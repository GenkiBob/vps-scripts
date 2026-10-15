#!/usr/bin/env bash
# 功能：填写功能说明。
# 运行条件：说明支持的系统、依赖和是否需要 root。
# 系统影响：说明修改哪些配置、服务或文件。
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd -- "$SCRIPT_DIR/.." && pwd)"
readonly SCRIPT_DIR PROJECT_ROOT

main() {
    # 在此实现功能；失败使用非零退出码，成功返回 0。
    # 不要在此重复实现主菜单或调用 main.sh。
    printf '请先实现此脚本的功能。\n' >&2
    return 1
}

main "$@"
