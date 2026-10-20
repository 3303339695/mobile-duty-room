#!/usr/bin/env bash
# 验证运行底座的安装流程：
#   一、下载中断留下的空壳不能被当成"已安装"
#   二、完整装好的底座要能被识别
#   三、重装前会先清掉空壳
#   四、连不上下载站时要立刻给出明确提示，而不是傻等
# 用法：bash tools/test_proot_install.sh
set -uo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

export HOME="$root/home"
export PREFIX="$root/prefix"
export ZBS_HOME_ROOT="$root/home/手机端值班室"
mkdir -p "$HOME" "$PREFIX" "$ZBS_HOME_ROOT" "$root/public/bin" "$root/bin"
cp "$base/assets/bin/common.sh" "$root/public/bin/common.sh"

# 假的下载器与安装器：只记录被怎么调用
cat > "$root/bin/proot-distro" <<'FAKE'
#!/usr/bin/env bash
printf 'proot-distro %s\n' "$*" >> "$CALL_LOG"
case "$1" in
  # 没装好就登不进去，与真实行为一致
  login) exit 1 ;;
  list) exit 0 ;;
  *) exit 0 ;;
esac
FAKE
cat > "$root/bin/curl" <<'FAKE'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$CALL_LOG"
exit "${NETWORK_DOWN:-0}"
FAKE
chmod +x "$root/bin/proot-distro" "$root/bin/curl"
export PATH="$root/bin:$PATH"
export CALL_LOG="$root/calls.log"

# shellcheck source=/dev/null
source "$root/public/bin/common.sh"

fail() { printf '失败：%s\n' "$1" >&2; exit 1; }

# 一、空壳目录（下载中断留下）不能被当成已安装
mkdir -p "$PROOT_ROOT/zbs-ubuntu"
if proot_distro_alias_exists "zbs-ubuntu"; then
  fail "下载中断留下的空壳被误判成已安装"
fi
printf '通过：空壳目录不会被误判成已安装\n'

# 二、完整装好的底座要能被识别
mkdir -p "$PROOT_ROOT/zbs-ubuntu/rootfs/etc"
if ! proot_distro_alias_exists "zbs-ubuntu"; then
  fail "装好的底座没有被识别"
fi
printf '通过：完整底座能被识别\n'

# 三、重装前先清掉空壳，再走安装命令
rm -rf "$PROOT_ROOT/zbs-ubuntu/rootfs"
: > "$CALL_LOG"
ensure_ubuntu >/dev/null 2>&1
if [ -e "$PROOT_ROOT/zbs-ubuntu/rootfs" ]; then
  fail "空壳没有被清理"
fi
grep -q 'proot-distro install ubuntu' "$CALL_LOG" \
  || fail "没有执行安装命令，实际记录：$(cat "$CALL_LOG" 2>/dev/null)"
printf '通过：重装前清理空壳，并执行了安装命令\n'

# 四、探测失败只提醒、不拦路：仍会尝试下载
#    （开着代理、分应用分流的环境里，探测方式可能和真实下载不一致，不能一棒子打死）
rm -rf "$PROOT_ROOT/zbs-ubuntu"
: > "$CALL_LOG"
code=0
output="$(NETWORK_DOWN=1 ensure_ubuntu 2>&1)" || code=$?
[ "$code" -eq 0 ] || fail "探测失败不该拦路，实际退出码 $code，输出：$output"
grep -q 'proot-distro install' "$CALL_LOG" \
  || fail "探测失败后没有继续尝试下载，实际记录：$(cat "$CALL_LOG" 2>/dev/null)"
printf '%s' "$output" | grep -q '仍会尝试下载' \
  || fail "没有给出"仍会尝试下载"的提示，实际输出：$output"
printf '通过：探测失败只提醒，仍会尝试下载\n'

# 五、真实下载失败时才报错，并且要说清楚怎么办
cat > "$root/bin/proot-distro" <<'FAKE'
#!/usr/bin/env bash
printf 'proot-distro %s\n' "$*" >> "$CALL_LOG"
case "$1" in
  install) exit 1 ;;
  login) exit 1 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$root/bin/proot-distro"
rm -rf "$PROOT_ROOT/zbs-ubuntu"
: > "$CALL_LOG"
code=0
output="$(NETWORK_DOWN=1 ensure_ubuntu 2>&1)" || code=$?
[ "$code" -ne 0 ] || fail "下载失败却没有报错"
printf '%s' "$output" | grep -q '下载中断' \
  || fail "下载失败的提示不明确，实际输出：$output"
printf '通过：下载失败时给出明确指引\n'

printf '\n运行底座安装验收：全部通过\n'
