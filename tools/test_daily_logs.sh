#!/usr/bin/env bash
set -euo pipefail
base="$(cd "$(dirname "$0")/.." && pwd)"
writer="$base/assets/bin/log_daily.sh"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT
day="$(TZ=Asia/Shanghai date +%F)"

printf 'app-only\n' | bash "$writer" "$root" app quiet
printf 'napcat-only\n' | bash "$writer" "$root" napcat quiet
printf 'instance-one\n' | bash "$writer" "$root" astrbot quiet bot-one
printf 'instance-two\n' | bash "$writer" "$root" astrbot quiet bot-two
test "$(cat "$root/logs/app/$day.log")" = app-only
test "$(cat "$root/logs/napcat/$day.log")" = napcat-only
test "$(cat "$root/logs/astrbot/bot-one/$day.log")" = instance-one
test "$(cat "$root/logs/astrbot/bot-two/$day.log")" = instance-two
test "$(wc -l < "$root/logs/astrbot/$day.log")" -eq 2

{
  printf 'before-delete\n'
  for _ in {1..100}; do
    [ -f "$root/logs/minilm/$day.log" ] && break
    sleep 0.02
  done
  test -f "$root/logs/minilm/$day.log"
  rm -rf "$root/logs/minilm"
  printf 'after-delete\n'
} | bash "$writer" "$root" minilm quiet
test "$(cat "$root/logs/minilm/$day.log")" = after-delete
if printf 'invalid\n' | bash "$writer" "" app quiet; then
  exit 1
fi
printf 'daily log isolation and directory recovery: PASS\n'
