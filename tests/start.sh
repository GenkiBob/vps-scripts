#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/bin" "$TEST_ROOT/tmp" "$TEST_ROOT/package/repo/scripts"
cp -- "$PROJECT_ROOT/main.sh" "$TEST_ROOT/package/repo/main.sh"
sed -i '/^MENU_ITEMS=(/,/^)/c\MENU_ITEMS=(\n    '\''1|测试项目|scripts/example.sh'\''\n)' "$TEST_ROOT/package/repo/main.sh"
printf '#!/usr/bin/env bash\nprintf "fixture-success\\n"\n' > "$TEST_ROOT/package/repo/scripts/example.sh"
tar -czf "$TEST_ROOT/fixture.tar.gz" -C "$TEST_ROOT/package" repo
cat > "$TEST_ROOT/bin/wget" <<'MOCK'
#!/usr/bin/env bash
[[ "${MOCK_DOWNLOAD_MODE:-success}" != fail ]] || exit 1
while [[ $# -gt 0 ]]; do
    if [[ "$1" == -O ]]; then
        output="$2"
        shift 2
    else
        shift
    fi
done
if [[ "${MOCK_DOWNLOAD_MODE:-success}" == corrupt ]]; then
    printf 'not an archive' > "$output"
else
    cp -- "$MOCK_ARCHIVE" "$output"
fi
MOCK
chmod +x "$TEST_ROOT/bin/wget"
export PATH="$TEST_ROOT/bin:$PATH" TMPDIR="$TEST_ROOT/tmp" MOCK_ARCHIVE="$TEST_ROOT/fixture.tar.gz"

output="$(printf '1\n0\n' | bash "$PROJECT_ROOT/start.sh" 2>&1)"
[[ "$output" == *fixture-success* && "$output" == *已退出* ]]
[[ -z "$(ls -A "$TMPDIR")" ]]

for mode in fail corrupt; do
    if output="$(MOCK_DOWNLOAD_MODE="$mode" bash "$PROJECT_ROOT/start.sh" </dev/null 2>&1)"; then
        printf 'FAIL: %s 应停止运行\n' "$mode" >&2
        exit 1
    fi
    [[ "$output" != *'VPS 脚本菜单'* ]]
    [[ -z "$(ls -A "$TMPDIR")" ]]
done

mkdir -p "$TEST_ROOT/incomplete/repo"
printf 'placeholder' > "$TEST_ROOT/incomplete/repo/README.md"
tar -czf "$TEST_ROOT/incomplete.tar.gz" -C "$TEST_ROOT/incomplete" repo
if output="$(MOCK_ARCHIVE="$TEST_ROOT/incomplete.tar.gz" bash "$PROJECT_ROOT/start.sh" </dev/null 2>&1)"; then
    printf 'FAIL: 残缺项目应停止运行\n' >&2
    exit 1
fi
[[ "$output" == *脚本包不完整* && -z "$(ls -A "$TMPDIR")" ]]
printf 'PASS: 下载启动、交互输入、下载失败、损坏包、残缺包与临时目录清理。\n'
