# Shared Debian 12/systemd management. Sourced by the protocol entry points.
readonly PROXY_LEGACY="$PROXY_KEY.service"
readonly PROXY_ROOT="/etc/$PROXY_KEY.d"
readonly PROXY_PRESET="/etc/systemd/system-preset/00-$PROXY_KEY.preset"
readonly PROXY_SILENT_NAME='90-vps-scripts-silent.conf'
readonly PROXY_LOG_PATHS='-/dev/log -/run/systemd/journal/dev-log -/run/systemd/journal/socket'
readonly PROXY_SILENT="[Service]
StandardOutput=null
StandardError=null
InaccessiblePaths=$PROXY_LOG_PATHS"
declare -a proxy_ports=()
declare -A proxy_instances=()
proxy_pending=''
install_stage='' install_prepared=false install_published=false

proxy_fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

proxy_private() {
    [[ ! -L "$1" && "$(stat -c '%u:%a' -- "$1" 2>/dev/null)" == "0:$2" ]]
}

proxy_only_files() {
    local dir="$1" path name allowed
    shift
    [[ -d "$dir" ]] && proxy_private "$dir" 700 || proxy_fail "无法确认目录 $dir 的归属。"
    for path in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [[ -e "$path" || -L "$path" ]] || continue
        name="${path##*/}"
        for allowed in "$@"; do
            if [[ "$name" == "$allowed" && -f "$path" ]] && proxy_private "$path" 600; then continue 2; fi
        done
        proxy_fail "目录 $dir 含有未识别的文件，未删除实例。"
    done
}

proxy_cleanup_pending() {
    if [[ -n "$proxy_pending" ]]; then rm -f -- "$proxy_pending" || true; fi
}

proxy_write() {
    local target="$1" mode="$2" content="$3"
    if [[ -e "$target" || -L "$target" ]]; then
        [[ ! -L "$target" && -f "$target" && "$(<"$target")" == "$content" ]] ||
            proxy_fail "已有自定义文件，未覆盖 $target。"
        return
    fi
    proxy_pending="$(mktemp -- "$target.XXXXXX")"
    printf '%s\n' "$content" > "$proxy_pending"
    chmod "$mode" "$proxy_pending"
    mv -nT -- "$proxy_pending" "$target"
    [[ ! -e "$proxy_pending" ]] || proxy_fail "文件已存在，未覆盖 $target。"
    proxy_pending=''
}

proxy_valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( $1 <= 65535 ))
}

proxy_random_hex() {
    local bytes="$1" value
    value="$(od -An -v -N "$bytes" -tx1 /dev/urandom | tr -d '[:space:]')" || proxy_fail '无法读取系统随机数。'
    [[ "$value" =~ ^[0-9a-f]+$ ]] && ((${#value} == bytes * 2)) || proxy_fail '随机数长度错误。'
    printf '%s' "$value"
}

proxy_prompt() {
    local label="$1" fallback="$2" value
    printf '%s：' "$label" >&2
    if [[ "${3:-}" == secret ]]; then
        IFS= read -rs value || proxy_fail '输入已结束，操作取消。'
        printf '\n' >&2
    else
        IFS= read -r value || proxy_fail '输入已结束，操作取消。'
    fi
    printf '%s' "${value:-$fallback}"
}

proxy_confirm() {
    local answer
    printf '%s [y/N]：' "$1"
    if IFS= read -r answer && [[ "$answer" == [yY] ]]; then return 0; fi
    printf '未确认，返回上一级。\n'
    return 1
}

proxy_unit() {
    if [[ "$2" == legacy ]]; then printf '%s' "$PROXY_LEGACY"
    else printf '%s-%s.service' "$PROXY_KEY" "$1"; fi
}

proxy_debug_unit() { printf '%s-debug-%s.service' "$PROXY_KEY" "$1"; }

proxy_state() {
    local state
    state="$(systemctl show -p ActiveState --value "$1")" || return 1
    [[ -n "$state" ]] || return 1
    printf '%s' "$state"
}

proxy_stopped() {
    local state pid
    state="$(proxy_state "$1")" || return 1
    [[ "$state" == inactive || "$state" == failed ]] || return 1
    pid="$(systemctl show -p MainPID --value "$1")" || return 1
    [[ -z "$pid" || "$pid" == 0 ]]
}

proxy_check_unit() {
    local port="$1" kind="$2" unit path fragment dropins owned_dropin
    unit="$(proxy_unit "$port" "$kind")"
    path="/etc/systemd/system/$unit"
    fragment="$(systemctl show -p FragmentPath --value "$unit")" || proxy_fail "无法确认 $unit 的归属。"
    [[ -z "$fragment" || "$fragment" == "$path" ]] || proxy_fail "检测到外部服务 $unit，操作取消。"
    if [[ -e "$path" || -L "$path" ]]; then
        [[ ! -L "$path" && -f "$path" ]] || proxy_fail "无法确认 $path 的归属。"
        [[ "$(<"$path")" == "$(proxy_unit_text "$port" "$kind")" ]] || proxy_fail "检测到自定义服务 $unit，操作取消。"
    fi
    dropins="$(systemctl show -p DropInPaths --value "$unit")" || proxy_fail "无法读取 $unit 的覆盖配置。"
    if [[ -n "$dropins" ]]; then
        owned_dropin="$(proxy_instance_dropin "$port" "$kind")"
        [[ "$dropins" == "$owned_dropin" && -f "$owned_dropin" && ! -L "$owned_dropin" &&
            "$(<"$owned_dropin")" == "$PROXY_SILENT" ]] || proxy_fail "检测到额外服务配置 $unit，操作取消。"
    fi
}

proxy_scan() {
    local path port
    local -a found=()
    proxy_ports=()
    proxy_instances=()
    if [[ -e "$PROXY_LEGACY_CONFIG" || -L "$PROXY_LEGACY_CONFIG" ]]; then
        if port="$(proxy_config_port legacy)" && proxy_valid_port "$port"; then
            proxy_instances["$port"]=legacy
            found+=("$port")
        else
            printf '无法识别旧配置 %s，请检查后再操作。\n' "$PROXY_LEGACY_CONFIG" >&2
            return 1
        fi
    fi
    if [[ -e "$PROXY_ROOT" || -L "$PROXY_ROOT" ]]; then
        [[ -d "$PROXY_ROOT" ]] && proxy_private "$PROXY_ROOT" 700 || {
            printf '请检查实例目录 %s 的类型和权限。\n' "$PROXY_ROOT" >&2
            return 1
        }
        for path in "$PROXY_ROOT"/*; do
            [[ -e "$path" || -L "$path" ]] || continue
            port="${path##*/}"
            if ! proxy_valid_port "$port" || ! proxy_private "$path" 700 ||
                [[ ! -d "$path" || -n "${proxy_instances[$port]:-}" ]] ||
                [[ "$(proxy_config_port "$path")" != "$port" ]]; then
                printf '无法识别实例目录 %s，请检查后再操作。\n' "$path" >&2
                return 1
            fi
            proxy_instances["$port"]="$path"
            found+=("$port")
        done
    fi
    if ((${#found[@]} > 0)); then
        mapfile -t proxy_ports < <(printf '%s\n' "${found[@]}" | sort -n)
    fi
}

proxy_list() {
    local port unit state label i=1
    if ((${#proxy_ports[@]} == 0)); then
        printf '状态：未安装\n'
        return
    fi
    for port in "${proxy_ports[@]}"; do
        unit="$(proxy_unit "$port" "${proxy_instances[$port]}")"
        state="$(proxy_state "$unit")" || return 1
        if [[ "$state" == active ]]; then label='在线'
        elif systemctl is-active --quiet "$(proxy_debug_unit "$port")"; then label='在线（调试）'
        else label='停止'; fi
        printf '%d. %s  端口 %s\n' "$i" "$label" "$port"
        ((i+=1))
    done
}

proxy_select() {
    local choice
    if ((${#proxy_ports[@]} == 0)); then
        printf '当前没有可操作的实例。\n' >&2
        return 1
    fi
    proxy_list >&2 || return 1
    printf '输入实例编号（回车返回）：' >&2
    IFS= read -r choice || return 1
    [[ -n "$choice" ]] || return 1
    if ! [[ "$choice" =~ ^[1-9][0-9]{0,4}$ ]] || ((choice > ${#proxy_ports[@]})); then
        printf '实例编号无效。\n' >&2
        return 1
    fi
    printf '%s' "${proxy_ports[choice-1]}"
}

proxy_preset_content() { printf 'disable %s' "$PROXY_VENDOR_UNIT"; }

proxy_package_status() {
    dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null || true
}

proxy_package_fingerprint() {
    local path
    for path in "${PROXY_VENDOR_CONFIG[@]}"; do
        if [[ -d "$path" && ! -L "$path" ]]; then
            find "$path" -printf '%y %p %l\n' | sort || return 1
            find "$path" -type f -exec sha256sum {} + | sort || return 1
        elif [[ -f "$path" && ! -L "$path" ]]; then
            sha256sum -- "$path" || return 1
        else
            printf '%s %s\n' "$(readlink -- "$path" 2>/dev/null || true)" "$path"
        fi
    done
}

proxy_vendor_config_exists() {
    local path
    for path in "${PROXY_VENDOR_CONFIG[@]}"; do
        if [[ -e "$path" || -L "$path" ]]; then return 0; fi
    done
    return 1
}

proxy_install_packages() {
    local package state='' status owned=false fingerprint
    local -a missing=()
    for package in "${PROXY_PACKAGES[@]}"; do
        if [[ "$(proxy_package_status "$package")" != installed ]]; then missing+=("$package"); fi
    done
    ((${#missing[@]} > 0)) || return 0
    if [[ "${missing[0]}" == "$PROXY_PACKAGE" ]]; then
        status="$(proxy_package_status "$PROXY_PACKAGE")"
        state="$(systemctl show -p LoadState --value "$PROXY_VENDOR_UNIT")"
        case "$state" in
            not-found|masked) ;;
            *) proxy_fail "检测到已有的 $PROXY_PACKAGE 服务，请先修复原软件包安装。" ;;
        esac
        if [[ -z "$status" && "$state" == not-found ]] && ! proxy_vendor_config_exists; then owned=true; fi
    fi
    apt-get -o APT::Update::Error-Mode=any update
    if [[ -n "$state" ]]; then
        mkdir -p -m 0755 -- "${PROXY_PRESET%/*}"
        proxy_write "$PROXY_PRESET" 0644 "$(proxy_preset_content)"
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
    if [[ "$state" == not-found ]] &&
        { systemctl is-enabled --quiet "$PROXY_VENDOR_UNIT" || systemctl is-active --quiet "$PROXY_VENDOR_UNIT"; }; then
        systemctl disable --now "$PROXY_VENDOR_UNIT"
    fi
    if [[ "$owned" == true ]]; then
        fingerprint="$(proxy_package_fingerprint | sha256sum)"
        proxy_write "$PROXY_ROOT/.package" 0600 "$fingerprint"
    fi
}

proxy_install_dependencies() { proxy_install_packages; }

proxy_package_unused() {
    local name units path state current
    local owner="$PROXY_ROOT/.package"
    [[ -f "$owner" ]] && proxy_private "$owner" 600 || return 1
    current="$(proxy_package_fingerprint | sha256sum)" || return 1
    [[ "$(<"$owner")" == "$current" ]] && proxy_stopped "$PROXY_VENDOR_UNIT" || return 1
    state="$(systemctl show -p UnitFileState --value "$PROXY_VENDOR_UNIT")" || return 1
    [[ "$state" == disabled || "$state" == masked || "$state" == '' ]] || return 1
    command -v pgrep >/dev/null || return 1
    for name in "${PROXY_PROCESS_NAMES[@]}"; do
        if pgrep -x "$name" >/dev/null; then return 1
        elif [[ $? != 1 ]]; then return 1; fi
    done
    # Look for other consumers, including stopped custom units and vendor template instances.
    units="$(find /etc/systemd/system /run/systemd/system \
        \( -type f -o -type l \) \( -name '*.service' -o -name '*.conf' \) -print 2>/dev/null)" || return 1
    while IFS= read -r path; do
        [[ -f "$path" ]] || continue
        if grep -Eq "$PROXY_UNIT_REFERENCE" "$path"; then return 1; fi
    done <<< "$units"
    return 0
}

proxy_purge_package() {
    local simulation
    [[ "$(proxy_package_status "$PROXY_PACKAGE")" == installed ]] || return 0
    if ! proxy_package_unused; then
        printf '保留 %s：无法确认软件包由本脚本独占使用。\n' "$PROXY_PACKAGE"
        return 0
    fi
    if ! simulation="$(LC_ALL=C apt-get --simulate -o APT::Get::AutomaticRemove=false purge "$PROXY_PACKAGE")" ||
        ! awk -v wanted="$PROXY_PACKAGE" '
            $1=="Purg" || $1=="Remv" { split($2, p, ":"); if (p[1]==wanted) found=1; else extra=1 }
            $1=="Inst" || $1=="Conf" { extra=1 }
            END { exit !(found && !extra) }
        ' <<< "$simulation"; then
        printf '保留 %s：无法安全地单独卸载此软件包。\n' "$PROXY_PACKAGE"
        return 0
    fi
    DEBIAN_FRONTEND=noninteractive apt-get purge -y -o APT::Get::AutomaticRemove=false "$PROXY_PACKAGE"
}

proxy_assert_no_debug() {
    local state
    state="$(proxy_state "$(proxy_debug_unit "$1")")" || proxy_fail '无法查询调试服务状态。'
    [[ "$state" == inactive || "$state" == failed ]] || proxy_fail '该实例正在调试，请先退出临时日志。'
}

proxy_assert_free_port() {
    local port="$1" occupied
    [[ -z "${proxy_instances[$port]:-}" ]] || proxy_fail "端口 $port 已有实例。"
    # A saved port is reserved even while the other protocol's instance is stopped.
    proxy_other_uses_port "$port" && proxy_fail "端口 $port 已由另一代理实例登记。"
    occupied="$(ss -H -lntu "sport = :$port")" || proxy_fail '无法检查端口占用。'
    [[ -z "$occupied" ]] || proxy_fail "端口 $port 已被占用。"
}

proxy_instance_dropin() {
    printf '/etc/systemd/system/%s.d/%s' "$(proxy_unit "$1" "$2")" "$PROXY_SILENT_NAME"
}

proxy_prepare_unit() {
    local port="$1" kind="$2" unit path
    unit="$(proxy_unit "$port" "$kind")"
    proxy_check_unit "$port" "$kind"
    path="/etc/systemd/system/$unit"
    if [[ ! -f "$path" ]]; then
        proxy_write "$path" 0644 "$(proxy_unit_text "$port" "$kind")"
    fi
    if [[ "$kind" == legacy ]]; then
        path="$(proxy_instance_dropin "$port" "$kind")"
        [[ ! -L "${path%/*}" ]] || proxy_fail "无法确认 $path 的归属。"
        if [[ ! -d "${path%/*}" ]]; then mkdir -m 0755 -- "${path%/*}"; fi
        proxy_write "$path" 0644 "$PROXY_SILENT"
    fi
    proxy_install_protocol_file "$port" "$kind"
    systemctl daemon-reload
}

proxy_wait_start() { proxy_wait "$@"; }

proxy_start() {
    local port="$1" kind="$2" unit state
    unit="$(proxy_unit "$port" "$kind")"
    proxy_assert_no_debug "$port"
    proxy_check_unit "$port" "$kind"
    state="$(proxy_state "$unit")" || proxy_fail "无法查询 $unit。"
    if [[ "$state" == active ]]; then
        printf '端口 %s 已在线。\n' "$port"
        return
    fi
    proxy_stopped "$unit" || proxy_fail '实例正在切换状态，请稍后再试。'
    proxy_prepare_unit "$port" "$kind"
    systemctl reset-failed "$unit" 2>/dev/null || true
    if ! systemctl start "$unit" || ! proxy_wait_start "$port" "$kind" || ! systemctl enable "$unit"; then
        systemctl disable --now "$unit" || printf '无法清理启动失败的实例，请检查 %s。\n' "$unit" >&2
        proxy_fail '启动验证失败，可选择临时日志进行诊断。'
    fi
    printf '端口 %s 已在线。\n' "$port"
}

proxy_stop() {
    local port="$1" kind="$2" unit
    unit="$(proxy_unit "$port" "$kind")"
    proxy_assert_no_debug "$port"
    proxy_check_unit "$port" "$kind"
    if [[ -f "/etc/systemd/system/$unit" ]]; then
        systemctl disable --now "$unit" || proxy_fail "无法停止端口 $port，保留实例文件。"
    fi
    proxy_stopped "$unit" || proxy_fail "无法确认端口 $port 已停止，保留实例文件。"
    printf '端口 %s 已停止。\n' "$port"
}

proxy_remove_instance() {
    local port="$1" kind="$2" unit path
    unit="$(proxy_unit "$port" "$kind")"
    proxy_check_unit "$port" "$kind"
    proxy_stopped "$unit" || proxy_fail "无法确认端口 $port 已停止，保留实例文件。"
    proxy_assert_no_debug "$port"
    path="$(proxy_instance_dropin "$port" "$kind")"
    if [[ ! -L "${path%/*}" && ! -L "$path" && -f "$path" && "$(<"$path")" == "$PROXY_SILENT" ]]; then
        rm -f -- "$path"
        rmdir -- "${path%/*}" 2>/dev/null || true
    fi
    rm -f -- "/etc/systemd/system/$unit"
    systemctl daemon-reload
    proxy_remove_config "$port" "$kind"
}

proxy_remove_interrupted_stages() {
    local stage
    [[ -d "$PROXY_ROOT" ]] && proxy_private "$PROXY_ROOT" 700 || return 0
    for stage in "$PROXY_ROOT"/.stage.??????; do
        [[ -e "$stage" || -L "$stage" ]] || continue
        proxy_check_stage "$stage"
        proxy_remove_stage "$stage"
    done
}

proxy_retire_dir() {
    local path="$1" retired device root_device
    if [[ ! -d "$PROXY_ROOT" ]]; then mkdir -m 0700 -- "$PROXY_ROOT"; fi
    device="$(stat -c %d -- "$path")"
    root_device="$(stat -c %d -- "$PROXY_ROOT")"
    [[ "$device" == "$root_device" ]] ||
        proxy_fail "实例目录位于不同文件系统，未删除 $path。"
    # Hide the directory from the instance list atomically before deleting its contents.
    retired="$(mktemp -d -- "$PROXY_ROOT/.stage.XXXXXX")"
    rmdir -- "$retired"
    mv -nT -- "$path" "$retired"
    [[ ! -e "$path" && -d "$retired" ]] || proxy_fail "无法移出实例目录 $path。"
    proxy_remove_stage "$retired"
}

proxy_uninstall() {
    local port
    if ((${#proxy_ports[@]} > 0)); then proxy_list; fi
    printf '将清理 %s 的全部受管实例、凭据、专用文件和可安全移除的依赖。\n' "$PROXY_LABEL"
    proxy_confirm '确认卸载' || return 0
    for port in "${proxy_ports[@]}"; do
        proxy_assert_no_debug "$port"
        proxy_check_unit "$port" "${proxy_instances[$port]}"
        proxy_check_removal "$port" "${proxy_instances[$port]}"
    done
    for port in "${proxy_ports[@]}"; do proxy_stop "$port" "${proxy_instances[$port]}"; done
    for port in "${proxy_ports[@]}"; do proxy_remove_instance "$port" "${proxy_instances[$port]}"; done
    proxy_remove_interrupted_stages
    if declare -F proxy_remove_dependencies >/dev/null; then proxy_remove_dependencies; fi
    proxy_purge_package
    if [[ ! -L "$PROXY_PRESET" && -f "$PROXY_PRESET" && "$(<"$PROXY_PRESET")" == "$(proxy_preset_content)" ]]; then
        rm -f -- "$PROXY_PRESET"
    fi
    if [[ -d "$PROXY_ROOT" ]] && proxy_private "$PROXY_ROOT" 700; then
        if [[ "$(proxy_package_status "$PROXY_PACKAGE")" != installed ]]; then rm -f -- "$PROXY_ROOT/.package"; fi
        rmdir -- "$PROXY_ROOT" 2>/dev/null || true
    fi
    printf '已清理 %s 受管实例。\n' "$PROXY_LABEL"
}

proxy_finish_debug() {
    if ! proxy_stopped "$debug_unit"; then
        systemctl stop "$debug_unit" || { printf '无法停止调试服务 %s。\n' "$debug_unit" >&2; return 1; }
    fi
    if [[ "$debug_resume" == true ]]; then
        systemctl start "$debug_normal" || { printf '无法恢复原服务 %s。\n' "$debug_normal" >&2; return 1; }
    fi
}

proxy_debug() {
    local port="$1" kind="$2" state result=0
    local -a options=()
    debug_normal="$(proxy_unit "$port" "$kind")"
    debug_unit="$(proxy_debug_unit "$port")"
    debug_resume=false
    proxy_assert_no_debug "$port"
    proxy_prepare_unit "$port" "$kind"
    state="$(proxy_state "$debug_normal")" || proxy_fail '无法读取原实例状态。'
    if [[ "$state" == active ]]; then
        debug_resume=true
        printf '调试会暂时中断端口 %s 的已有连接。\n' "$port"
        options+=(-p "ExecStopPost=+/usr/bin/systemctl --no-block start $debug_normal")
    else
        proxy_stopped "$debug_normal" || proxy_fail '实例正在切换状态，请稍后再试。'
    fi
    if [[ -t 0 && -t 1 ]]; then options+=(--pty); else options+=(--pipe); fi
    # The manager restores the original service even if this terminal is killed.
    trap proxy_finish_debug EXIT
    printf '临时日志最多显示 5 分钟，按 Ctrl+C 退出。\n'
    proxy_run_debug "$port" "$kind" --quiet --collect --wait --unit="$debug_unit" \
        -p "Conflicts=$debug_normal" -p "After=$debug_normal" -p "InaccessiblePaths=$PROXY_LOG_PATHS" \
        -p RuntimeMaxSec=5min -p TimeoutStopSec=10s -p LimitCORE=0 "${options[@]}" || result=$?
    proxy_finish_debug || proxy_fail '临时调试结束，恢复失败。'
    trap proxy_cleanup_pending EXIT
    if ((result != 0)); then printf '调试进程已结束（退出码 %s）。\n' "$result"; fi
    printf '已退出临时日志。\n'
}

proxy_install_cleanup() {
    proxy_cleanup_pending
    if [[ -n "$install_stage" ]]; then proxy_remove_stage "$install_stage"; fi
    if [[ "$install_prepared" == true ]]; then
        if [[ -f "/etc/systemd/system/$install_unit" ]]; then
            systemctl disable --now "$install_unit" || return 1
        fi
        if ! proxy_stopped "$install_unit"; then
            printf '无法确认端口 %s 已停止，保留实例文件。\n' "$install_port" >&2
            return 1
        fi
        if [[ "$install_published" == true ]]; then
            proxy_remove_instance "$install_port" "$install_target"
        else
            proxy_remove_protocol_file "$install_port" "$install_target"
        fi
    fi
}

proxy_install() {
    local raw default_label password='' username=''
    default_label="$PROXY_LABEL 端口"
    if [[ -n "$PROXY_DEFAULT_PORT" ]]; then default_label+=" [$PROXY_DEFAULT_PORT]"; fi
    while true; do
        raw="$(proxy_prompt "$default_label" "$PROXY_DEFAULT_PORT")"
        if [[ "$raw" =~ ^[0-9]{1,5}$ ]] && ((10#$raw >= 1 && 10#$raw <= 65535)); then
            install_port=$((10#$raw))
            break
        fi
        printf '请输入 1–65535 的整数。\n'
    done
    [[ -z "${proxy_instances[$install_port]:-}" ]] || proxy_fail "端口 $install_port 已有实例。"
    if command -v ss >/dev/null; then proxy_assert_free_port "$install_port"; fi
    install_target="$PROXY_ROOT/$install_port"
    install_unit="$(proxy_unit "$install_port" "$install_target")"
    [[ "$(systemctl show -p LoadState --value "$install_unit")" == not-found &&
        ! -e "/etc/systemd/system/$install_unit" && ! -L "/etc/systemd/system/$install_unit" ]] ||
        proxy_fail "已有同名服务 $install_unit。"
    # The protocol adapter fills the credentials scoped to this installation.
    proxy_read_credentials
    trap proxy_install_cleanup EXIT
    if [[ ! -d "$PROXY_ROOT" ]]; then mkdir -m 0700 -- "$PROXY_ROOT"; fi
    proxy_install_dependencies
    proxy_assert_free_port "$install_port"
    install_stage="$(mktemp -d -- "$PROXY_ROOT/.stage.XXXXXX")"
    proxy_create_config "$install_port" "$install_stage" "$username" "$password"
    mv -nT -- "$install_stage" "$install_target"
    [[ ! -e "$install_stage" ]] || proxy_fail "端口 $install_port 的配置目录已存在。"
    install_stage=''
    install_published=true
    install_prepared=true
    proxy_prepare_unit "$install_port" "$install_target"
    systemctl start "$install_unit" || proxy_fail '安装启动失败。'
    proxy_wait "$install_port" "$install_target" "$username" "$password" ||
        proxy_fail '新实例验证失败，正在清理本次安装。'
    systemctl enable "$install_unit"
    install_prepared=false
    printf '端口 %s 已在线。\n' "$install_port"
    proxy_show "$install_port" "$install_target"
}

proxy_action() {
    local action="$1" port kind
    umask 077
    exec 9>/run/lock/vps-proxy-manager.lock
    flock -n 9 || proxy_fail '另一代理管理操作正在执行，请稍后重试。'
    trap proxy_cleanup_pending EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    proxy_scan || exit 1
    case "$action" in
        1) proxy_install; return ;;
        3) proxy_uninstall; return ;;
    esac
    port="$(proxy_select)" || return 0
    kind="${proxy_instances[$port]}"
    case "$action" in
        2) proxy_stop "$port" "$kind" ;;
        4) proxy_show "$port" "$kind" ;;
        5) proxy_start "$port" "$kind" ;;
        6) proxy_debug "$port" "$kind" ;;
        7)
            proxy_confirm "确认删除端口 $port 的实例与凭据" || return 0
            proxy_check_removal "$port" "$kind"
            proxy_stop "$port" "$kind"
            proxy_remove_instance "$port" "$kind"
            printf '已删除端口 %s 的实例。\n' "$port"
            ;;
        8)
            if declare -F proxy_convert >/dev/null; then proxy_convert "$port" "$kind"
            else printf '输入错误。\n'; fi
            ;;
    esac
}

proxy_menu() {
    local action status
    ((EUID == 0)) || proxy_fail '请以 root 执行。'
    [[ -r /etc/os-release ]] || proxy_fail '无法识别操作系统。'
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == debian && "${VERSION_ID:-}" == 12 ]] || proxy_fail '此脚本支持 Debian 12。'
    systemctl show -p Version --value >/dev/null || proxy_fail '需要运行中的 systemd。'
    while true; do
        printf '\n========== %s 管理 ==========\n' "$PROXY_LABEL"
        proxy_scan && proxy_list || proxy_fail '无法读取实例列表。'
        printf '1. 安装\n2. 停止\n3. 卸载\n4. 查看\n5. 启动\n6. 临时日志\n7. 删除实例\n'
        if declare -F proxy_convert >/dev/null; then printf '8. 设置现有实例的同端口模式或 NAT 地址\n'; fi
        printf '0. 返回\n请选择：'
        IFS= read -r action || return 0
        case "$action" in
            0) return 0 ;;
            [1-8])
                if [[ "$action" == 8 ]] && ! declare -F proxy_convert >/dev/null; then
                    printf '输入错误。\n'
                    continue
                fi
                set +e
                (set -e; proxy_action "$action")
                status=$?
                set -e
                if ((status != 0 && status != 130)); then printf '操作未完成（退出码 %s）。\n' "$status" >&2; fi
                ;;
            *) printf '输入错误。\n' >&2 ;;
        esac
    done
}
