#!/usr/bin/env bash
# Debian/Ubuntu + systemd，root；只接管普通静态 resolv.conf，保留原 DNS 和恢复副本。
# 官方固定版本独立安装，不覆盖发行版 SmartDNS；安装前需要 dig/curl/python3 等工具。
set -euo pipefail

STATE=/var/lib/vps-smartdns
CONFIG=/etc/vps-smartdns.conf
RESOLV=/etc/resolv.conf
UNIT=/etc/systemd/system/vps-smartdns.service
BIN=/usr/local/lib/vps-smartdns/run-smartdns
SELF=/usr/local/lib/vps-smartdns/manage.sh
LOCK=/run/lock/vps-smartdns.lock
SERVICE=vps-smartdns.service
WORK=''
TRANSACTION=false

die() { printf '错误：%s\n' "$*" >&2; return 1; }

valid_ip() {
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    addr = ipaddress.ip_address(sys.argv[1])
    if isinstance(addr, ipaddress.IPv6Address) and addr.ipv4_mapped:
        addr = addr.ipv4_mapped
    # 本机、未指定、多播和带作用域的地址不能成为本服务的上游。
    ok = not (addr.is_loopback or addr.is_unspecified or addr.is_multicast or '%' in sys.argv[1])
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
PY
}

query_ok() {
    local server=$1 domain=$2 transport=${3:-udp} result
    local -a options=()
    [[ $transport != tcp ]] || options+=(+tcp)
    result=$(dig @"$server" "$domain" A +time=3 +tries=1 +noall +comments +answer "${options[@]}" 2>/dev/null) || return 1
    [[ $result == *'status: NOERROR,'* ]] &&
        awk '$0 !~ /^;/ && $4 == "A" { found=1 } END { exit !found }' <<< "$result"
}

test_upstream() {
    local server=$1 domain
    for domain in example.com www.iana.org; do
        query_ok "$server" "$domain" || return 1
    done
    query_ok "$server" example.com tcp
}

ask_dns() {
    local candidate
    while true; do
        if ! IFS= read -r -p '请输入首选 DNS 的 IPv4/IPv6 地址（回车测试，Ctrl+C 取消）：' candidate; then
            die '输入结束，未修改 DNS 配置。'; return 1
        fi
        if ! valid_ip "$candidate"; then
            printf '地址不合法，或不能作为上游，请重新输入。\n'; continue
        fi
        printf '正在测试实际 UDP/TCP DNS 解析……\n'
        if test_upstream "$candidate"; then
            PREFERRED=$candidate
            printf '首选 DNS 测试通过。\n'; return 0
        fi
        printf 'DNS 解析测试失败，未修改配置，请重新输入。\n'
    done
}

read_original_dns() {
    local source=$1 address
    ORIGINAL=()
    while IFS= read -r address; do
        if valid_ip "$address"; then ORIGINAL+=("$address"); fi
    done < <(awk '$1 == "nameserver" {print $2}' "$source")
    ((${#ORIGINAL[@]} > 0)) || die '原配置中没有可直接使用的非本机 DNS，停止以避免解析循环。'
}

write_config() {
    local destination=$1 address
    {
        printf '# Managed by vps-scripts configure-smartdns\n'
        printf 'server-name vps-smartdns\nbind 127.0.0.1:53\nbind-tcp 127.0.0.1:53\n'
        # 不用 IP 测速干扰首选语义，不缓存后备答案以便恢复后立即重试首选。
        printf 'cache-size 0\nspeed-check-mode none\ndualstack-ip-selection no\nserve-expired no\n'
        printf 'log-level warn\nlog-console yes\n'
        printf 'server %s\n' "$PREFERRED"
        for address in "${ORIGINAL[@]}"; do
            [[ $address == "$PREFERRED" ]] || printf 'server %s -fallback\n' "$address"
        done
    } > "$destination"
}

preflight() {
    local dependency
    [[ $EUID == 0 ]] || die '请使用 root 运行；脚本不会自动提权。'
    for dependency in python3 dig curl dpkg-deb sha256sum systemctl systemd-run flock ss install timeout; do
        command -v "$dependency" >/dev/null || die "缺少依赖 $dependency；请先安装相应工具（apt install dnsutils curl python3 ca-certificates iproute2 util-linux）。"
    done
    [[ -d /run/systemd/system ]] || die '仅支持运行 systemd 的主机。'
    # shellcheck disable=SC1091
    . /etc/os-release
    [[ $ID == debian || $ID == ubuntu ]] || die '首版仅支持 Debian/Ubuntu。'
    [[ -f $RESOLV && ! -L $RESOLV ]] || die 'resolv.conf 不是普通静态文件；不接管 resolved/resolvconf 等管理的配置。'
    if systemctl is-active --quiet systemd-resolved || systemctl is-active --quiet NetworkManager; then
        die '检测到活动的 DNS/网络管理服务，停止以避免覆盖。'
    fi
    if pgrep -x dhclient >/dev/null || pgrep -x dhcpcd >/dev/null ||
        grep -Eq '^[[:space:]]*iface[[:space:]]+[^[:space:]]+[[:space:]]+inet6?[[:space:]]+dhcp' /etc/network/interfaces /etc/network/interfaces.d/* 2>/dev/null; then
        die '检测到 DHCP 管理的网络，首版不接管其 DNS 配置。'
    fi
    if grep -Eqi 'generated|managed by|do not edit' "$RESOLV" && ! grep -q '^# Managed by vps-scripts' "$RESOLV"; then
        die 'resolv.conf 标记为自动生成，请先确认 DNS 管理方式。'
    fi
    if [[ ! -f $STATE/managed ]]; then
        if command -v smartdns >/dev/null || [[ -e /etc/smartdns || -e /etc/smartdns.conf || -e $CONFIG || -e $UNIT || -e $BIN || -e $SELF ]]; then
            die '发现已有 SmartDNS 或同名安装文件，停止，避免覆盖。'
        fi
    else
        [[ -f $STATE/original-resolv.conf ]] || die '缺少原 DNS 备份，停止。'
        [[ -f $STATE/pending || ! -f $CONFIG ]] || grep -q '^# Managed by vps-scripts configure-smartdns$' "$CONFIG" || die 'SmartDNS 配置已被外部修改，停止。'
    fi
    if [[ ! -f $STATE/managed ]] && ss -H -lnut | awk '$5 ~ /:53$/ { found=1 } END { exit !found }'; then
        die '53 端口已被占用，停止。'
    fi
}

download_binary() {
    local architecture checksum package
    case $(dpkg --print-architecture) in
        amd64) architecture=x86_64; checksum=4cc1b8f9db10110e1212d981cfee7eb89a3c80f5766760e3b5f7541c8da8b546 ;;
        arm64) architecture=aarch64; checksum=2effd18abaa7b8a5e30a66bb087b8429ceb87cf1ee37b06571362cdc17dab229 ;;
        *) die '仅提供 amd64/arm64 官方固定版本安装。'; return 1 ;;
    esac
    WORK=$(mktemp -d)
    package="smartdns.1.2026.08.05-0921.${architecture}-debian-all.deb"
    curl --proto '=https' --tlsv1.2 -fsSL --connect-timeout 10 --max-time 180 --retry 2 \
        "https://github.com/pymumu/smartdns/releases/download/Release48.4/$package" -o "$WORK/package.deb"
    printf '%s  %s\n' "$checksum" "$WORK/package.deb" | sha256sum -c -
    dpkg-deb -x "$WORK/package.deb" "$WORK/extracted"
    local package_root="$WORK/extracted/usr/local/lib/smartdns"
    [[ -x $package_root/smartdns && -f $package_root/lib/libc.so && -f $package_root/lib/libgcc_s.so.1 ]] || die '安装包结构不符合预期。'
    install -d -m 755 /usr/local/lib/vps-smartdns/lib
    install -m 755 "$package_root/smartdns" /usr/local/lib/vps-smartdns/smartdns
    install -m 755 "$package_root/lib/libc.so" /usr/local/lib/vps-smartdns/lib/libc.so
    install -m 755 "$package_root/lib/libgcc_s.so.1" /usr/local/lib/vps-smartdns/lib/libgcc_s.so.1
    # 使用已校验包中的 musl loader；不依赖工作目录和发行版 libc。
    cat > "$WORK/run-smartdns" <<'EOF'
#!/usr/bin/env bash
exec /usr/local/lib/vps-smartdns/lib/libc.so --library-path /usr/local/lib/vps-smartdns/lib /usr/local/lib/vps-smartdns/smartdns "$@"
EOF
    install -m 755 "$WORK/run-smartdns" "$BIN"
}

recover() {
    [[ -f $STATE/pending ]] || return 0
    [[ -f $STATE/transaction/resolv.conf && ! -L $RESOLV ]] || die '恢复副本缺失或 resolv.conf 类型已改变，请人工检查。'
    printf '发现未完成配置，正在恢复上一份 DNS 配置……\n' >&2
    # 先恢复系统 DNS，避免停止服务时继续指向本机。
    cat "$STATE/transaction/resolv.conf" > "$RESOLV" || return 1
    systemctl stop "$SERVICE" || true
    if [[ -f $STATE/transaction/config ]]; then
        install -m 644 "$STATE/transaction/config" "$CONFIG" || return 1
    else
        rm -f -- "$CONFIG"
    fi
    if [[ -f $STATE/transaction/active ]]; then systemctl start "$SERVICE" || return 1; fi
    if [[ ! -f $STATE/transaction/enabled ]]; then systemctl disable "$SERVICE" >/dev/null 2>&1 || true; fi
    rm -f -- "$STATE/pending"
    printf '上一份配置已恢复。\n' >&2
}

finish() {
    local status=$?
    trap - EXIT INT TERM HUP
    if [[ $TRANSACTION == true ]]; then
        if ! recover; then printf '自动恢复失败，请检查 %s/transaction/resolv.conf。\n' "$STATE" >&2; status=1; fi
    fi
    [[ -z $WORK ]] || rm -rf -- "$WORK"
    exit "$status"
}

install_units() {
    if [[ ! ${BASH_SOURCE[0]} -ef $SELF ]]; then install -m 755 "${BASH_SOURCE[0]}" "$SELF"; fi
    cat > "$UNIT" <<'EOF'
[Unit]
Description=VPS SmartDNS preferred and fallback resolver
After=network.target vps-smartdns-recover.service
[Service]
Type=simple
ExecStart=/usr/local/lib/vps-smartdns/run-smartdns -f -c /etc/vps-smartdns.conf -p /run/vps-smartdns/smartdns.pid
RuntimeDirectory=vps-smartdns
Restart=on-failure
RestartSec=2
UMask=0027
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/vps-smartdns-recover.service <<'EOF'
[Unit]
Description=Recover interrupted VPS SmartDNS configuration
After=local-fs.target
Before=vps-smartdns.service
[Service]
Type=oneshot
ExecStart=/usr/local/lib/vps-smartdns/manage.sh --recover
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable vps-smartdns-recover.service >/dev/null
}

apply_config() {
    local attempt
    install -d -m 700 "$STATE/transaction"
    rm -f -- "$STATE/transaction/config" "$STATE/transaction/active" "$STATE/transaction/enabled"
    cp -p -- "$RESOLV" "$STATE/transaction/resolv.conf"
    [[ ! -f $CONFIG ]] || cp -p -- "$CONFIG" "$STATE/transaction/config"
    if systemctl is-active --quiet "$SERVICE"; then touch "$STATE/transaction/active"; fi
    if systemctl is-enabled --quiet "$SERVICE"; then touch "$STATE/transaction/enabled"; fi
    touch "$STATE/pending"
    TRANSACTION=true
    # 独立任务：SSH 断开或脚本被强制终止后仍能恢复；正常提交后任务成为空操作。
    systemd-run --quiet --unit="vps-smartdns-rollback-$(date +%s)-$$" --on-active=90s "$SELF" --recover
    write_config "$STATE/new-config"
    install -m 644 "$STATE/new-config" "$CONFIG"
    systemctl enable "$SERVICE" >/dev/null
    systemctl restart "$SERVICE"
    for attempt in {1..10}; do
        if query_ok 127.0.0.1 example.com && query_ok 127.0.0.1 www.iana.org tcp; then break; fi
        sleep 1
    done
    query_ok 127.0.0.1 example.com || die '本机 SmartDNS 验证失败。'
    systemctl is-active --quiet "$SERVICE" || die 'SmartDNS 服务未正常运行。'
    # 不替换 inode，不修改文件权限；保留搜索域等原有解析选项。
    {
        printf '# Managed by vps-scripts configure-smartdns\nnameserver 127.0.0.1\n'
        # SmartDNS 自身不可用时，系统解析器仍可尝试原 DNS。
        printf 'nameserver %s\n' "${ORIGINAL[@]:0:2}"
        awk '$1 != "nameserver" && $1 != "options" && $0 !~ /^# Managed by vps-scripts/' "$STATE/original-resolv.conf"
        # rotate 会破坏本机优先；其余原选项保留。
        awk '$1 == "options" {printf "options"; for(i=2;i<=NF;i++) if($i != "rotate") printf " %s", $i; print ""}' "$STATE/original-resolv.conf"
    } > "$STATE/new-resolv.conf"
    cat "$STATE/new-resolv.conf" > "$RESOLV"
    local result
    result=$(dig example.com A +time=4 +tries=1 +noall +comments +answer +stats)
    [[ $result == *'SERVER: 127.0.0.1#53'* && $result == *'status: NOERROR,'* ]] || die '切换后的系统解析验证失败。'
    rm -f -- "$STATE/pending"
    TRANSACTION=false
    printf 'SmartDNS 配置成功：首选正常时优先，失败时使用原 DNS；恢复后重新尝试首选。\n'
}

website_tests() {
    local name domain result status code dns_status
    local -a sites=(
        'Netflix|www.netflix.com' 'YouTube|www.youtube.com' 'Disney+|www.disneyplus.com'
        'OpenAI|chatgpt.com' 'Gemini|gemini.google.com' 'Claude|claude.ai'
        'Cursor|cursor.com' 'Instagram|www.instagram.com' 'Google DeepMind|deepmind.google'
    )
    printf '\n网站访问测试（不代表账号、地区或流媒体解锁，不参与 DNS 切换）\n'
    for result in "${sites[@]}"; do
        IFS='|' read -r name domain <<< "$result"
        dns_status=失败
        if query_ok 127.0.0.1 "$domain"; then dns_status=成功; fi
        status=0
        result=$(curl --noproxy '*' --proto '=https' --proto-redir '=https' -sSL -o /dev/null \
            --connect-timeout 6 --max-time 20 --max-redirs 4 \
            -w '%{http_code}|%{time_connect}|%{time_appconnect}|%{time_total}' "https://$domain/" 2>/dev/null) || status=$?
        code=${result%%|*}
        if ((status != 0)); then
            printf '%s (%s)：DNS=%s；HTTPS 请求失败（curl=%s）；%s\n' "$name" "$domain" "$dns_status" "$status" "$result"
        else
            printf '%s (%s)：DNS=%s；HTTP/连接秒/TLS秒/总秒=%s\n' "$name" "$domain" "$dns_status" "$result"
            [[ $code != 403 && $code != 429 ]] || printf '  服务已响应，但拒绝访问或限制请求；不判定为访问成功。\n'
        fi
    done
}

main() {
    if [[ ${1:-} == --recover && $# == 1 ]]; then
        [[ $EUID == 0 ]] || die '恢复需要 root。'
        exec 9> "$LOCK"
        flock -w 180 9 || return 1
        recover; return
    fi
    [[ $# == 0 ]] || { die '用法：bash scripts/configure-smartdns.sh'; return 1; }
    preflight
    exec 9> "$LOCK"
    flock -n 9 || { die '另一个配置或恢复任务正在运行。'; return 1; }
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    recover
    ask_dns
    if [[ -f $STATE/original-resolv.conf ]]; then
        read_original_dns "$STATE/original-resolv.conf"
    else
        read_original_dns "$RESOLV"
    fi
    local address usable=false
    for address in "${ORIGINAL[@]}"; do
        [[ $address != "$PREFERRED" ]] || continue
        if query_ok "$address" example.com; then usable=true; break; fi
    done
    [[ $usable == true ]] || die '没有与首选不同且可用的原系统 DNS，不能提供独立后备，停止。'
    install -d -m 700 "$STATE"
    if [[ ! -f $STATE/original-resolv.conf ]]; then cp -p -- "$RESOLV" "$STATE/original-resolv.conf"; fi
    touch "$STATE/managed"
    if [[ ! -x $BIN ]]; then download_binary; fi
    install_units
    apply_config
    website_tests
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
