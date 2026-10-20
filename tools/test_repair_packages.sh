#!/usr/bin/env bash
# 验证 repair_termux_packages 的调用顺序：
#   1) 正常情况：先收尾半截配置，再更新源，再升级
#   2) 升级被半截状态挡住时：会补跑收尾、修依赖，然后重试升级
# 用假的包管理命令记录调用顺序，不会真的动系统。
# 用法：bash tools/test_repair_packages.sh
set -uo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"

fail() { printf '失败：%s\n' "$1" >&2; exit 1; }

run_case() {
  local label="$1"
  local first_upgrade_fails="$2"
  local root
  root="$(mktemp -d)"
  export HOME="$root/home"
  export PREFIX="$root/prefix"
  export ZBS_HOME_ROOT="$root/home/手机端值班室"
  export CALL_LOG="$root/calls.log"
  export UPGRADE_COUNT="$root/upgrade.count"
  export FIRST_UPGRADE_FAILS="$first_upgrade_fails"
  mkdir -p "$HOME" "$PREFIX" "$ZBS_HOME_ROOT" "$root/public/bin" "$root/bin"
  cp "$base/assets/bin/common.sh" "$root/public/bin/common.sh"

  # 假的包管理命令：只记录被怎么调用，然后按剧本返回成功或失败
  cat > "$root/bin/dpkg" <<'FAKE'
#!/usr/bin/env bash
printf 'dpkg %s\n' "$*" >> "$CALL_LOG"
exit 0
FAKE
  cat > "$root/bin/apt-get" <<'FAKE'
#!/usr/bin/env bash
printf 'apt-get %s\n' "$*" >> "$CALL_LOG"
case "$*" in
  *full-upgrade*)
    n=$(cat "$UPGRADE_COUNT" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s\n' "$n" > "$UPGRADE_COUNT"
    if [ "$n" -le "$FIRST_UPGRADE_FAILS" ]; then
      exit 1
    fi
    exit 0
    ;;
esac
exit 0
FAKE
  chmod +x "$root/bin/dpkg" "$root/bin/apt-get"
  export PATH="$root/bin:$PATH"

  # shellcheck source=/dev/null
  ( source "$root/public/bin/common.sh"; repair_termux_packages ) >/dev/null 2>&1
  local code=$?
  printf '%s\n' "--- $label（退出码 $code）调用顺序 ---"
  cat "$CALL_LOG" 2>/dev/null
  RESULT="$(cat "$CALL_LOG" 2>/dev/null || true)"
  CODE="$code"
  rm -rf "$root"
}

# 场景一：状态干净，第一次升级就成功
run_case "状态干净" 0
[ "$CODE" -eq 0 ] || fail "干净状态下修复竟然失败了"
first_line="$(printf '%s\n' "$RESULT" | head -n 1)"
printf '%s' "$first_line" | grep -q '^dpkg --configure -a$' \
  || fail "第一件事不是先收尾半截配置，实际是：$first_line"
printf '%s' "$RESULT" | grep -q 'apt-get update' || fail "没有更新软件源"
printf '%s' "$RESULT" | grep -q 'full-upgrade' || fail "没有执行升级"
printf '通过：干净状态下顺序正确（先收尾、再更新源、再升级）\n'

# 场景二：第一次升级被半截状态挡住，应当补跑收尾并重试成功
run_case "升级被挡住一次" 1
[ "$CODE" -eq 0 ] || fail "补跑收尾之后仍然失败"
upgrade_times="$(printf '%s\n' "$RESULT" | grep -c 'full-upgrade')"
[ "$upgrade_times" -ge 2 ] || fail "升级只尝试了 $upgrade_times 次，没有重试"
configure_times="$(printf '%s\n' "$RESULT" | grep -c 'dpkg --configure -a')"
[ "$configure_times" -ge 2 ] || fail "收尾只跑了 $configure_times 次，失败后没有补跑"
printf '%s' "$RESULT" | grep -q 'fix-broken' || fail "没有修复损坏的依赖"
printf '通过：升级失败后会补跑收尾（共 %s 次）、修依赖、再重试\n' "$configure_times"

printf '\n软件包收尾验收：全部通过\n'
