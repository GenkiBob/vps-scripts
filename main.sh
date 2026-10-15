#!/usr/bin/env bash
# 菜单注册表：编号|显示名称|脚本路径|可选依赖路径（逗号分隔）。
# 编号保持稳定；0 保留给退出。新增功能只需增加一行并创建对应脚本。
MENU_ITEMS=(
    '1|运行演示脚本|scripts/example.sh'
    '2|配置 SmartDNS|scripts/configure-smartdns.sh'
)

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly PROJECT_ROOT
readonly DOWNLOAD_BASE='https://raw.githubusercontent.com/GenkiBob/vps-scripts/main'
REMOTE_MODE=false

run_remote() (
    local script="$1" dependencies="$2" work_dir path
    local -a files=("$script") extra_files=()
    if [[ -n "$dependencies" ]]; then
        IFS=',' read -r -a extra_files <<< "$dependencies"
        files+=("${extra_files[@]}")
    fi
    # 防止注册路径逃出临时目录。
    for path in "${files[@]}"; do
        if [[ ! "$path" =~ ^scripts/([a-zA-Z0-9_-]+/)*[a-zA-Z0-9_-]+\.sh$ ]]; then
            printf '菜单配置错误：脚本或依赖路径不合法。\n' >&2
            return 1
        fi
    done
    work_dir="$(mktemp -d)" || return 1
    trap 'rm -rf -- "$work_dir"' EXIT
    for path in "${files[@]}"; do
        mkdir -p -- "$work_dir/$(dirname -- "$path")" || return 1
        printf '正在下载：%s\n' "$path"
        if ! wget --https-only --timeout=30 --tries=2 -q -O "$work_dir/$path" "$DOWNLOAD_BASE/$path"; then
            printf '下载失败或脚本不存在：%s\n' "$path" >&2
            return 1
        fi
        if [[ ! -s "$work_dir/$path" ]] || ! bash -n "$work_dir/$path"; then
            printf '下载内容为空或 Bash 语法错误：%s\n' "$path" >&2
            return 1
        fi
    done
    # 全部文件下载验证成功后才执行；保留标准输入用于交互。
    cd -- "$work_dir" && bash -- "$work_dir/$script"
)

show_menu() {
    local entry id title script dependencies
    printf '\n========== VPS 脚本菜单 ==========\n'
    for entry in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r id title script dependencies <<< "$entry"
        printf '%s. %s\n' "$id" "$title"
    done
    printf '0. 退出\n'
}

run_selection() {
    local selection="$1" entry id title script dependencies status
    for entry in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r id title script dependencies <<< "$entry"
        if [[ "$selection" == "$id" ]]; then
            if [[ "$REMOTE_MODE" == false ]] && [[ ! -f "$PROJECT_ROOT/$script" || ! -r "$PROJECT_ROOT/$script" ]]; then
                printf '输入错误：对应脚本不存在或不可读：%s\n' "$script" >&2
                return
            fi
            printf '\n开始执行：%s\n' "$title"
            # 独立进程避免子脚本的 exit、cd、变量和 shell 选项影响菜单。
            # 保留标准输入；本地从项目根目录、在线从当次临时根目录执行。
            if [[ "$REMOTE_MODE" == true ]]; then
                run_remote "$script" "$dependencies"
                status=$?
            else
                (cd -- "$PROJECT_ROOT" && bash -- "$PROJECT_ROOT/$script")
                status=$?
            fi
            if [[ "$status" -eq 0 ]]; then
                printf '执行完成，返回主菜单。\n'
            else
                printf '执行失败（退出码：%s），返回主菜单。\n' "$status" >&2
            fi
            return
        fi
    done
    printf '输入错误：请输入菜单中显示的编号。\n' >&2
}

main() {
    local selection dependency
    if [[ "${1:-}" == '--remote' && $# -eq 1 ]]; then
        REMOTE_MODE=true
        for dependency in wget mktemp; do
            if ! command -v "$dependency" >/dev/null 2>&1; then
                printf '启动失败：缺少依赖 %s。\n' "$dependency" >&2
                return 1
            fi
        done
    elif [[ $# -ne 0 ]]; then
        printf '用法：bash main.sh [--remote]\n' >&2
        return 1
    fi
    while true; do
        show_menu
        if ! IFS= read -r -p '请输入编号并按回车：' selection; then
            printf '\n输入已结束，退出。\n'
            return 0
        fi
        if [[ "$selection" == '0' ]]; then
            printf '已退出。\n'
            return 0
        fi
        run_selection "$selection"
    done
}

main "$@"
