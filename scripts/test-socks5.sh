#!/usr/bin/env bash
# Interactive SOCKS5 client diagnostics for Linux.
set -o pipefail
export LC_NUMERIC=C

readonly measure_bytes=10000000
readonly trace_url='https://www.cloudflare.com/cdn-cgi/trace'
readonly ip_url='https://api.ipify.org'
readonly speed_url='https://speed.cloudflare.com'
declare -a summaries=()

read_proxy() {
    local line rest host port user password label
    local -a labels
    while true; do
        printf '请输入 IP:Port:user:passwd（输入隐藏，无认证用 IP:Port::，0 返回）：'
        IFS= read -rs line || { printf '\n'; return 2; }
        printf '\n'
        [[ "$line" != 0 ]] || return 1
        if [[ "$line" != *:*:*:* || "$line" == *$'\r'* ]]; then
            printf '格式错误，请重新输入。\n'; continue
        fi
        host=${line%%:*}; rest=${line#*:}
        port=${rest%%:*}; rest=${rest#*:}
        user=${rest%%:*}; password=${rest#*:}
        if [[ ! "$port" =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1 || 10#$port > 65535 )); then
            printf '端口须为 1 到 65535。\n'; continue
        fi
        if [[ ! "$host" =~ ^[a-zA-Z0-9.-]{1,253}$ || "$host" == *..* || "$host" == .* || "$host" == *. ]]; then
            printf '请输入有效 IPv4 地址或域名。\n'; continue
        fi
        if [[ "$host" =~ ^[0-9.]+$ ]]; then
            if ! python3 -c 'import ipaddress,sys; sys.exit(not isinstance(ipaddress.ip_address(sys.argv[1]), ipaddress.IPv4Address))' "$host" 2>/dev/null; then
                printf 'IPv4 地址无效。\n'; continue
            fi
        else
            IFS=. read -ra labels <<< "$host"
            for label in "${labels[@]}"; do
                if [[ ! "$label" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$ ]]; then
                    printf '域名无效。\n'; continue 2
                fi
            done
        fi
        local LC_ALL=C
        if [[ "$user" =~ [[:cntrl:]] ]]; then
            printf '账号含无效控制字符。\n'; continue
        fi
        if [[ -n "$user" || -n "$password" ]]; then
            if (( ${#user} < 1 || ${#user} > 255 || ${#password} < 1 || ${#password} > 255 )); then
                printf '认证账号和密码各需 1–255 字节，匿名代理请将两者都留空。\n'; continue
            fi
        fi
        proxy_host=$host; proxy_port=$((10#$port))
        proxy_user=$user; proxy_password=$password
        summaries=()
        return 0
    done
}

# Feed credentials through stdin. Quoting here follows curl's config-file syntax.
proxy_curl() {
    local auth config=''
    if [[ -n "$proxy_user" ]]; then
        auth="$proxy_user:$proxy_password"
        auth=${auth//\\/\\\\}
        auth=${auth//\"/\\\"}
        auth=${auth//$'\t'/\\t}
        printf -v config 'proxy-user = "%s"' "$auth"
    fi
    curl -q -4 -s --connect-timeout 5 --max-time 12 --noproxy '' \
        --socks5-hostname "$proxy_host:$proxy_port" --config - "$@" <<< "$config"
}

probe_path() {
    # Flush each stage so an outer timeout retains the last completed TCP connect
    # and the operation that was waiting. Secrets are passed only on stdin.
    printf '%s\n%s\n' "$proxy_user" "$proxy_password" | timeout 8 python3 -u -c '
import http.client
import io
import os
import socket
import ssl
import struct
import sys
from urllib.parse import urlsplit

def take(stream, size):
    data = stream.read(size)
    if len(data) != size:
        raise ValueError("响应不完整")
    return data

def address(stream):
    kind = take(stream, 1)
    if kind == b"\x01":
        host = socket.inet_ntoa(take(stream, 4))
    elif kind == b"\x03":
        host = take(stream, take(stream, 1)[0]).decode("ascii")
    elif kind == b"\x04":
        host = socket.inet_ntop(socket.AF_INET6, take(stream, 16))
    else:
        raise ValueError("未知地址类型")
    return host, int.from_bytes(take(stream, 2), "big")

def request(tcp, reply, command, destination):
    tcp.sendall(bytes((5, command, 0)) + destination)
    version, result, reserved = take(reply, 3)
    if version != 5 or reserved != 0:
        raise ValueError("SOCKS5 响应无效")
    if result:
        reasons = {2: "规则拒绝", 3: "网络不可达", 4: "目的主机不可达", 5: "连接被拒绝",
                   6: "TTL 到期", 7: "不支持该命令", 8: "不支持该地址类型"}
        raise ValueError("SOCKS5 REP 0x%02x（%s）" % (result, reasons.get(result, "代理报告失败")))
    return address(reply)

def stage(name):
    global current_stage
    current_stage = name
    print(name)

def probe():
    user, password = (sys.stdin.buffer.readline().rstrip(b"\n") for _ in range(2))
    method = b"\x02" if user else b"\x00"
    socket.setdefaulttimeout(4)
    stage("连接代理入口")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as tcp:
        tcp.connect((sys.argv[1], int(sys.argv[2])))
        print("TCP_OK")
        with tcp.makefile("rb") as reply:
            stage("SOCKS5 认证")
            tcp.sendall(b"\x05\x01" + method)
            if take(reply, 2) != b"\x05" + method:
                raise ValueError("代理未接受认证方式")
            if user:
                tcp.sendall(b"\x01" + bytes([len(user)]) + user + bytes([len(password)]) + password)
                if take(reply, 2) != b"\x01\x00":
                    raise ValueError("账号或密码被拒绝")
            if sys.argv[3] == "https":
                url = urlsplit(sys.argv[4])
                name = url.hostname.encode("ascii")
                stage("SOCKS5 域名 CONNECT")
                request(tcp, reply, 1, b"\x03" + bytes([len(name)]) + name + struct.pack("!H", 443))
                stage("目标 TLS 握手")
                with ssl.create_default_context().wrap_socket(tcp, server_hostname=url.hostname) as tls:
                    stage("目标 HTTPS 响应")
                    tls.sendall(("GET %s HTTP/1.1\r\nHost: %s\r\nConnection: close\r\n\r\n"
                                 % (url.path, url.hostname)).encode("ascii"))
                    with http.client.HTTPResponse(tls) as response:
                        response.begin()
                        if not 200 <= response.status <= 599:
                            raise ValueError("HTTP 状态码 %s" % response.status)
                        print("HTTP %d" % response.status)
                return
            stage("UDP ASSOCIATE")
            host, port = request(tcp, reply, 3, b"\x01" + bytes(6))
            if host in ("0.0.0.0", "::"):
                host = tcp.getpeername()[0]
            family = socket.AF_INET6 if ":" in host else socket.AF_INET
            stage("解析 UDP 中继地址")
            relay = socket.getaddrinfo(host, port, family, socket.SOCK_DGRAM)[0][4]
            with socket.socket(family, socket.SOCK_DGRAM) as udp:
                stage("UDP 公共 DNS 往返")
                udp.connect(relay)
                resolver = "1.1.1.1"
                header = b"\x00\x00\x00\x01" + socket.inet_aton(resolver) + struct.pack("!H", 53)
                token = os.urandom(2)
                question = b"\x07example\x03com\x00\x00\x01\x00\x01"
                udp.send(header + token + struct.pack("!5H", 0x0100, 1, 0, 0, 0) + question)
                packet = io.BytesIO(udp.recv(4096))
                if take(packet, 3) != bytes(3) or address(packet) != (resolver, 53):
                    raise ValueError("中继回包不匹配")
                ident, flags, questions = struct.unpack("!2sHH", take(packet, 6))
                take(packet, 6)
                if (ident != token or flags & 0xF800 != 0x8000 or questions != 1
                        or take(packet, len(question)).lower() != question):
                    raise ValueError("DNS 回包不匹配")

try:
    probe()
except (OSError, ValueError, http.client.HTTPException) as error:
    if isinstance(error, socket.timeout):
        reason = "超时"
    elif isinstance(error, ssl.SSLCertVerificationError):
        reason = "证书校验失败"
    elif isinstance(error, ValueError) and not isinstance(error, UnicodeError):
        reason = str(error)
    elif isinstance(error, OSError) and error.errno:
        reason = "系统错误 %s" % error.errno
    else:
        reason = "响应无效或连接已关闭"
    print("%s：%s" % (current_stage, reason))
    sys.exit(1)
' "$proxy_host" "$proxy_port" "$1" "$trace_url"
}

store_result() {
    summaries[$1]=$2
    printf '%s\n' "$2"
}

availability_label() {
    case $1 in 3) printf '可用' ;; 0) printf '本次未通' ;; *) printf '部分成功' ;; esac
}

availability() {
    local tcp=0 https=0 udp=0 round path report rc detail summary
    local last_http='' https_failure='' udp_failure=''
    for round in 1 2 3; do
        printf '检测中（第 %s/3 轮）…\n' "$round"
        for path in https udp; do
            rc=0
            report=$(probe_path "$path") || rc=$?
            report=${report//$'\r'/}
            if [[ $path == https && $'\n'$report$'\n' == *$'\nTCP_OK\n'* ]]; then ((tcp+=1)); fi
            if ((rc == 0)); then
                if [[ $path == https ]]; then
                    ((https+=1))
                    last_http=${report##*$'\n'}
                else
                    ((udp+=1))
                fi
                continue
            fi
            detail=${report##*$'\n'}
            if ((rc == 124)); then detail="${detail:-启动探测}：超时"; fi
            detail=${detail:-探测进程失败（退出码 $rc）}
            if [[ $path == https ]]; then https_failure=$detail; else udp_failure=$detail; fi
            printf '  %s\n' "$detail"
        done
    done
    printf -v summary '代理入口 TCP %s（%s/3）\n经代理的域名 HTTPS（%s）%s（%s/3）\nUDP 公共 DNS 往返 %s（%s/3）' \
        "$(availability_label "$tcp")" "$tcp" "${trace_url#https://}" "$(availability_label "$https")" "$https" "$(availability_label "$udp")" "$udp"
    if [[ -n $last_http ]]; then summary+=$'\n'"目标最近响应：$last_http"; fi
    if [[ -n $https_failure ]]; then summary+=$'\n'"域名 HTTPS 最近失败：$https_failure"; fi
    if [[ -n $udp_failure ]]; then summary+=$'\n'"UDP 最近失败：$udp_failure"; fi
    store_result 1 "$summary"
}

ping_entry() {
    local output stats
    if ! command -v ping >/dev/null; then store_result 2 'Ping：缺少 ping，已跳过。'; return; fi
    printf '正在 Ping 代理入口（10 次）…\n'
    output=$(LC_ALL=C ping -4 -n -c 10 -W 2 "$proxy_host" 2>&1)
    printf '%s\n' "$output"
    stats=$(awk '/packet loss|^rtt |^round-trip /' <<< "$output")
    store_result 2 "Ping：${stats:-未取得统计，请检查 ICMP 或 ping 权限。}"
}

valid_ip() {
    python3 -c 'import ipaddress,sys; print(ipaddress.ip_address(sys.stdin.read().strip()))' 2>/dev/null
}

compare_exits() {
    local direct proxy comparison
    direct=$(curl -q -4 -fsS --noproxy '*' --connect-timeout 5 --max-time 12 "$ip_url" 2>/dev/null | valid_ip) || direct=''
    proxy=$(proxy_curl -f "$ip_url" | valid_ip) || proxy=''
    if [[ -z "$direct" || -z "$proxy" ]]; then comparison='未能比对'
    elif [[ $direct == "$proxy" ]]; then comparison='两者相同'
    else comparison='两者不同'; fi
    store_result 3 "本机出口：${direct:-查询失败}　代理出口：${proxy:-查询失败}（$comparison）"
}

exit_info() {
    local info
    if info=$(proxy_curl -f 'https://ipinfo.io/json' | python3 -c '
import json, sys
data = json.load(sys.stdin)
fields = [("国家", "country"), ("地区", "region"), ("城市", "city"), ("ASN/ISP", "org")]
items = ["%s：%s" % (label, data[key]) for label, key in fields if isinstance(data, dict) and isinstance(data.get(key), str) and data[key].isprintable()]
if not items:
    sys.exit(1)
print("　".join(items))' 2>/dev/null); then store_result 4 "$info"
    else store_result 4 '出口归属查询失败。'; fi
}

latency() {
    local i row timings='' summary
    printf '次数   TCP 连接(ms)   首包(ms)      总耗时(ms)\n'
    for ((i=1; i<=10; i++)); do
        if row=$(proxy_curl -o /dev/null -w '%{time_connect} %{time_starttransfer} %{time_total} %{http_code}' "$trace_url") &&
            [[ ${row##* } =~ ^[2-5][0-9]{2}$ ]]; then
            timings+="${row% *}"$'\n'
            awk -v i="$i" '{printf "%2d     %-12.1f   %-12.1f  %.1f\n",i,$1*1000,$2*1000,$3*1000}' <<< "$row"
        else printf '%2d     请求失败\n' "$i"; fi
    done
    summary=$(awk '
        function level(v) {return v<10?"很稳定":(v<30?"正常":(v<60?"波动明显":"抖动较大"))}
        NF==3 {
            n++
            for (i=1; i<=3; i++) {
                ms = $i * 1000
                sum[i] += ms
                if (n > 1) {
                    delta = ms - prev[i]
                    jitter[i] += (delta < 0 ? -delta : delta)
                }
                prev[i] = ms
            }
            total = prev[3]
            if (n == 1 || total < low) low = total
            if (n == 1 || total > high) high = total
        }
        END {
            printf "延迟请求成功 %d/10", n
            if (!n) exit
            split("TCP连接 首包 总耗时", names, " ")
            for (i=1; i<=3; i++) {
                printf "\n%s平均 %.1f ms，抖动 ", names[i], sum[i]/n
                if (n < 2) printf "样本不足"
                else {
                    j = jitter[i] / (n-1)
                    printf "%.1f ms（%s）", j, level(j)
                }
            }
            printf "\n最低/最高总耗时 %.1f / %.1f ms", low, high
        }' <<< "$timings")
    store_result 5 "$summary"
}

transfer() (
    local direction=$1 payload='' stats http bytes seconds rate rc label
    if [[ "$direction" == download ]]; then
        label=下载
        # Keep the body bounded even on older curl when Content-Length is absent.
        stats=$({
            proxy_curl --max-time 240 -f --max-filesize "$measure_bytes" \
                -w '%{stderr}%{http_code} %{size_download} %{time_total} %{speed_download}' \
                "$speed_url/__down?bytes=$measure_bytes" | head -c "$measure_bytes" >/dev/null
        } 2>&1)
        rc=$?
    else
        label=上传
        umask 077
        payload=$(mktemp) || { printf '上传失败：无法准备测试数据。'; return 1; }
        trap 'rm -f -- "$payload"' EXIT
        trap 'exit 1' HUP INT TERM
        head -c "$measure_bytes" /dev/zero > "$payload" || { printf '上传失败：无法生成测试数据。'; return 1; }
        stats=$(proxy_curl --max-time 240 -f -o /dev/null --data-binary "@$payload" \
            -H 'Content-Type: application/octet-stream' -w '%{http_code} %{size_upload} %{time_total} %{speed_upload}' \
            "$speed_url/__up")
        rc=$?
    fi
    read -r http bytes seconds rate <<< "$stats"
    if (( rc != 0 )) || [[ ! $http =~ ^2[0-9]{2}$ || $bytes != "$measure_bytes" ]]; then
        printf '%s失败（HTTP %s，已传输 %s/%s 字节，curl 退出码 %s）。' "$label" "${http:-000}" "${bytes:-0}" "$measure_bytes" "$rc"
        case $rc in 28) printf '请求超时。';; 7) printf '连接失败。';; 97) printf '代理握手失败。';; esac
        return 1
    fi
    awk -v name="$label" -v seconds="$seconds" -v rate="$rate" 'BEGIN {
        printf "%s Cloudflare：10 MB，耗时 %.2f 秒，平均 %.2f Mbps / %.2f MB/s",name,seconds,rate*8/1000000,rate/1000000}'
)

speed() {
    local key=$1 direction=$2 label=$3 result
    printf '%s测速中（Cloudflare，10 MB）…\n' "$label"
    result=$(transfer "$direction")
    store_result "$key" "$result"
}

main() {
    local tool choice entry
    for tool in curl python3 timeout awk head mktemp; do
        command -v "$tool" >/dev/null || { printf '缺少依赖：%s\n' "$tool" >&2; return 1; }
    done
    read_proxy || return 0
    availability
    while true; do
        printf '\nSOCKS5 测试（%s:%s）\n' "$proxy_host" "$proxy_port"
        printf '%s\n' '1. 重测入口 TCP、域名 HTTPS 与 UDP（各 3 次）' '2. Ping 入口（10 次）' \
            '3. 比对本机和代理出口 IP' '4. 查询出口归属与 ASN/ISP' '5. 延迟与抖动（10 次）' \
            '6. 下载测速（10 MB）' '7. 上传测速（10 MB）' '8. 查看当前代理检测摘要' '9. 更换代理' '0. 返回主菜单'
        IFS= read -r -p '请选择：' choice || return 0
        case "$choice" in
            1) availability ;; 2) ping_entry ;; 3) compare_exits ;; 4) exit_info ;; 5) latency ;;
            6) speed 6 download 下载 ;; 7) speed 7 upload 上传 ;;
            8) for entry in "${summaries[@]}"; do printf '%s\n' "$entry"; done ;;
            9) if read_proxy; then availability; elif [[ $? == 2 ]]; then return 0; fi ;;
            0) return 0 ;;
            *) printf '输入错误，请选择菜单中的编号。\n' ;;
        esac
    done
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
