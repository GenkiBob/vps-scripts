#!/usr/bin/env bash
# 菜单注册表：编号|显示名称|相对于项目根目录的脚本路径。
# 编号保持稳定；0 保留给退出。新增功能只需增加一行并创建对应脚本。
MENU_ITEMS=(
    '1|运行演示脚本|scripts/example.sh'
)

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
readonly PROJECT_ROOT

show_menu() {
    local entry id title script
    printf '\n========== VPS 脚本菜单 ==========\n'
    for entry in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r id title script <<< "$entry"
        printf '%s. %s\n' "$id" "$title"
    done
    printf '0. 退出\n'
}

run_selection() {
    local selection="$1" entry id title script status
    for entry in "${MENU_ITEMS[@]}"; do
        IFS='|' read -r id title script <<< "$entry"
        if [[ "$selection" == "$id" ]]; then
            if [[ ! -f "$PROJECT_ROOT/$script" || ! -r "$PROJECT_ROOT/$script" ]]; then
                printf '输入错误：对应脚本不存在或不可读：%s\n' "$script" >&2
                return
            fi
            printf '\n开始执行：%s\n' "$title"
            # 独立进程避免子脚本的 exit、cd、变量和 shell 选项影响菜单。
            # 保留标准输入，供子脚本交互使用；统一从项目根目录执行。
            if (cd -- "$PROJECT_ROOT" && bash -- "$PROJECT_ROOT/$script"); then
                printf '执行完成，返回主菜单。\n'
            else
                status=$?
                printf '执行失败（退出码：%s），返回主菜单。\n' "$status" >&2
            fi
            return
        fi
    done
    printf '输入错误：请输入菜单中显示的编号。\n' >&2
}

main() {
    local selection
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
