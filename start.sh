#!/usr/bin/env bash
# 安装一次后复用本地菜单；--update 显式更新，不执行任何运维功能。
set -u
umask 077
INSTALL_ROOT="${VPS_SCRIPTS_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/vps-scripts}"
mkdir -p -- "$INSTALL_ROOT/versions" || exit 1
INSTALL_ROOT="$(cd -- "$INSTALL_ROOT" && pwd)" || exit 1
readonly INSTALL_ROOT

current_root() {
    local version
    [[ -f "$INSTALL_ROOT/current" ]] || return 1
    IFS= read -r version < "$INSTALL_ROOT/current" || return 1
    [[ "$version" =~ ^[a-f0-9]{40}-[a-zA-Z0-9]+$ ]] || return 1
    [[ -s "$INSTALL_ROOT/versions/$version/main.sh" && -s "$INSTALL_ROOT/versions/$version/.revision" ]] || return 1
    printf '%s\n' "$INSTALL_ROOT/versions/$version"
}

install_version() (
    local previous="$1" revision_file stage='' launcher_temp='' pointer_temp='' revision path
    command -v wget >/dev/null 2>&1 || { printf '安装或更新需要 wget。\n' >&2; return 1; }
    revision_file="$(mktemp "$INSTALL_ROOT/.revision.XXXXXX")" || return 1
    trap 'rm -f -- "$revision_file"; [[ -z "$launcher_temp" ]] || rm -f -- "$launcher_temp"; [[ -z "$pointer_temp" ]] || rm -f -- "$pointer_temp"; [[ -z "$stage" ]] || rm -rf -- "$stage"' EXIT
    printf '正在检查版本……\n'
    wget --https-only --timeout=30 --tries=2 -q --header='Accept: application/vnd.github.sha' -O "$revision_file" \
        'https://api.github.com/repos/GenkiBob/vps-scripts/commits/main' || return 1
    revision="$(tr -d '\r\n' < "$revision_file")"
    [[ "$revision" =~ ^[a-f0-9]{40}$ ]] || { printf '远端版本格式错误。\n' >&2; return 1; }
    if [[ -n "$previous" && "$(cat "$previous/.revision")" == "$revision" ]]; then
        printf '当前已是最新版本：%s\n' "${revision:0:12}"
        return 0
    fi
    stage="$(mktemp -d "$INSTALL_ROOT/versions/$revision-XXXXXX")" || return 1
    printf '%s\n' "$revision" > "$stage/.revision" || return 1
    for path in start.sh main.sh; do
        printf '正在下载：%s\n' "$path"
        wget --https-only --timeout=30 --tries=2 -q -O "$stage/$path" \
            "https://raw.githubusercontent.com/GenkiBob/vps-scripts/$revision/$path" || return 1
        [[ -s "$stage/$path" ]] && bash -n "$stage/$path" || return 1
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

main() {
    local previous='' selected update=false
    case "${1:-}" in
        '') [[ $# -eq 0 ]] || return 1 ;;
        --update) [[ $# -eq 1 ]] || return 1; update=true ;;
        *) printf '用法：bash start.sh [--update]\n' >&2; return 1 ;;
    esac
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
main "$@"
