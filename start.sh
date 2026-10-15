#!/usr/bin/env bash
# 公开下载入口：获取同一版本的完整项目，然后启动菜单。
set -euo pipefail

readonly ARCHIVE_URL='https://codeload.github.com/GenkiBob/vps-scripts/tar.gz/refs/heads/main'

for dependency in wget tar mktemp; do
    if ! command -v "$dependency" >/dev/null 2>&1; then
        printf '启动失败：缺少依赖 %s，请安装后重试。\n' "$dependency" >&2
        exit 1
    fi
done

WORK_DIR="$(mktemp -d)"
readonly WORK_DIR
# 只清理由本次启动创建的临时目录，菜单运行结束后再删除。
trap 'rm -rf -- "$WORK_DIR"' EXIT

printf '正在下载 VPS 脚本包……\n'
if ! wget --https-only --timeout=30 --tries=2 -q -O "$WORK_DIR/project.tar.gz" "$ARCHIVE_URL"; then
    printf '下载失败，请检查网络及仓库是否公开。\n' >&2
    exit 1
fi

mkdir -- "$WORK_DIR/project"
if ! tar -xzf "$WORK_DIR/project.tar.gz" -C "$WORK_DIR/project" --strip-components=1; then
    printf '解压失败，停止运行。\n' >&2
    exit 1
fi
if [[ ! -r "$WORK_DIR/project/main.sh" || ! -d "$WORK_DIR/project/scripts" ]]; then
    printf '脚本包不完整，停止运行。\n' >&2
    exit 1
fi

# 使用正常标准输入，支持菜单及子脚本交互；不要改成管道执行。
bash -- "$WORK_DIR/project/main.sh"
