#!/usr/bin/env bash
# 菜单注册表：编号|显示名称|脚本路径|可选依赖路径（逗号分隔）。
MENU_ITEMS=(
    '1|运行演示脚本|scripts/example.sh'
    '2|配置 SmartDNS|scripts/configure-smartdns.sh'
)
PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly PROJECT_ROOT
readonly DOWNLOAD_BASE='https://raw.githubusercontent.com/GenkiBob/vps-scripts'
REMOTE_MODE=false
REVISION=''
if [[ -f "$PROJECT_ROOT/.revision" ]]; then
    IFS= read -r REVISION < "$PROJECT_ROOT/.revision"
    [[ "$REVISION" =~ ^[a-f0-9]{40}$ ]] || { printf '本地版本文件错误。\n' >&2; exit 1; }
fi

# 文件组来自固定提交；全部验证完成后才标记为可用。
ensure_cached() (
    local id="$1" script="$2" dependencies="$3" path stage='' complete=true
    local -a files=("$script") extra_files=()
    [[ "$id" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ -n "$REVISION" ]] || return 1
    if [[ -n "$dependencies" ]]; then
        IFS=',' read -r -a extra_files <<< "$dependencies"
        files+=("${extra_files[@]}")
    fi
    for path in "${files[@]}"; do
        [[ "$path" =~ ^scripts/([a-zA-Z0-9_-]+/)*[a-zA-Z0-9_-]+\.sh$ ]] || { printf '菜单配置路径不合法。\n' >&2; return 1; }
        if [[ ! -s "$PROJECT_ROOT/$path" ]] || ! bash -n "$PROJECT_ROOT/$path"; then complete=false; fi
    done
    if [[ -f "$PROJECT_ROOT/.installed/$id" && "$complete" == true ]]; then
        printf '使用本地版本：%s\n版本：%s\n' "$PROJECT_ROOT/$script" "${REVISION:0:12}"
        return 0
    fi
    command -v wget >/dev/null 2>&1 || { printf '首次下载需要 wget。\n' >&2; return 1; }
    umask 077
    stage="$(mktemp -d "$PROJECT_ROOT/.download.XXXXXX")" || return 1
    trap 'rm -rf -- "$stage"' EXIT
    for path in "${files[@]}"; do
        mkdir -p -- "$stage/$(dirname -- "$path")" || return 1
        printf '首次下载或准备更新：%s\n' "$path"
        wget --https-only --timeout=30 --tries=2 -q -O "$stage/$path" "$DOWNLOAD_BASE/$REVISION/$path" || { printf '下载失败或脚本不存在：%s\n' "$path" >&2; return 1; }
        [[ -s "$stage/$path" ]] && bash -n "$stage/$path" || { printf '下载为空或语法错误：%s\n' "$path" >&2; return 1; }
    done
    for path in "${files[@]}"; do
        mkdir -p -- "$PROJECT_ROOT/$(dirname -- "$path")" || return 1
        mv -f -- "$stage/$path" "$PROJECT_ROOT/$path" || return 1
    done
    mkdir -p -- "$PROJECT_ROOT/.installed" || return 1
    printf '%s\n' "$script" > "$PROJECT_ROOT/.installed/$id" || return 1
    printf '已保存：%s\n版本：%s\n' "$PROJECT_ROOT/$script" "${REVISION:0:12}"
)

prepare_update() {
    local previous="$1" entry id title script dependencies
    [[ -n "$REVISION" ]] || return 1
    [[ -z "$previous" || -d "$previous/.installed" ]] || return 0
    for entry in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r id title script dependencies <<< "$entry"
        if [[ -n "$previous" && -f "$previous/.installed/$id" ]]; then
            printf '准备更新已使用功能：%s\n' "$title"
            ensure_cached "$id" "$script" "$dependencies" || return 1
        fi
    done
}

show_menu() {
    local entry id title script dependencies
    printf '\n========== VPS 脚本菜单 ==========\n'
    for entry in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r id title script dependencies <<< "$entry"
        printf '%s. %s\n' "$id" "$title"
    done
    printf 'u. 检查并更新脚本\n0. 退出\n'
}

run_selection() {
    local selection="$1" entry id title script dependencies status
    for entry in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r id title script dependencies <<< "$entry"
        if [[ "$selection" == "$id" ]]; then
            if [[ "$REMOTE_MODE" == true ]]; then
                ensure_cached "$id" "$script" "$dependencies" || { printf '下载或校验失败，返回主菜单。\n' >&2; return; }
            elif [[ ! -f "$PROJECT_ROOT/$script" || ! -r "$PROJECT_ROOT/$script" ]]; then
                printf '输入错误：对应脚本不存在或不可读：%s\n' "$script" >&2
                return
            fi
            printf '\n开始执行：%s\n' "$title"
            (cd -- "$PROJECT_ROOT" && bash -- "$PROJECT_ROOT/$script")
            status=$?
            if [[ "$status" -eq 0 ]]; then printf '执行完成，返回主菜单。\n'
            else printf '执行失败（退出码：%s），返回主菜单。\n' "$status" >&2; fi
            return
        fi
    done
    printf '输入错误：请输入菜单中显示的编号。\n' >&2
}

main() {
    local selection
    if [[ "${1:-}" == '--prepare-update' && $# -eq 2 ]]; then
        prepare_update "$2"
        return $?
    elif [[ "${1:-}" == '--remote' && $# -eq 1 ]]; then
        REMOTE_MODE=true
        if [[ -z "$REVISION" ]]; then exec bash "$PROJECT_ROOT/start.sh"; fi
    elif [[ $# -ne 0 ]]; then
        printf '用法：bash main.sh [--remote]\n' >&2
        return 1
    fi
    while true; do
        show_menu
        if ! IFS= read -r -p '请输入编号并按回车：' selection; then printf '\n输入已结束，退出。\n'; return 0; fi
        if [[ "$selection" == '0' ]]; then printf '已退出。\n'; return 0; fi
        if [[ "$selection" == 'u' ]]; then exec bash "$PROJECT_ROOT/start.sh" --update; fi
        run_selection "$selection"
    done
}
main "$@"
