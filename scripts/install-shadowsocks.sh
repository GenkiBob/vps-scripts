#!/usr/bin/env bash
# 在 Debian 12 上安装单实例 Shadowsocks 服务端。需要 root 和 systemd。
set -euo pipefail

readonly SERVICE='vps-shadowsocks.service' PACKAGE_SERVICE='shadowsocks-libev.service'
readonly PACKAGE_PRESET='/etc/systemd/system-preset/00-vps-shadowsocks.preset'
readonly CONFIG='/etc/vps-shadowsocks.json' METHOD='chacha20-ietf-poly1305'
readonly UNIT="/etc/systemd/system/$SERVICE"
readonly LISTEN_TIMEOUT_SECONDS=60
staged_file=''
new_config=false

fail() {
    printf '%s\n' "$@" >&2
    exit 1
}

cleanup() {
    if [[ -n "$staged_file" ]]; then rm -f -- "$staged_file" || true; fi
    if [[ "$new_config" == true ]]; then
        if systemctl disable --now "$SERVICE" >/dev/null 2>&1; then
            rm -f -- "$CONFIG"
        else
            printf '无法清理失败的服务，请检查 %s 和 %s。\n' "$SERVICE" "$CONFIG" >&2
        fi
    fi
}

write_atomic() {
    local destination="$1" mode="$2"
    staged_file="$(mktemp -- "$destination.XXXXXX")"
    cat > "$staged_file"
    chmod "$mode" "$staged_file"
    mv -T -- "$staged_file" "$destination"
    staged_file=''
}

install_packages() {
    local status default_state='' preset_rule="disable $PACKAGE_SERVICE"
    local -a packages=()
    status="$(dpkg-query -W -f='${db:Status-Status}' shadowsocks-libev 2>/dev/null || true)"
    if [[ "$status" != installed || ! -x /usr/bin/ss-server ]]; then
        default_state="$(systemctl show -p LoadState --value "$PACKAGE_SERVICE")"
        case "$default_state" in
            not-found|masked) ;;
            *) fail '检测到已有的 Shadowsocks 套件服务，请先修复原套件安装。' ;;
        esac
        packages+=(shadowsocks-libev)
    fi
    if ! command -v ss >/dev/null || ! command -v ip >/dev/null; then packages+=(iproute2); fi
    if ((${#packages[@]} == 0)); then return; fi

    apt-get -o APT::Update::Error-Mode=any update
    if [[ -n "$default_state" ]]; then
        # Debian 的安装钩子用 preset 决定是否启用默认服务。
        if [[ -e "$PACKAGE_PRESET" || -L "$PACKAGE_PRESET" ]]; then
            [[ ! -L "$PACKAGE_PRESET" && -f "$PACKAGE_PRESET" && "$(<"$PACKAGE_PRESET")" == "$preset_rule" ]] ||
                fail "已有自定义预设文件，未覆盖 $PACKAGE_PRESET。"
        else
            mkdir -p -m 0755 -- "${PACKAGE_PRESET%/*}"
            write_atomic "$PACKAGE_PRESET" 0644 <<< "$preset_rule"
        fi
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${packages[@]}"
    # 如果更高优先级的预设启用了新装的默认服务，停用它以保留单实例。
    if [[ "$default_state" == not-found ]] &&
        { systemctl is-enabled --quiet "$PACKAGE_SERVICE" || systemctl is-active --quiet "$PACKAGE_SERVICE"; }; then
        systemctl disable --now "$PACKAGE_SERVICE"
    fi
}

wait_for_listeners() {
    local port="$1" expected=1 pid='' sockets=''
    local deadline=$((SECONDS + LISTEN_TIMEOUT_SECONDS))
    if [[ "$2" == *::* ]]; then expected=2; fi
    while true; do
        pid="$(systemctl show -p MainPID --value "$SERVICE")" || break
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
    printf '\nShadowsocks 已启动（TCP 与 UDP）。\n端口：%s\n加密：%s\n密码：%s\n' "$port" "$METHOD" "$password"
    if [[ -z "$host" ]]; then
        printf '客户端请填写 VPS 的公网地址或域名，或用 SS_HOST 指定地址后重跑以生成导入链接。\n'
    else
        if [[ "$host" == *:* ]]; then host="[$host]"; fi
        userinfo="$(printf '%s:%s' "$METHOD" "$password" | base64 -w 0 | tr '/+' '_-' | tr -d '=')"
        printf '导入链接：ss://%s@%s:%s\n' "$userinfo" "$host" "$port"
    fi
    printf '若 VPS 有防火墙或安全组，请确认允许此端口的 TCP 和 UDP 入站。\n'
}

main() {
    local port password listeners occupied unit_text load_state active_state
    local log_command="journalctl -u $SERVICE -n 30 --no-pager"
    local config_pattern='^\{"server":(\["0\.0\.0\.0"(,"::")?\]),"server_port":([1-9][0-9]{0,4}),"password":"([0-9a-f]{64})","method":"'"$METHOD"'","mode":"tcp_and_udp"\}$'
    ((EUID == 0)) || fail '请以 root 执行。'
    [[ -r /etc/os-release ]] || fail '无法识别操作系统。'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 12 ]] || fail '此脚本支持 Debian 12。'
    systemctl show -p Version --value >/dev/null || fail '需要运行中的 systemd。'
    if [[ -n "${SS_HOST:-}" && ! "$SS_HOST" =~ ^[a-zA-Z0-9.-]+$ && ! "$SS_HOST" =~ ^[0-9a-fA-F:.]*:[0-9a-fA-F:.]*$ ]]; then
        fail 'SS_HOST 应为 IP 地址或域名，IPv6 无需加方括号。'
    fi

    umask 077
    exec 9>/run/lock/vps-shadowsocks.lock
    flock -n 9 || fail '另一安装进程正在运行。'
    trap cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP

    unit_text="$(cat <<EOF
[Unit]
Description=Shadowsocks server
After=network.target

[Service]
Type=exec
DynamicUser=yes
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LoadCredential=config.json:$CONFIG
ExecStart=/usr/bin/ss-server -c %d/config.json
Restart=on-failure
RestartSec=2s
LimitCORE=0

[Install]
WantedBy=multi-user.target
EOF
)"
    if [[ -e "$UNIT" || -L "$UNIT" ]]; then
        [[ ! -L "$UNIT" && -f "$UNIT" && "$(<"$UNIT")" == "$unit_text" ]] || fail "已有自定义服务文件，未覆盖 $UNIT。"
    else
        load_state="$(systemctl show -p LoadState --value "$SERVICE")"
        [[ "$load_state" == not-found ]] || fail "已有同名服务，未覆盖 $SERVICE。"
    fi

    if [[ -e "$CONFIG" || -L "$CONFIG" ]]; then
        [[ ! -L "$CONFIG" && -f "$CONFIG" && "$(stat -c '%u:%a' -- "$CONFIG")" == 0:600 ]] || fail "请检查 $CONFIG 的类型及权限（root:0600）。"
        [[ "$(<"$CONFIG")" =~ $config_pattern ]] || fail "已有自定义配置，未覆盖 $CONFIG。"
        listeners="${BASH_REMATCH[1]}" port="${BASH_REMATCH[3]}" password="${BASH_REMATCH[4]}"
        ((port <= 65535)) || fail "已有配置的端口无效，请检查 $CONFIG。"
        printf '沿用已保存的端口 %s 和密码。\n' "$port"
    else
        active_state="$(systemctl show -p ActiveState --value "$SERVICE")"
        [[ "$active_state" == inactive || "$active_state" == failed ]] || fail "已有运行中的服务，但缺少 $CONFIG。"
        while true; do
            printf '请输入 Shadowsocks 端口（1–65535）：' >&2
            IFS= read -r port || fail '未输入端口，安装取消。'
            if [[ "$port" =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1 && 10#$port <= 65535)); then
                port=$((10#$port))
                if ! command -v ss >/dev/null; then break; fi
                occupied="$(ss -H -lntu "sport = :$port")"
                if [[ -z "$occupied" ]]; then break; fi
                printf '端口 %s 已被 TCP 或 UDP 服务占用，请另选。\n' "$port" >&2
            else
                printf '端口必须为 1–65535 的整数。\n' >&2
            fi
        done
    fi

    install_packages
    if [[ ! -f "$UNIT" ]]; then write_atomic "$UNIT" 0644 <<< "$unit_text"; fi
    systemctl daemon-reload
    if [[ ! -f "$CONFIG" ]]; then
        occupied="$(ss -H -lntu "sport = :$port")"
        [[ -z "$occupied" ]] || fail "端口 $port 已被占用，请重跑并另选端口。"
        password="$(od -An -v -N32 -tx1 /dev/urandom | tr -d '[:space:]')"
        [[ "$password" =~ ^[0-9a-f]{64}$ ]] || fail '无法生成随机密码。'
        listeners='["0.0.0.0"]'
        if [[ -n "$(ip -o -6 addr show up scope global)" ]]; then listeners='["0.0.0.0","::"]'; fi
        new_config=true
        write_atomic "$CONFIG" 0600 <<< "$(printf '{"server":%s,"server_port":%s,"password":"%s","method":"%s","mode":"tcp_and_udp"}' "$listeners" "$port" "$password" "$METHOD")"
    fi
    if ! systemctl start "$SERVICE"; then
        fail "服务 $SERVICE 启动失败。请执行以下命令查看日志。" "$log_command"
    fi
    printf '等待服务监听 TCP 和 UDP 端口 %s（最长 %s 秒）。\n' "$port" "$LISTEN_TIMEOUT_SECONDS"
    if ! wait_for_listeners "$port" "$listeners"; then
        fail "未能确认服务同时监听 TCP 和 UDP 端口 $port。请执行以下命令查看日志。" "$log_command"
    fi
    systemctl enable "$SERVICE"
    new_config=false
    show_connection "$port" "$password" "$listeners"
}

main "$@"
