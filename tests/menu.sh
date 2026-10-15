#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf -- "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/project with spaces/scripts"
FIXTURE="$TEST_ROOT/project with spaces"
cp -- "$PROJECT_ROOT/main.sh" "$FIXTURE/main.sh"
# 替换副本中的注册表，使后续新增真实运维功能也不会在测试中被执行。
sed -i '/^MENU_ITEMS=(/,/^)/c\MENU_ITEMS=(\n    '\''1|测试项目|scripts/example.sh'\''\n)' "$FIXTURE/main.sh"
printf '#!/usr/bin/env bash\nprintf "fixture-success\\n"\n' > "$FIXTURE/scripts/example.sh"

assert_contains() {
    if [[ "$output" != *"$1"* ]]; then
        printf 'FAIL: 缺少输出 %s\n%s\n' "$1" "$output" >&2
        exit 1
    fi
}

output="$(printf '\nabc\n99\n01\n 1\n0\n' | bash "$FIXTURE/main.sh" 2>&1)"
count="$(printf '%s' "$output" | grep -c '输入错误')"
[[ "$count" -eq 5 ]]
assert_contains '已退出'

output="$(cd -- "$TEST_ROOT" && printf '1\n1\n0\n' | bash "$FIXTURE/main.sh" 2>&1)"
count="$(printf '%s' "$output" | grep -c 'fixture-success')"
[[ "$count" -eq 2 ]]
assert_contains '执行完成，返回主菜单'
assert_contains '已退出'

printf '#!/usr/bin/env bash\nexit 7\n' > "$FIXTURE/scripts/example.sh"
output="$(printf '1\n0\n' | bash "$FIXTURE/main.sh" 2>&1)"
assert_contains '执行失败（退出码：7）'
assert_contains '已退出'

mv -- "$FIXTURE/scripts/example.sh" "$FIXTURE/scripts/example.disabled"
output="$(printf '1\n0\n' | bash "$FIXTURE/main.sh" 2>&1)"
assert_contains '对应脚本不存在或不可读'
assert_contains '已退出'

output="$(bash "$FIXTURE/main.sh" </dev/null 2>&1)"
assert_contains '输入已结束'
printf 'PASS: 非法输入、重复执行、失败恢复、缺失脚本、跨目录及 EOF。\n'
