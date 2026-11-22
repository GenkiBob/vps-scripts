#!/usr/bin/env bash
# Debian 12 systemd Shadowsocks instances.
set -euo pipefail

readonly PROXY_KEY='vps-shadowsocks' PROXY_LABEL='Shadowsocks' PROXY_DEFAULT_PORT=''
readonly PROXY_PACKAGE='shadowsocks-libev' PROXY_VENDOR_UNIT='shadowsocks-libev.service'
readonly PROXY_LEGACY_CONFIG='/etc/vps-shadowsocks.json' METHOD='chacha20-ietf-poly1305'
readonly LISTEN_TIMEOUT_SECONDS=60
readonly PROXY_UNIT_REFERENCE='(^|[^[:alnum:]_-])((ss-server|ss-local|ss-redir|ss-tunnel|ss-manager)([^[:alnum:]_-]|$)|shadowsocks-libev)'
readonly -a PROXY_PACKAGES=(shadowsocks-libev iproute2)
readonly -a PROXY_VENDOR_CONFIG=(/etc/shadowsocks-libev /etc/default/shadowsocks-libev)
readonly -a PROXY_PROCESS_NAMES=(ss-server ss-local ss-redir ss-tunnel ss-manager)
# shellcheck source=scripts/proxy-manager.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/proxy-manager.sh"

proxy_ss_path() {
    if [[ "$1" == legacy ]]; then printf '%s' "$PROXY_LEGACY_CONFIG"
    else printf '%s/config.json' "$1"; fi
}

proxy_ss_read() {
    local path pattern
    path="$(proxy_ss_path "$1")"
    pattern='^\{"server":(\["0\.0\.0\.0"(,"::")?\]),"server_port":([1-9][0-9]{0,4}),"password":"([0-9a-f]{64})","method":"'"$METHOD"'","mode":"tcp_and_udp"\}$'
    [[ -f "$path" ]] && proxy_private "$path" 600 || return 1
    [[ "$(<"$path")" =~ $pattern ]] || return 1
    ss_listeners="${BASH_REMATCH[1]}" ss_port="${BASH_REMATCH[3]}" ss_password="${BASH_REMATCH[4]}"
    proxy_valid_port "$ss_port"
}

proxy_config_port() {
    proxy_ss_read "$1" || return 1
    printf '%s' "$ss_port"
}

proxy_other_uses_port() {
    [[ -e "/etc/vps-socks5.d/$1" || -L "/etc/vps-socks5.d/$1" ]] ||
        grep -Fxq "internal: 0.0.0.0 port = $1" /etc/vps-socks5/danted.conf 2>/dev/null
}

proxy_unit_text() {
    local config
    config="$(proxy_ss_path "$2")"
    cat <<EOF
[Unit]
Description=Shadowsocks server
After=network.target

[Service]
Type=exec
DynamicUser=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LoadCredential=config.json:$config
ExecStart=/usr/bin/ss-server -c %d/config.json
Restart=on-failure
RestartSec=2s
LimitCORE=0
EOF
    if [[ "$2" != legacy ]]; then
        printf 'StandardOutput=null\nStandardError=null\nInaccessiblePaths=%s\n' "$PROXY_LOG_PATHS"
    fi
    printf '\n[Install]\nWantedBy=multi-user.target\n'
}

proxy_read_credentials() {
    password="$(proxy_random_hex 32)"
}

proxy_create_config() {
    local port="$1" stage="$2" secret="$4" addresses listeners='["0.0.0.0"]'
    addresses="$(ip -o -6 addr show up scope global)"
    if [[ -n "$addresses" ]]; then listeners='["0.0.0.0","::"]'; fi
    printf '{"server":%s,"server_port":%s,"password":"%s","method":"%s","mode":"tcp_and_udp"}\n' \
        "$listeners" "$port" "$secret" "$METHOD" > "$stage/config.json"
}

proxy_install_protocol_file() { :; }
proxy_remove_protocol_file() { :; }

proxy_check_stage() { proxy_only_files "$1" config.json; }

proxy_check_removal() {
    if [[ "$2" != legacy ]]; then proxy_check_stage "$2"; fi
}

proxy_remove_stage() {
    rm -f -- "$1/config.json"
    rmdir -- "$1"
}

proxy_remove_config() {
    proxy_check_removal "$1" "$2"
    if [[ "$2" == legacy ]]; then rm -f -- "$PROXY_LEGACY_CONFIG"
    else proxy_retire_dir "$2"; fi
}

wait_for_listeners() {
    local port="$1" unit="$3" expected=1 pid='' sockets=''
    local deadline=$((SECONDS + LISTEN_TIMEOUT_SECONDS))
    if [[ "$2" == *::* ]]; then expected=2; fi
    while true; do
        pid="$(systemctl show -p MainPID --value "$unit")" || break
        sockets="$(ss -H -lntup "sport = :$port")" || break
        if [[ "$pid" =~ ^[1-9][0-9]*$ ]] && awk -v pid="$pid" -v expected="$expected" '
            index($0, "pid=" pid ",") { listening[$1]++ }
            END { exit !(listening["tcp"] >= expected && listening["udp"] >= expected) }
        ' <<< "$sockets"; then
            return 0
        fi
        if ((SECONDS >= deadline)); then break; fi
        sleep 1
    done
    printf 'systemd 主进程 PID：%s\n端口 %s 最后一次检查的监听记录：\n%s\n' \
        "${pid:-未知}" "$port" "${sockets:-未取得 TCP 或 UDP 监听记录。}" >&2
    return 1
}

show_connection() {
    local port="$1" password="$2" listeners="$3" host="${SS_HOST:-}" userinfo
    if [[ -n "$host" && ! "$host" =~ ^[a-zA-Z0-9.-]+$ && ! "$host" =~ ^[0-9a-fA-F:.]*:[0-9a-fA-F:.]*$ ]]; then
        host=''
    fi
    if [[ -z "$host" ]]; then
        # 仅使用本机地址，不向外部网站查询。NAT 的公网地址可由 SS_HOST 提供。
        host="$(ip -o addr show up scope global | awk -v ipv6="$listeners" '
            $3 == "inet" && !v4 {
                split($4, addr, "/"); split(addr[1], part, ".")
                if (part[1] > 0 && part[1] < 224 && part[1] != 10 && part[1] != 127 &&
                    !(part[1] == 100 && part[2] >= 64 && part[2] <= 127) &&
                    !(part[1] == 169 && part[2] == 254) && !(part[1] == 172 && part[2] >= 16 && part[2] <= 31) &&
                    !(part[1] == 192 && part[2] == 168)) v4 = addr[1]
            }
            $3 == "inet6" && $4 ~ /^[23]/ && $4 !~ /^2001:db8:/ && !v6 && ipv6 ~ /::/ {
                split($4, addr, "/"); v6 = addr[1]
            }
            END { print v4 ? v4 : v6 }
        ')" || host=''
    fi
    printf '\n端口：%s（TCP 与 UDP）\n账号：无\n加密：%s\n密码：%s\n' "$port" "$METHOD" "$password"
    if [[ -z "$host" ]]; then
        printf '客户端请填写 VPS 的公网地址或域名，或设置 SS_HOST 后重新查看以生成导入链接。\n'
    else
        if [[ "$host" == *:* ]]; then host="[$host]"; fi
        userinfo="$(printf '%s:%s' "$METHOD" "$password" | base64 -w 0 | tr '/+' '_-' | tr -d '=')"
        printf '导入链接：ss://%s@%s:%s\n' "$userinfo" "$host" "$port"
    fi
    printf '若 VPS 有防火墙或安全组，请确认允许此端口的 TCP 和 UDP 入站。\n'
}

proxy_wait() {
    local port="$1" kind="$2" ss_port ss_listeners ss_password
    proxy_ss_read "$kind" && wait_for_listeners "$port" "$ss_listeners" "$(proxy_unit "$port" "$kind")"
}

proxy_show() {
    local ss_port ss_listeners ss_password
    proxy_ss_read "$2" || proxy_fail '无法读取实例连接信息。'
    show_connection "$1" "$ss_password" "$ss_listeners"
}

proxy_run_debug() {
    local port="$1" kind="$2" config debug
    shift 2
    config="$(proxy_ss_path "$kind")"
    debug="$(proxy_debug_unit "$port")"
    systemd-run "$@" -p Type=exec -p DynamicUser=yes \
        -p CapabilityBoundingSet=CAP_NET_BIND_SERVICE -p AmbientCapabilities=CAP_NET_BIND_SERVICE \
        -p "LoadCredential=config.json:$config" \
        /usr/bin/ss-server -v -c "/run/credentials/$debug/config.json"
}

proxy_menu "$@"
