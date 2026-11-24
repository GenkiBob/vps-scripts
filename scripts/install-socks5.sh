#!/usr/bin/env bash
# Debian 12 systemd SOCKS5 instances, including existing Dante instances.
set -euo pipefail
export LC_ALL=C

readonly PROXY_KEY='vps-socks5' PROXY_LABEL='SOCKS5' PROXY_DEFAULT_PORT='50501'
readonly PROXY_PACKAGE='dante-server' PROXY_VENDOR_UNIT='danted.service'
readonly PROXY_LEGACY_CONFIG='/etc/vps-socks5' CONFIG_HEADER='# Managed by install-socks5.sh'
readonly PROXY_UNIT_REFERENCE='(^|[^[:alnum:]_-])(danted|sockd)([^[:alnum:]_-]|$)'
readonly -a PROXY_PROCESS_NAMES=(danted sockd)
readonly -a PROXY_VENDOR_CONFIG=(/etc/danted.conf /etc/default/danted /etc/pam.d/danted)
# shellcheck source=scripts/proxy-manager.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/proxy-manager.sh"
readonly HEV_VERSION='2.13.1' HEV_BINARY="$PROXY_ROOT/.hev-socks5-server"

proxy_hev_release() {
    case "$(dpkg --print-architecture)" in
        amd64) hev_arch=x86_64 hev_asset=506468323 hev_digest=9707a6d9e6419f6474173affa9d00b25a9ec61c9f320f2d19bb14a0a5a584bc5 ;;
        arm64) hev_arch=arm64 hev_asset=506468081 hev_digest=53fb8db2835075f9b0744fe5fa46e308b8fc9d214158e509f4482783799f9b02 ;;
        i386) hev_arch=i686 hev_asset=506468112 hev_digest=cac65599c3a4c2c2b82d16059614ec7785f0da47963cfd0c8a2d1202956137ca ;;
        armhf) hev_arch=arm32v7hf hev_asset=506468077 hev_digest=f77db0a5e8cf97dd72edf8848756a2063dd8d72a90398ecac9a062f7f991be2d ;;
        armel) hev_arch=arm32 hev_asset=506468052 hev_digest=5be596e893f4dc96158f20ea520c791a89928795461fc6b16c933a8eb54212e3 ;;
        ppc64el) hev_arch=powerpc64le hev_asset=506468261 hev_digest=5bce65075c35003b4eb7aa0a0f83f9a2470e1503c981f46e940590a64fe6defd ;;
        s390x) hev_arch=s390x hev_asset=506468314 hev_digest=7672bffdc0b025296cfc71f399c87eb1f6e9b0f3377076065f5b156f7edc7be9 ;;
        *) return 1 ;;
    esac
}

proxy_hev_checksum() {
    printf '%s  %s\n' "$2" "$1" | sha256sum --check --status
}

proxy_install_dependencies() {
    local hev_arch hev_asset hev_digest package
    local -a missing=()
    proxy_hev_release || proxy_fail '此架构没有受支持的 SOCKS5 同端口版本。'
    for package in iproute2 python3; do
        if [[ "$(proxy_package_status "$package")" != installed ]]; then missing+=("$package"); fi
    done
    if ((${#missing[@]} > 0)); then
        apt-get -o APT::Update::Error-Mode=any update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    fi
    if [[ -e "$HEV_BINARY" || -L "$HEV_BINARY" ]]; then
        [[ -f "$HEV_BINARY" ]] && proxy_private "$HEV_BINARY" 755 &&
            proxy_hev_checksum "$HEV_BINARY" "$hev_digest" || proxy_fail '已有 SOCKS5 程序未通过校验。'
        return
    fi
    command -v wget >/dev/null || proxy_fail '首次下载 SOCKS5 需要 wget。'
    proxy_pending="$(mktemp -- "$PROXY_ROOT/.hev-download.XXXXXX")"
    if ! wget --https-only --timeout=30 --tries=2 --no-verbose -O "$proxy_pending" \
        "https://github.com/heiher/hev-socks5-server/releases/download/$HEV_VERSION/hev-socks5-server-linux-$hev_arch" ||
        ! proxy_hev_checksum "$proxy_pending" "$hev_digest"; then
        wget --https-only --timeout=15 --tries=1 --no-verbose -O "$proxy_pending" \
            --header='Accept: application/octet-stream' \
            "https://api.github.com/repos/heiher/hev-socks5-server/releases/assets/$hev_asset"
    fi
    proxy_hev_checksum "$proxy_pending" "$hev_digest" || proxy_fail 'SOCKS5 程序 SHA-256 校验失败。'
    chmod 0755 "$proxy_pending"
    mv -nT -- "$proxy_pending" "$HEV_BINARY"
    [[ ! -e "$proxy_pending" ]] || proxy_fail '已有 SOCKS5 程序，未覆盖。'
    proxy_pending=''
}

proxy_remove_dependencies() {
    local hev_arch hev_asset hev_digest
    [[ -e "$HEV_BINARY" || -L "$HEV_BINARY" ]] || return 0
    if [[ -f "$HEV_BINARY" ]] && proxy_private "$HEV_BINARY" 755 &&
        proxy_hev_release && proxy_hev_checksum "$HEV_BINARY" "$hev_digest"; then
        rm -f -- "$HEV_BINARY"
    else
        printf '保留无法确认归属的 SOCKS5 程序。\n'
    fi
}

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

proxy_dante_record() {
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

proxy_socks_is_hev() {
    local dir unit
    dir="$(proxy_socks_dir "$1")"
    [[ -e "$dir/hev.yml" || -L "$dir/hev.yml" ]] || return 1
    [[ -f "$dir/danted.conf" ]] || return 0
    # A replacement unit commits the conversion when both configurations exist.
    unit="$(proxy_unit "${dir##*/}" "$1")"
    grep -Fxq "ExecStart=$HEV_BINARY $dir/hev.yml" "/etc/systemd/system/$unit" 2>/dev/null
}

proxy_valid_ipv4() {
    local octet a b c d
    [[ "$1" =~ ^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    for octet in "$a" "$b" "$c" "$d"; do ((octet <= 255)) || return 1; done
}

proxy_valid_relay_name() {
    local name="${1%.}" label last_label
    local -a labels
    if proxy_valid_ipv4 "$1"; then return 0; fi
    [[ "${#name}" -le 253 && "$name" == *.* && "$name" != .* &&
        "$name" != *. && "$name" != *..* ]] || return 1
    IFS=. read -r -a labels <<< "$name"
    for label in "${labels[@]}"; do
        [[ "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]] || return 1
        last_label="$label"
    done
    # Numeric endpoints must use the IPv4 syntax checked above.
    [[ "$last_label" == *[a-zA-Z]* ]]
}

proxy_resolve_relay_ipv4() {
    if proxy_valid_ipv4 "$1"; then printf '%s\n' "$1"; return; fi
    timeout 8 python3 -c '
import socket
import sys

try:
    addresses = socket.getaddrinfo(sys.argv[1], None, socket.AF_UNSPEC,
                                   socket.SOCK_STREAM, 0, socket.AI_PASSIVE)
except OSError:
    sys.exit("DDNS 无法解析，请检查 DNS 和 A 记录。")
if any(item[0] == socket.AF_INET6 for item in addresses):
    sys.exit("IPv4 NAT 模式需要仅有 A 记录的 DDNS 域名。")
ipv4 = sorted({item[4][0] for item in addresses if item[0] == socket.AF_INET})
if not ipv4:
    sys.exit("DDNS 域名缺少 IPv4 A 记录。")
print(" ".join(ipv4))
' "$1"
}

proxy_socks_record() {
    local dir config udp_port
    if ! proxy_socks_is_hev "$1"; then
        socks_mode=dante
        socks_relay=''
        proxy_dante_record "$1"
        return
    fi
    dir="$(proxy_socks_dir "$1")"
    config="$dir/hev.yml"
    [[ -f "$config" && -f "$dir/password" ]] && proxy_private "$dir" 700 &&
        proxy_private "$config" 600 && proxy_private "$dir/password" 600 &&
        grep -Fxq "$CONFIG_HEADER" "$config" || return 1
    socks_port="$(sed -n 's/^  port: //p' "$config")"
    udp_port="$(sed -n 's/^  udp-port: //p' "$config")"
    socks_mode="$(sed -n 's/^# Mode: //p' "$config")"
    socks_relay="$(sed -n 's/^  udp-public-address-v4: //p' "$config")"
    socks_user="$(sed -n "s/^  username: '\\(.*\\)'$/\\1/p" "$config")"
    proxy_valid_port "$socks_port" && [[ "$socks_port" == "$udp_port" &&
        "$socks_user" =~ ^[a-zA-Z0-9_.-]{1,64}$ ]] || return 1
    case "$socks_mode" in
        direct) [[ -z "$socks_relay" ]] ;;
        nat) proxy_valid_relay_name "$socks_relay" ;;
        *) return 1 ;;
    esac
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
    if proxy_socks_is_hev "$2"; then
        proxy_hev_unit_text "$2"
    else
        proxy_dante_unit_text "$@"
    fi
}

proxy_hev_unit_text() {
    local dir
    dir="$(proxy_socks_dir "$1")"
    cat <<EOF
[Unit]
Description=Authenticated SOCKS5 proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
ExecStart=$HEV_BINARY $dir/hev.yml
PrivateTmp=yes
ProtectSystem=full
ProtectHome=yes
LimitCORE=0
Restart=on-failure
RestartSec=2s
StandardOutput=null
StandardError=null
InaccessiblePaths=$PROXY_LOG_PATHS

[Install]
WantedBy=multi-user.target
EOF
}

proxy_dante_unit_text() {
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

proxy_read_mode() {
    local choice default=1 saved_relay="${2:-}" label
    if [[ "${1:-}" == nat ]]; then default=2; fi
    label='NAT 公网 IPv4 或 DDNS 域名（域名使用 A 记录，TCP 和 UDP 同端口映射）'
    if [[ -n "$saved_relay" ]]; then label+=" [$saved_relay]"; fi
    while true; do
        choice="$(proxy_prompt "1 公网直连 VPS / 2 NAT VPS [$default]" "$default")"
        case "$choice" in
            1) socks_mode=direct socks_relay=''; return ;;
            2)
                socks_relay="$(proxy_prompt "$label" "$saved_relay")"
                if proxy_valid_relay_name "$socks_relay"; then socks_mode=nat; return; fi
                printf '请输入公网 IPv4 或完整 DDNS 域名。\n'
                ;;
            *) printf '请选择 1 或 2。\n' ;;
        esac
    done
}

proxy_read_credentials() {
    proxy_read_mode
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

proxy_check_relay() {
    if [[ "$socks_mode" == nat ]]; then
        proxy_resolve_relay_ipv4 "$socks_relay" >/dev/null || proxy_fail '无法验证 NAT 中继地址。'
    fi
}

proxy_hev_config() {
    local port="$1" account="$2" secret="$3" quoted
    quoted="$(printf '%s' "$secret" | python3 -c '
import json, sys
value = json.dumps(sys.stdin.buffer.read().decode("utf-8"), ensure_ascii=False)
for char in ("\x85", "\u2028", "\u2029"):
    value = value.replace(char, "\\u%04x" % ord(char))
sys.stdout.buffer.write(value.encode("utf-8"))
')" || proxy_fail '密码须为有效的 UTF-8。'
    printf '%s\n# Mode: %s\nmain:\n  workers: 1\n  listen-address: 0.0.0.0\n  port: %s\n  udp-port: %s\n' \
        "$CONFIG_HEADER" "$socks_mode" "$port" "$port"
    if [[ "$socks_mode" == nat ]]; then printf '  udp-public-address-v4: %s\n' "$socks_relay"; fi
    printf "auth:\n  username: '%s'\n  password: %s\nmisc:\n  log-file: stderr\n  log-level: warn\n" \
        "$account" "$quoted"
}

proxy_create_config() {
    proxy_check_relay
    proxy_hev_config "$1" "$3" "$4" > "$2/hev.yml"
    printf '%s\n' "$4" > "$2/password"
}

proxy_install_protocol_file() {
    if proxy_socks_is_hev "$2"; then return 0; fi
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
    [[ -f "$(proxy_socks_dir "$2")/danted.conf" ]] || return 0
    proxy_check_pam "$1" "$2"
    rm -f -- "/etc/pam.d/$(proxy_pam_name "$1" "$2")"
}

proxy_check_stage() { proxy_only_files "$1" danted.conf users password hev.yml; }

proxy_check_removal() {
    if [[ -f "$(proxy_socks_dir "$2")/danted.conf" ]]; then proxy_check_pam "$1" "$2"; fi
    proxy_check_stage "$(proxy_socks_dir "$2")"
}

proxy_remove_stage() {
    rm -f -- "$1/danted.conf" "$1/users" "$1/password" "$1/hev.yml"
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

probe_hev_socks5() {
    local relay_addresses status=0
    relay_addresses="$(proxy_resolve_relay_ipv4 "$4")" || return 1
    # The probes send data through real SOCKS5 sessions to local echo sockets.
    printf '%s\n%s\n' "$2" "$3" | timeout 15 python3 -c '
import ipaddress
import socket
import struct
import sys

port = int(sys.argv[1])
relay_addresses = {ipaddress.ip_address(value) for value in sys.argv[2].split()}
account = sys.stdin.buffer.readline().rstrip(b"\n")
password = sys.stdin.buffer.readline().rstrip(b"\n")
local = "127.0.0.1"
socket.setdefaulttimeout(4)

def receive(sock, size):
    data = b""
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise OSError("short SOCKS5 reply")
        data += chunk
    return data

def address(ip, port):
    return b"\x01" + socket.inet_aton(ip) + struct.pack("!H", port)

def authenticate(sock):
    sock.sendall(b"\x05\x01\x02")
    if receive(sock, 2) != b"\x05\x02":
        raise OSError("unexpected authentication method")
    sock.sendall(bytes((1, len(account))) + account + bytes((len(password),)) + password)
    if receive(sock, 2) != b"\x01\x00":
        raise OSError("SOCKS5 authentication failed")

def request(sock, command, target):
    sock.sendall(bytes((5, command, 0)) + address(*target))
    version, result, reserved, family = receive(sock, 4)
    if (version, result, reserved) != (5, 0, 0) or family not in (1, 4):
        raise OSError("SOCKS5 request rejected")
    ip = ipaddress.ip_address(receive(sock, 4 if family == 1 else 16))
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    return ip, struct.unpack("!H", receive(sock, 2))[0]

phase = "TCP 连接与认证"
try:
    with socket.socket() as server, socket.create_connection((local, port)) as control:
        server.bind((local, 0))
        server.listen(1)
        authenticate(control)
        phase = "TCP CONNECT"
        request(control, 1, server.getsockname())
        connection, _ = server.accept()
        phase = "TCP 本机转发"
        with connection:
            control.sendall(b"tcp")
            if receive(connection, 3) != b"tcp":
                raise OSError("invalid TCP relay payload")
            connection.sendall(b"ok")
            if receive(control, 2) != b"ok":
                raise OSError("invalid TCP relay response")

    phase = "UDP 会话认证"
    with socket.socket(type=socket.SOCK_DGRAM) as server, \
         socket.socket(type=socket.SOCK_DGRAM) as client, \
         socket.create_connection((local, port)) as control:
        server.bind((local, 0))
        client.bind((local, 0))
        authenticate(control)
        phase = "UDP ASSOCIATE 中继地址与端口"
        relay_address, relay_port = request(control, 3, client.getsockname())
        if relay_address not in relay_addresses or relay_port != port:
            raise OSError("unexpected UDP relay address or port")
        header = b"\x00\x00\x00" + address(*server.getsockname())
        # The public NAT address is checked above. The local probe bypasses NAT.
        phase = "UDP 本机转发"
        client.sendto(header + b"udp", (local, port))
        payload, peer = server.recvfrom(65535)
        if payload != b"udp":
            raise OSError("invalid UDP relay payload")
        server.sendto(b"ok", peer)
        if client.recvfrom(65535) != (header + b"ok", (local, port)):
            raise OSError("invalid UDP relay response")
except (OSError, ValueError, struct.error) as error:
    sys.exit(f"{phase}: {error}")
' "$1" "$relay_addresses" || status=$?
    if ((status == 124)); then printf 'TCP/UDP 转发探测超时。\n' >&2; fi
    return "$status"
}

proxy_wait_start() {
    local port="$1" kind="$2" unit secret deadline result=''
    local socks_port socks_user socks_hash socks_mode socks_relay
    if ! proxy_socks_is_hev "$kind"; then proxy_wait "$@"; return; fi
    unit="$(proxy_unit "$port" "$kind")"
    proxy_socks_record "$kind" || { printf '无法读取 SOCKS5 实例配置。\n' >&2; return 1; }
    IFS= read -r secret < "$(proxy_socks_dir "$kind")/password" ||
        { printf '无法读取 SOCKS5 实例密码。\n' >&2; return 1; }
    deadline=$((SECONDS + 60))
    until systemctl is-active --quiet "$unit" && probe_socks5 "$port" "$socks_user" "$secret"; do
        if ((SECONDS >= deadline)); then
            printf 'SOCKS5 本机 TCP 连接或认证未通过。\n' >&2
            return 1
        fi
        sleep 1
    done
    if result="$(probe_hev_socks5 "$port" "$socks_user" "$secret" "${socks_relay:-127.0.0.1}" 2>&1)"; then
        printf 'SOCKS5 本机 TCP 和 UDP 转发验证通过。\n'
        return 0
    fi
    if systemctl is-active --quiet "$unit" && probe_socks5 "$port" "$socks_user" "$secret"; then
        printf 'SOCKS5 TCP 认证通过，保留服务运行。转发探测未通过：%s\n' "${result:-探测超时或解析失败。}" >&2
        return 0
    fi
    printf 'SOCKS5 转发探测后，TCP 连接或认证未通过：%s\n' "${result:-请查看临时日志。}" >&2
    return 1
}

proxy_wait() {
    local port="$1" kind="$2" account="${3:-}" secret="${4:-}" unit deadline result=''
    local socks_mode=dante socks_port socks_user socks_relay socks_hash
    unit="$(proxy_unit "$port" "$kind")"
    proxy_socks_record "$kind" || return 1
    if [[ "$socks_mode" != dante && -z "$account" ]]; then
        account="$socks_user"
        IFS= read -r secret < "$(proxy_socks_dir "$kind")/password" || return 1
    fi
    deadline=$((SECONDS + 60))
    while ((SECONDS < deadline)); do
        if systemctl is-active --quiet "$unit"; then
            if [[ "$socks_mode" == dante ]]; then
                if probe_socks5 "$port" "$account" "$secret"; then return 0; fi
            elif result="$(probe_hev_socks5 "$port" "$account" "$secret" "${socks_relay:-127.0.0.1}" 2>&1)"; then
                return 0
            fi
        fi
        sleep 1
    done
    if [[ -n "$result" ]]; then printf 'SOCKS5 本机验证失败：%s\n' "$result" >&2; fi
    return 1
}

proxy_verify_dante_password() {
    local secret="$1" hash="$2" salt verified
    [[ "$hash" =~ ^\$6\$([./A-Za-z0-9]{1,16})\$[./A-Za-z0-9]{86}$ ]] ||
        proxy_fail '不能验证此旧密码哈希格式。'
    salt="${BASH_REMATCH[1]}"
    verified="$(printf '%s\n' "$secret" | openssl passwd -6 -salt "$salt" -stdin)"
    [[ "$verified" == "$hash" ]] || proxy_fail '密码验证失败。'
}

proxy_show() {
    local port="$1" kind="$2" socks_port socks_user socks_hash socks_mode socks_relay password_file secret
    proxy_socks_record "$kind" || proxy_fail '无法读取实例连接信息。'
    case "$socks_mode" in
        direct) printf '模式：公网直连 VPS\n端口：%s（TCP + UDP）\n' "$port" ;;
        nat) printf '模式：NAT VPS\n端口：%s（TCP + UDP）\n公网 UDP 中继：%s:%s\n' "$port" "$socks_relay" "$port" ;;
        dante) printf '端口：%s（TCP）\nUDP ASSOCIATE 使用会话分配的中继端口。\n' "$port" ;;
    esac
    printf '账号：%s\n' "$socks_user"
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
        proxy_verify_dante_password "$secret" "$socks_hash"
        proxy_write "$password_file" 0600 "$secret"
        printf '已补录通过验证的原密码。\n密码：%s\n' "$secret"
    else
        printf '未找到可显示的密码。\n'
    fi
}

proxy_run_hev_debug() (
    local config=$1 pid current_pid scratch='' snapshot=''
    local -a dns_options=()
    shift
    if [[ $debug_resume == true ]]; then
        pid=$(systemctl show -p MainPID --value "$debug_normal") && [[ $pid =~ ^[1-9][0-9]*$ ]] ||
            { printf '无法确认正式实例 PID，取消调试。\n' >&2; return 1; }
        scratch=$(mktemp -d /run/vps-socks5-debug-dns.XXXXXXXX) || return 1
        snapshot="$scratch/resolv.conf"
        trap 'if [[ -d $scratch ]]; then rm -f -- "$snapshot"; rmdir -- "$scratch"; fi' EXIT
        trap 'exit 1' HUP INT TERM
        # Copy before Conflicts= stops the original process and its mount namespace.
        if ! nsenter --target "$pid" --mount --root -- /bin/cat /etc/resolv.conf > "$snapshot"; then
            printf '无法读取正式实例的 DNS 配置，取消调试。\n' >&2; return 1
        fi
        current_pid=$(systemctl show -p MainPID --value "$debug_normal") && [[ $current_pid == "$pid" ]] ||
            { printf '正式实例在读取 DNS 时已切换，取消调试。\n' >&2; return 1; }
        dns_options=(-p "RuntimeDirectory=${scratch##*/}" -p RuntimeDirectoryMode=0700
            -p "BindReadOnlyPaths=$snapshot:/etc/resolv.conf")
        if cmp -s /etc/resolv.conf "$snapshot"; then
            printf '临时日志沿用正式实例的 DNS 配置。\n'
        else
            printf '正式实例与本机的 DNS 配置不同，临时日志沿用正式实例的配置。\n'
        fi
    else
        printf '正式实例已停止，无法读取其运行时 DNS；本次临时日志使用本机 DNS。\n'
    fi
    systemd-run "$@" "${dns_options[@]}" -p Type=exec -p PrivateTmp=yes -p ProtectSystem=full -p ProtectHome=yes \
        /bin/bash -c '
            if [[ -n $3 ]] && ! cmp -s -- "$3" /etc/resolv.conf; then
                printf "临时实例的 DNS 与正式实例快照不一致，取消调试。\n" >&2
                exit 1
            fi
            exec "$1" /dev/fd/3 3< <(sed "s/^  log-level: warn$/  log-level: debug/" "$2")
        ' bash "$HEV_BINARY" "$config" "$snapshot"
)

proxy_run_debug() {
    local port="$1" kind="$2" dir
    shift 2
    dir="$(proxy_socks_dir "$kind")"
    if proxy_socks_is_hev "$kind"; then
        proxy_run_hev_debug "$dir/hev.yml" "$@"
        return
    fi
    proxy_check_pam "$port" "$kind"
    systemd-run "$@" -p Type=exec -p PrivateTmp=yes -p ProtectSystem=full -p ProtectHome=yes \
        -p "RuntimeDirectory=$PROXY_KEY-debug-$port" \
        /usr/sbin/danted -d1 -f "$dir/danted.conf" -p "/run/$PROXY_KEY-debug-$port/danted.pid"
}

proxy_replace_socks_file() {
    local path="$1" content="$2" mode="$3"
    proxy_pending="$(mktemp -- "$path.XXXXXX")" || return 1
    printf '%s\n' "$content" > "$proxy_pending" && chmod "$mode" "$proxy_pending" &&
        mv -fT -- "$proxy_pending" "$path" || return 1
    proxy_pending=''
}

proxy_finish_conversion() {
    proxy_cleanup_pending
    if [[ "$conversion_started" == true ]]; then
        if ! systemctl stop "$unit" || ! proxy_stopped "$unit" ||
            ! proxy_replace_socks_file "$switch_file" "$original_content" "$switch_mode" ||
            ! systemctl daemon-reload; then
            proxy_cleanup_pending
            printf '无法恢复原服务 %s，已保留实例配置以便诊断。\n' "$unit" >&2
            return 1
        fi
    fi
    if [[ "$conversion_created" == true ]]; then rm -f -- "$dir/hev.yml"; fi
    if [[ "$conversion_password_created" == true ]]; then rm -f -- "$dir/password"; fi
    if [[ "$conversion_started" == true && "$previous_state" == active ]]; then
        if ! systemctl start "$unit" || ! proxy_wait "$port" "$kind" "$socks_user" "$secret"; then
            printf '原服务配置已恢复，实例启动验证失败，请查看临时日志。\n' >&2
            return 1
        fi
    fi
    if [[ "$conversion_started" == true ]]; then printf '已恢复原服务及其状态。\n' >&2; fi
}

proxy_convert() {
    local port="$1" kind="$2" dir unit previous_state secret config occupied
    local socks_user socks_port socks_hash socks_mode socks_relay
    local previous_mode previous_relay switch_file original_content switch_mode
    local conversion_started=false conversion_created=false conversion_password_created=false
    proxy_assert_no_debug "$port"
    proxy_check_unit "$port" "$kind"
    proxy_check_removal "$port" "$kind"
    proxy_socks_record "$kind" || proxy_fail '无法读取原实例配置。'
    previous_mode="$socks_mode"
    previous_relay="$socks_relay"
    dir="$(proxy_socks_dir "$kind")"
    unit="$(proxy_unit "$port" "$kind")"
    previous_state="$(proxy_state "$unit")" || proxy_fail '无法查询原服务状态。'
    if [[ "$previous_state" != active ]]; then
        proxy_stopped "$unit" || proxy_fail '实例正在切换状态，请稍后重试。'
    fi
    if [[ -f "$dir/password" ]]; then
        IFS= read -r secret < "$dir/password" || proxy_fail '无法读取原密码。'
    else
        secret="$(proxy_prompt '输入原密码以保留当前账号' '' secret)"
    fi
    proxy_valid_password "$secret" || proxy_fail '原密码无效。'
    if [[ "$previous_mode" == dante ]]; then proxy_verify_dante_password "$secret" "$socks_hash"; fi
    proxy_read_mode "$previous_mode" "$previous_relay"
    if [[ "$socks_mode" == "$previous_mode" && "$socks_relay" == "$previous_relay" ]]; then
        printf '当前配置已符合所选设置。\n'
        return
    fi
    printf '端口 %s 将保留原账号和密码。在线连接会短暂中断。\n' "$port"
    proxy_confirm '确认应用该实例的新设置' || return 0
    if [[ ! -d "$PROXY_ROOT" ]]; then mkdir -m 0700 -- "$PROXY_ROOT"; fi
    proxy_install_dependencies
    proxy_check_relay
    if [[ "$previous_mode" == dante ]]; then
        config="$(proxy_hev_config "$port" "$socks_user" "$secret")"
    else
        config="$(awk -v mode="$socks_mode" -v relay="$socks_relay" '
            /^# Mode: / { print "# Mode: " mode; next }
            /^  udp-public-address-v4: / { next }
            { print }
            /^  udp-port: / && mode == "nat" { print "  udp-public-address-v4: " relay }
        ' "$dir/hev.yml")"
    fi
    proxy_prepare_unit "$port" "$kind"
    switch_file="$dir/hev.yml"
    switch_mode=0600
    if [[ "$previous_mode" == dante ]]; then
        switch_file="/etc/systemd/system/$unit"
        switch_mode=0644
    fi
    original_content="$(<"$switch_file")"
    trap proxy_finish_conversion EXIT
    if [[ "$previous_mode" == dante ]]; then
        if [[ ! -e "$dir/hev.yml" && ! -L "$dir/hev.yml" ]]; then conversion_created=true; fi
        proxy_write "$dir/hev.yml" 0600 "$config"
        if [[ ! -e "$dir/password" && ! -L "$dir/password" ]]; then conversion_password_created=true; fi
        proxy_write "$dir/password" 0600 "$secret"
        config="$(proxy_hev_unit_text "$kind")"
    fi

    conversion_started=true
    systemctl stop "$unit"
    proxy_stopped "$unit" || proxy_fail '无法确认原服务已停止。'
    occupied="$(ss -H -lntu "sport = :$port")"
    [[ -z "$occupied" ]] || proxy_fail "端口 $port 仍被其他服务占用。"
    proxy_replace_socks_file "$switch_file" "$config" "$switch_mode"
    systemctl daemon-reload
    systemctl reset-failed "$unit" 2>/dev/null || true
    systemctl start "$unit" && proxy_wait "$port" "$kind" "$socks_user" "$secret" ||
        proxy_fail '新设置验证失败，正在恢复原服务。'
    if [[ "$previous_state" != active ]]; then
        systemctl stop "$unit"
        proxy_stopped "$unit" || proxy_fail '无法恢复实例的停止状态。'
    fi
    trap proxy_cleanup_pending EXIT
    printf '端口 %s 已应用新设置，本机 TCP 和 UDP 转发验证通过。\n' "$port"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then proxy_menu "$@"; fi
