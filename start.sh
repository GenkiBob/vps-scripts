#!/usr/bin/env bash
# 安装一次后复用本地菜单；--update 显式更新，不执行任何运维功能。

# 入口、菜单和功能脚本共用固定提交的下载逻辑。
download_script() {
    local revision="$1" path="$2" destination="$3" response
    if wget --https-only --timeout=30 --tries=2 --no-verbose -O "$destination" \
        "https://raw.githubusercontent.com/GenkiBob/vps-scripts/$revision/$path"; then
        return 0
    else
        printf 'GitHub Raw 下载失败（wget 退出码 %s），尝试 GitHub Contents API：%s\n' "$?" "$path" >&2
    fi

    if ! response="$(wget --https-only --timeout=15 --tries=1 --no-verbose --server-response \
        --header='Accept: application/vnd.github.raw+json' -O "$destination" \
        "https://api.github.com/repos/GenkiBob/vps-scripts/contents/$path?ref=$revision" 2>&1)"; then
        # 只输出 HTTP 状态和 wget 错误，避免打印其他响应头。
        awk '$1 ~ /^HTTP\// || /^[^[:space:]]/' <<< "$response" >&2
        printf '备用下载失败：%s（提交 %s）。\n' "$path" "${revision:0:12}" >&2
        return 1
    fi

    if ! awk '
        $1 ~ /^HTTP\// { media = "" }
        tolower($1) == "content-type:" { media = tolower($2); sub(/[;\r].*/, "", media) }
        END { exit (media != "application/vnd.github.raw+json") }
    ' <<< "$response"; then
        printf 'GitHub Contents API 未返回脚本正文：%s。\n' "$path" >&2
        return 1
    fi
}

current_root() {
    local version
    [[ -f "$INSTALL_ROOT/current" ]] || return 1
    IFS= read -r version < "$INSTALL_ROOT/current" || return 1
    [[ "$version" =~ ^[a-f0-9]{40}-[a-zA-Z0-9]+$ ]] || return 1
    [[ -s "$INSTALL_ROOT/versions/$version/main.sh" && -s "$INSTALL_ROOT/versions/$version/.revision" ]] || return 1
    printf '%s\n' "$INSTALL_ROOT/versions/$version"
}

resolve_revision() {
    local reply_file="$1" revision first_line
    if wget --https-only --timeout=15 --tries=1 --no-verbose --header='Accept: application/vnd.github.sha' \
        -O "$reply_file" 'https://api.github.com/repos/GenkiBob/vps-scripts/commits/main'; then
        revision="$(tr -d '\r\n' < "$reply_file")"
        if [[ "$revision" =~ ^[a-f0-9]{40}$ ]]; then
            printf '%s\n' "$revision"
            return 0
        fi
        printf 'GitHub API 未返回有效的提交 SHA。\n' >&2
    else
        printf 'GitHub API 版本查询失败（wget 退出码 %s）。\n' "$?" >&2
    fi

    printf '正在通过 GitHub 提交补丁查询版本……\n' >&2
    if ! wget --https-only --timeout=15 --tries=1 --no-verbose -O "$reply_file" \
        'https://github.com/GenkiBob/vps-scripts/commit/main.patch'; then
        printf 'GitHub 备用版本查询失败。\n' >&2
        return 1
    fi
    if ! IFS= read -r first_line < "$reply_file" || ! [[ "$first_line" =~ ^From\ ([a-f0-9]{40})\  ]]; then
        printf 'GitHub 提交补丁未返回有效的提交 SHA。\n' >&2
        return 1
    fi
    printf '%s\n' "${BASH_REMATCH[1]}"
}

install_version() (
    local previous="$1" revision_file stage='' launcher_temp='' pointer_temp='' revision path
    command -v wget >/dev/null 2>&1 || { printf '安装或更新需要 wget。\n' >&2; return 1; }
    revision_file="$(mktemp "$INSTALL_ROOT/.revision.XXXXXX")" || return 1
    trap 'rm -f -- "$revision_file"; [[ -z "$launcher_temp" ]] || rm -f -- "$launcher_temp"; [[ -z "$pointer_temp" ]] || rm -f -- "$pointer_temp"; [[ -z "$stage" ]] || rm -rf -- "$stage"' EXIT
    printf '正在检查版本……\n'
    revision="$(resolve_revision "$revision_file")" || return 1
    if [[ -n "$previous" && "$(cat "$previous/.revision")" == "$revision" ]]; then
        printf '当前已是最新版本：%s\n' "${revision:0:12}"
        return 0
    fi
    stage="$(mktemp -d "$INSTALL_ROOT/versions/$revision-XXXXXX")" || return 1
    printf '%s\n' "$revision" > "$stage/.revision" || return 1
    for path in start.sh main.sh; do
        printf '正在下载：%s\n' "$path"
        download_script "$revision" "$path" "$stage/$path" || return 1
        [[ -s "$stage/$path" ]] && bash -n "$stage/$path" || {
            printf '下载内容为空或 Bash 语法验证失败：%s。\n' "$path" >&2
            return 1
        }
    done
    # 由新版菜单读取新版登记表，只预下载已使用功能的新版本，不运行功能。
    bash "$stage/main.sh" --prepare-update "$previous" || return 1
    launcher_temp="$(mktemp "$INSTALL_ROOT/.launcher.XXXXXX")" || return 1
    cp -- "$stage/start.sh" "$launcher_temp" || return 1
    mv -f -- "$launcher_temp" "$INSTALL_ROOT/start.sh" || return 1
    launcher_temp=''
    pointer_temp="$(mktemp "$INSTALL_ROOT/.current.XXXXXX")" || return 1
    printf '%s\n' "${stage##*/}" > "$pointer_temp" || return 1
    mv -f -- "$pointer_temp" "$INSTALL_ROOT/current" || return 1
    pointer_temp=''
    stage=''
    printf '安装或更新完成，本地启动命令：bash "%s/start.sh"\n' "$INSTALL_ROOT"
)

start() {
    local previous='' selected update=false
    case "${1:-}" in
        '') [[ $# -eq 0 ]] || return 1 ;;
        --update) [[ $# -eq 1 ]] || return 1; update=true ;;
        *) printf '用法：bash start.sh [--update]\n' >&2; return 1 ;;
    esac
    local INSTALL_ROOT="${VPS_SCRIPTS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/vps-scripts}"
    mkdir -p -- "$INSTALL_ROOT/versions" || return 1
    INSTALL_ROOT="$(cd -- "$INSTALL_ROOT" && pwd)" || return 1
    readonly INSTALL_ROOT

    previous="$(current_root)" || previous=''
    if [[ -z "$previous" || "$update" == true ]]; then
        if ! install_version "$previous"; then
            if [[ -z "$previous" ]]; then printf '安装失败，未启动。\n' >&2; return 1; fi
            printf '更新失败，保留并使用原有本地版本。\n' >&2
        fi
    fi
    selected="$(current_root)" || return 1
    printf '使用本地菜单：%s\n版本：%s\n' "$selected/main.sh" "$(cat "$selected/.revision")"
    bash "$selected/main.sh" --remote
}
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -u
    umask 077
    start "$@"
fi
