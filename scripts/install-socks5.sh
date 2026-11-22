#!/usr/bin/env bash
# Debian 12 systemd SOCKS5 instances, with per-instance PAM accounts.
set -euo pipefail
export LC_ALL=C

readonly PROXY_KEY='vps-socks5' PROXY_LABEL='SOCKS5' PROXY_DEFAULT_PORT='50501'
readonly PROXY_PACKAGE='dante-server' PROXY_VENDOR_UNIT='danted.service'
readonly PROXY_LEGACY_CONFIG='/etc/vps-socks5' CONFIG_HEADER='# Managed by install-socks5.sh'
readonly PROXY_UNIT_REFERENCE='(^|[^[:alnum:]_-])(danted|sockd)([^[:alnum:]_-]|$)'
readonly -a PROXY_PACKAGES=(dante-server libpam-pwdfile openssl iproute2)
readonly -a PROXY_PROCESS_NAMES=(danted sockd)
readonly -a PROXY_VENDOR_CONFIG=(/etc/danted.conf /etc/default/danted /etc/pam.d/danted)
# shellcheck source=scripts/proxy-manager.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/proxy-manager.sh"

proxy_socks_dir() {
    if [[ "$1" == legacy ]]; then printf '%s' "$PROXY_LEGACY_CONFIG"
    else printf '%s' "$1"; fi
}

proxy_pam_name() {
    if [[ "$2" == legacy ]]; then printf '%s' "$PROXY_KEY"
    else printf '%s-%s' "$PROXY_KEY" "$1"; fi
}

proxy_pam_content() {
    printf 'auth required pam_pwdfile.so pwdfile=%s/users\naccount required pam_permit.so' "$(proxy_socks_dir "$1")"
}

proxy_socks_record() {
    local path
    path="$(proxy_socks_dir "$1")"
    [[ -d "$path" && -f "$path/danted.conf" && -f "$path/users" ]] &&
        proxy_private "$path" 700 && proxy_private "$path/danted.conf" 600 &&
        proxy_private "$path/users" 600 && grep -Fxq "$CONFIG_HEADER" "$path/danted.conf" || return 1
    socks_port="$(sed -n 's/^internal: 0\.0\.0\.0 port = //p' "$path/danted.conf")" || return 1
    IFS=: read -r socks_user socks_hash < "$path/users" || return 1
    proxy_valid_port "$socks_port" && [[ "$socks_user" =~ ^[a-zA-Z0-9_.-]{1,64}$ && "$socks_hash" == \$6\$* ]] || return 1
    if [[ "$1" != legacy ]]; then
        grep -Fxq "    pam.servicename: $(proxy_pam_name "$socks_port" "$1")" "$path/danted.conf" || return 1
    fi
}

proxy_config_port() {
    proxy_socks_record "$1" || return 1
    printf '%s' "$socks_port"
}

proxy_other_uses_port() {
    [[ -e "/etc/vps-shadowsocks.d/$1" || -L "/etc/vps-shadowsocks.d/$1" ]] ||
        grep -Fq "\"server_port\":$1," /etc/vps-shadowsocks.json 2>/dev/null
}

proxy_unit_text() {
    local dir runtime
    dir="$(proxy_socks_dir "$2")"
    runtime="$(proxy_pam_name "$1" "$2")"
    cat <<EOF
[Unit]
Description=Authenticated SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
RuntimeDirectory=$runtime
ExecStart=/usr/sbin/danted -f $dir/danted.conf -p /run/$runtime/danted.pid
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
LimitCORE=0
Restart=on-failure
RestartSec=2s
EOF
    if [[ "$2" != legacy ]]; then
        printf 'StandardOutput=null\nStandardError=null\nInaccessiblePaths=%s\n' "$PROXY_LOG_PATHS"
    fi
    printf '\n[Install]\nWantedBy=multi-user.target\n'
}

proxy_read_credentials() {
    while true; do
        username="$(proxy_prompt 'SOCKS5 账号（回车随机生成）' '')"
        if [[ -z "$username" ]]; then username="socks_$(proxy_random_hex 6)"; fi
        if [[ "$username" =~ ^[a-zA-Z0-9_.-]{1,64}$ ]]; then break; fi
        printf '账号须为 1–64 个英文字母、数字、下划线、点或连字符。\n'
    done
    while true; do
        password="$(proxy_prompt 'SOCKS5 密码（回车随机生成）' '' secret)"
        if [[ -z "$password" ]]; then password="$(proxy_random_hex 32)"; fi
        if proxy_valid_password "$password"; then break; fi
        printf '密码须为 1–255 字节，不能包含回车。\n'
    done
}

proxy_valid_password() {
    [[ -n "$1" && ${#1} -le 255 && "$1" != *$'\r'* && "$1" != *$'\n'* ]]
}

proxy_create_config() {
    local port="$1" stage="$2" account="$3" secret="$4" interface hash
    interface="$(ip -4 route show default | awk '{ for (i=1; i<NF; i++) if ($i=="dev") { print $(i+1); exit } }')"
    [[ "$interface" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]] || proxy_fail '未找到可用的 IPv4 默认路由网卡。'
    hash="$(printf '%s\n' "$secret" | openssl passwd -6 -stdin)"
    [[ "$hash" == \$6\$* && "$hash" != *$'\n'* ]] || proxy_fail '无法生成密码哈希。'
    printf '%s:%s\n' "$account" "$hash" > "$stage/users"
    printf '%s\n' "$secret" > "$stage/password"
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
    pam.servicename: $PROXY_KEY-$port
}
EOF
    /usr/sbin/danted -V -f "$stage/danted.conf" || proxy_fail 'Dante 配置验证失败。'
}

proxy_install_protocol_file() {
    proxy_write "/etc/pam.d/$(proxy_pam_name "$1" "$2")" 0644 "$(proxy_pam_content "$2")"
}

proxy_check_pam() {
    local pam
    pam="/etc/pam.d/$(proxy_pam_name "$1" "$2")"
    if [[ -e "$pam" || -L "$pam" ]]; then
        [[ ! -L "$pam" && -f "$pam" && "$(<"$pam")" == "$(proxy_pam_content "$2")" ]] ||
            proxy_fail "存在自定义 PAM 文件，未处理 $pam。"
    fi
}

proxy_remove_protocol_file() {
    proxy_check_pam "$1" "$2"
    rm -f -- "/etc/pam.d/$(proxy_pam_name "$1" "$2")"
}

proxy_check_stage() { proxy_only_files "$1" danted.conf users password; }

proxy_check_removal() {
    proxy_check_pam "$1" "$2"
    proxy_check_stage "$(proxy_socks_dir "$2")"
}

proxy_remove_stage() {
    rm -f -- "$1/danted.conf" "$1/users" "$1/password"
    rmdir -- "$1"
}

proxy_remove_config() {
    proxy_check_removal "$1" "$2"
    proxy_remove_protocol_file "$1" "$2"
    proxy_retire_dir "$(proxy_socks_dir "$2")"
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


proxy_wait() {
    local port="$1" kind="$2" account="${3:-}" secret="${4:-}" unit deadline
    unit="$(proxy_unit "$port" "$kind")"
    deadline=$((SECONDS + 60))
    until systemctl is-active --quiet "$unit" && probe_socks5 "$port" "$account" "$secret"; do
        ((SECONDS < deadline)) || return 1
        sleep 1
    done
}

proxy_show() {
    local port="$1" kind="$2" socks_port socks_user socks_hash password_file secret salt verified
    proxy_socks_record "$kind" || proxy_fail '无法读取实例连接信息。'
    printf '端口：%s（TCP）\n账号：%s\n' "$port" "$socks_user"
    password_file="$(proxy_socks_dir "$kind")/password"
    if [[ -e "$password_file" || -L "$password_file" ]]; then
        [[ -f "$password_file" ]] && proxy_private "$password_file" 600 || proxy_fail '请检查密码文件权限。'
        IFS= read -r secret < "$password_file" || proxy_fail '无法读取实例密码。'
        proxy_valid_password "$secret" || proxy_fail '实例密码文件格式无效。'
        printf '密码：%s\n' "$secret"
    elif [[ "$kind" == legacy ]]; then
        printf '旧实例只保存密码哈希，无法直接显示原密码。\n'
        proxy_confirm '是否验证并补录原密码' || return 0
        secret="$(proxy_prompt '输入原密码' '' secret)"
        proxy_valid_password "$secret" || proxy_fail '原密码输入无效。'
        if ! [[ "$socks_hash" =~ ^\$6\$([./A-Za-z0-9]{1,16})\$[./A-Za-z0-9]{86}$ ]]; then
            proxy_fail '不能验证此旧密码哈希格式。'
        fi
        salt="${BASH_REMATCH[1]}"
        verified="$(printf '%s\n' "$secret" | openssl passwd -6 -salt "$salt" -stdin)"
        [[ "$verified" == "$socks_hash" ]] || proxy_fail '密码验证失败。'
        proxy_write "$password_file" 0600 "$secret"
        printf '已补录通过验证的原密码。\n密码：%s\n' "$secret"
    else
        printf '未找到可显示的密码。\n'
    fi
    printf 'UDP ASSOCIATE 使用会话分配的中继端口。\n'
}

proxy_run_debug() {
    local port="$1" kind="$2" dir
    shift 2
    dir="$(proxy_socks_dir "$kind")"
    proxy_check_pam "$port" "$kind"
    systemd-run "$@" -p Type=exec -p PrivateTmp=yes -p ProtectSystem=full -p ProtectHome=yes \
        -p "RuntimeDirectory=$PROXY_KEY-debug-$port" \
        /usr/sbin/danted -d1 -f "$dir/danted.conf" -p "/run/$PROXY_KEY-debug-$port/danted.pid"
}

proxy_menu "$@"
