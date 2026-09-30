#!/usr/bin/env bash
# 用真实 bash 对仓库里所有 shell 脚本做语法检查（等价于 CI 里的 shellcheck 步骤）。
# 用法：bash tools/check_shell_syntax.sh
#
# 背景：DSH 沙箱会阻止 Git Bash 创建内部信号管道（Win32 error 5），
# 因此在受限沙箱下这个脚本跑不起来，需要以放宽权限的方式执行一次。
set -uo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
count=0

for f in "$base"/assets/bin/*.sh "$base"/tools/*.sh; do
  [ -f "$f" ] || continue
  count=$((count + 1))
  if err="$(bash -n "$f" 2>&1)"; then
    printf 'OK   %s\n' "$(basename "$f")"
  else
    fail=$((fail + 1))
    printf 'FAIL %s\n%s\n' "$(basename "$f")" "$err"
  fi
done

printf '\n共检查 %d 个脚本，失败 %d 个\n' "$count" "$fail"
exit "$fail"
