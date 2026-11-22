#!/usr/bin/env bash
# 在 Debian 12 + systemd 上安装带账号认证的 IPv4 SOCKS5 服务。需要 root。
set -euo pipefail
export LC_ALL=C

readonly DEFAULT_PORT='50501' SERVICE='vps-socks5.service' PACKAGE_SERVICE='danted.service'
readonly CONFIG_DIR='/etc/vps-socks5' PAM_FILE='/etc/pam.d/vps-socks5'
readonly UNIT_FILE="/etc/systemd/system/$SERVICE"
readonly PRESET='/etc/systemd/system-preset/00-vps-socks5.preset'
readonly CONFIG_HEADER='# Managed by install-socks5.sh'
stage='' pending_file='' new_config=false

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

cleanup() {
    if [[ -n "$pending_file" ]]; then rm -f -- "$pending_file" || true; fi
    if [[ -n "$stage" ]]; then
        rm -f -- "$stage/danted.conf" "$stage/users" || true
        rmdir -- "$stage" || true
    fi
    if [[ "$new_config" == true ]]; then
        if systemctl disable --now "$SERVICE" >/dev/null 2>&1; then
            rm -f -- "$CONFIG_DIR/danted.conf" "$CONFIG_DIR/users"
            rmdir -- "$CONFIG_DIR"
        else
            printf '无法清理本次配置，请检查 %s。\n' "$SERVICE" >&2
        fi
    fi
}

write_once() {
    local target="$1" content="$2"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ ! -L "$target" && -f "$target" && "$(<"$target")" == "$content" ]] || fail "已有自定义文件，未覆盖 $target。"
        return
    fi
    pending_file="$(mktemp -- "$target.XXXXXX")"
    printf '%s\n' "$content" > "$pending_file"
    chmod 0644 "$pending_file"
    mv -nT -- "$pending_file" "$target"
    [[ ! -e "$pending_file" ]] || fail "文件 $target 已存在，安装中止。"
    pending_file=''
}

install_packages() {
    local package package_state=''
    local -a missing=()
    for package in dante-server libpam-pwdfile openssl iproute2; do
        if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)" != installed ]]; then
            missing+=("$package")
        fi
    done
    if ((${#missing[@]} == 0)); then return; fi

    if [[ "${missing[0]}" == dante-server ]]; then
        package_state="$(systemctl show -p LoadState --value "$PACKAGE_SERVICE")"
        case "$package_state" in
            not-found|masked) ;;
            *) fail '检测到已有的 Debian Dante 服务，请先修复原套件安装。' ;;
        esac
    fi
    apt-get -o APT::Update::Error-Mode=any update
    if [[ -n "$package_state" ]]; then
        mkdir -p -m 0755 -- "${PRESET%/*}"
        write_once "$PRESET" "disable $PACKAGE_SERVICE"
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    if [[ "$package_state" == not-found ]] &&
        { systemctl is-enabled --quiet "$PACKAGE_SERVICE" || systemctl is-active --quiet "$PACKAGE_SERVICE"; }; then
        systemctl disable --now "$PACKAGE_SERVICE"
    fi
}

prompt_value() {
    local label="$1" default="$2" hidden="${3:-false}" value suffix=''
    if [[ -n "$default" && "$hidden" == false ]]; then suffix=" [$default]"; fi
    printf '%s%s：' "$label" "$suffix" >&2
    if [[ "$hidden" == true ]]; then
        IFS= read -rs value || fail '输入已结束，安装取消。'
        printf '\n' >&2
    else
        IFS= read -r value || fail '输入已结束，安装取消。'
    fi
    printf '%s' "${value:-$default}"
}

random_hex() {
    local bytes="$1" value
    value="$(od -An -v -N "$bytes" -tx1 /dev/urandom | tr -d '[:space:]')" || fail '无法读取系统随机数。'
    [[ "$value" =~ ^[0-9a-f]+$ ]] && ((${#value} == bytes * 2)) || fail '随机数长度错误。'
    printf '%s' "$value"
}

probe_socks5() {
    # 用后台验证进程的标准输入传递密钥，不把密码放进进程参数。
    printf '%s\n%s\n' "$2" "$3" | timeout 5 bash -c '
        set -euo pipefail
        IFS= read -r username
        IFS= read -r password
        exec 3<>"/dev/tcp/127.0.0.1/$1"
        printf "\x05\x01\x02" >&3
        [[ "$(od -An -v -N2 -tx1 <&3 | tr -d "[:space:]")" == 0502 ]]
        [[ -n "$username" ]] || exit 0
        printf "\x01%b%s%b%s" "\\x$(printf "%02x" "${#username}")" "$username" \
            "\\x$(printf "%02x" "${#password}")" "$password" >&3
        [[ "$(od -An -v -N2 -tx1 <&3 | tr -d "[:space:]")" == 0100 ]]
    ' bash "$1" 2>/dev/null
}

main() {
    local port username password='' interface occupied unit pam hash active_state deadline
    ((EUID == 0)) || fail '请以 root 执行。'
    [[ -r /etc/os-release ]] || fail '无法识别操作系统。'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 12 ]] || fail '此脚本支持 Debian 12。'
    systemctl show -p Version --value >/dev/null || fail '需要运行中的 systemd。'
    umask 077
    exec 9>/run/lock/vps-socks5.lock
    flock -n 9 || fail '另一 SOCKS5 安装进程正在运行。'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
        [[ ! -L "$CONFIG_DIR" && -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR/danted.conf" && -f "$CONFIG_DIR/danted.conf" &&
            ! -L "$CONFIG_DIR/users" && -s "$CONFIG_DIR/users" ]] || fail "请检查已有配置 $CONFIG_DIR。"
        grep -Fxq "$CONFIG_HEADER" "$CONFIG_DIR/danted.conf" || fail "检测到外部配置，未覆盖 $CONFIG_DIR。"
        port="$(sed -n 's/^internal: 0\.0\.0\.0 port = //p' "$CONFIG_DIR/danted.conf")"
        IFS=: read -r username hash < "$CONFIG_DIR/users"
        [[ "$port" =~ ^[1-9][0-9]{0,4}$ && -n "$username" && "$hash" == \$6\$* ]] &&
            ((port <= 65535)) || fail "已有配置格式无效，请检查 $CONFIG_DIR。"
        printf '沿用已保存的端口与账号。\n'
    else
        active_state="$(systemctl show -p ActiveState --value "$SERVICE")"
        [[ "$active_state" == inactive || "$active_state" == failed ]] || fail "已有运行中的服务，请检查 $SERVICE。"
        while true; do
            port="$(prompt_value 'SOCKS5 端口' "$DEFAULT_PORT")"
            if [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)); then
                port=$((10#$port))
                break
            fi
            printf '请输入 1–65535 的整数。\n' >&2
        done
        while true; do
            username="$(prompt_value 'SOCKS5 账号（回车随机生成）' '')"
            if [[ -z "$username" ]]; then username="socks_$(random_hex 6)"; fi
            if [[ "$username" =~ ^[a-zA-Z0-9_.-]{1,64}$ ]]; then break; fi
            printf '账号须为 1–64 个英文字母、数字、下划线、点或连字符。\n' >&2
        done
        while true; do
            password="$(prompt_value 'SOCKS5 密码（回车随机生成）' '' true)"
            if [[ -z "$password" ]]; then password="$(random_hex 32)"; fi
            if [[ -n "$password" && ${#password} -le 255 && "$password" != *$'\r'* ]]; then break; fi
            printf '密码须为 1–255 字节，不能包含回车。\n' >&2
        done
    fi

    if [[ ! -e "$UNIT_FILE" && ! -L "$UNIT_FILE" ]]; then
        [[ "$(systemctl show -p LoadState --value "$SERVICE")" == not-found ]] || fail "已有同名服务，未覆盖 $SERVICE。"
    fi
    install_packages

    pam="$(printf '%s\n' "auth required pam_pwdfile.so pwdfile=$CONFIG_DIR/users" 'account required pam_permit.so')"
    unit="$(cat <<EOF
[Unit]
Description=Authenticated SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
RuntimeDirectory=vps-socks5
ExecStart=/usr/sbin/danted -f $CONFIG_DIR/danted.conf -p /run/vps-socks5/danted.pid
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
LimitCORE=0
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=multi-user.target
EOF
)"
    if [[ -n "$password" ]]; then
        occupied="$(ss -H -lnt "sport = :$port")"
        [[ -z "$occupied" ]] || fail "TCP 端口 $port 已被占用，请重跑并另选端口。"
        interface="$(ip -4 route show default | awk '{ for (i=1; i<NF; i++) if ($i=="dev") { print $(i+1); exit } }')"
        [[ "$interface" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || fail '未找到可用的 IPv4 默认路由网卡。'
        hash="$(printf '%s\n' "$password" | openssl passwd -6 -stdin)"
        [[ "$hash" == \$6\$* && "$hash" != *$'\n'* ]] || fail '无法生成密码哈希。'
        stage="$(mktemp -d -- /etc/.vps-socks5.XXXXXX)"
        printf '%s:%s\n' "$username" "$hash" > "$stage/users"
        cat > "$stage/danted.conf" <<EOF
$CONFIG_HEADER
logoutput: stderr
internal: 0.0.0.0 port = $port
external: $interface
external.protocol: ipv4
user.privileged: root
user.notprivileged: nobody
clientmethod: none
socksmethod: pam.username

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    command: connect udpassociate udpreply
    proxyprotocol: socks_v5
    pam.servicename: vps-socks5
}
EOF
        /usr/sbin/danted -V -f "$stage/danted.conf" || fail 'Dante 配置验证失败。'
    fi

    write_once "$PAM_FILE" "$pam"
    write_once "$UNIT_FILE" "$unit"
    if [[ -n "$stage" ]]; then
        mv -nT -- "$stage" "$CONFIG_DIR"
        [[ ! -e "$stage" ]] || fail "配置目录 $CONFIG_DIR 已存在，安装中止。"
        stage=''
        new_config=true
    fi
    systemctl daemon-reload
    systemctl start "$SERVICE" || fail 'SOCKS5 服务启动失败，请查看日志。' "journalctl -u $SERVICE -n 30 --no-pager"
    printf '正在验证本机 SOCKS5 服务。\n'
    deadline=$((SECONDS + 60))
    until systemctl is-active --quiet "$SERVICE" && probe_socks5 "$port" "${password:+$username}" "$password"; do
        ((SECONDS < deadline)) || fail '本机 SOCKS5 验证失败，请查看日志。' "journalctl -u $SERVICE -n 30 --no-pager"
        sleep 1
    done
    systemctl enable "$SERVICE"
    new_config=false
    printf '\nSOCKS5 已启动。\n端口：%s（TCP）\n账号：%s\n' "$port" "$username"
    if [[ -n "$password" ]]; then printf '密码：%s\n' "$password"; fi
    unset password
    printf 'UDP ASSOCIATE 使用会话分配的中继端口。若有防火墙或安全组，请按实际需要放行。\n'
}

main "$@"
