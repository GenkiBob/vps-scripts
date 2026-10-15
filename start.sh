#!/usr/bin/env bash
# 公开下载入口：只获取菜单，功能脚本在选择后按需下载。
set -euo pipefail

readonly MENU_URL='https://raw.githubusercontent.com/GenkiBob/vps-scripts/main/main.sh'

for dependency in wget mktemp; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf '启动失败：缺少依赖 %s，请安装后重试。\n' "$dependency" >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
# 只清理由本次启动创建的临时目录，菜单运行结束后再删除。
trap 'rm -rf -- "$WORK_DIR"' EXIT

printf '正在下载菜单……\n'
if ! wget --https-only --timeout=30 --tries=2 -q -O "$WORK_DIR/main.sh" "$MENU_URL"; then
    printf '下载失败，请检查网络及仓库是否公开。\n' >&2
    exit 1
fi

if [[ ! -s "$WORK_DIR/main.sh" ]] || ! bash -n "$WORK_DIR/main.sh"; then
    printf '菜单为空或 Bash 语法错误，停止运行。\n' >&2
    exit 1
fi

# 使用正常标准输入，支持菜单及子脚本交互；不要改成管道执行。
bash -- "$WORK_DIR/main.sh" --remote
