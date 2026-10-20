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
# LIST_SAYS_INSTALLED=1 用来模拟"底层工具登记表里还挂着这个实例"
cat > "$root/bin/proot-distro" <<'FAKE'
#!/usr/bin/env bash
printf 'proot-distro %s\n' "$*" >> "$CALL_LOG"
case "$1" in
  # 没装好就登不进去，与真实行为一致
  login) exit 1 ;;
  list)
    if [ "${LIST_SAYS_INSTALLED:-0}" = "1" ]; then
      printf 'zbs-ubuntu\n'
    fi
    exit 0
    ;;
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

# 一·补、底层工具登记表里挂着、但磁盘上没有内容，同样不能算已安装
#      （这正是"看起来装着、一登录就崩、想重装又报同名已存在"的死循环来源）
: > "$CALL_LOG"
export LIST_SAYS_INSTALLED=1
if proot_distro_alias_exists "zbs-ubuntu"; then
  fail "登记表里挂着但文件不存在，却被当成已安装"
fi
printf '通过：只认磁盘上的真实文件，不盲信登记表\n'
unset LIST_SAYS_INSTALLED

# 二、完整装好的底座要能被识别
mkdir -p "$PROOT_ROOT/zbs-ubuntu/rootfs/etc"
if ! proot_distro_alias_exists "zbs-ubuntu"; then
  fail "装好的底座没有被识别"
fi
printf '通过：完整底座能被识别\n'

# 三、重装前先清掉残留，并且要注销底层工具的登记
rm -rf "$PROOT_ROOT/zbs-ubuntu/rootfs"
: > "$CALL_LOG"
export LIST_SAYS_INSTALLED=1
ensure_ubuntu >/dev/null 2>&1
unset LIST_SAYS_INSTALLED
if [ -e "$PROOT_ROOT/zbs-ubuntu/rootfs" ]; then
  fail "空壳没有被清理"
fi
grep -q 'proot-distro remove' "$CALL_LOG" \
  || fail "没有注销底层工具里的残留登记，实际记录：$(cat "$CALL_LOG" 2>/dev/null)"
grep -q 'proot-distro install ubuntu' "$CALL_LOG" \
  || fail "没有执行安装命令，实际记录：$(cat "$CALL_LOG" 2>/dev/null)"
printf '通过：重装前清理残留并注销登记，然后执行安装\n'

# 四、救援机制失败（镜像没备好）时不能阻断安装，要继续让安装器自己试
rm -rf "$PROOT_ROOT/zbs-ubuntu"
: > "$CALL_LOG"
code=0
output="$(NETWORK_DOWN=1 ensure_ubuntu 2>&1)" || code=$?
[ "$code" -eq 0 ] || fail "救援失败不该阻断安装，实际退出码 $code，输出：$output"
grep -q 'proot-distro install' "$CALL_LOG" \
  || fail "救援失败后没有继续安装，实际记录：$(cat "$CALL_LOG" 2>/dev/null)"
printf '%s' "$output" | grep -q '交给安装器自己下载' \
  || fail "没有说明会交给安装器继续尝试，实际输出：$output"
printf '通过：救援机制失败时仍会继续安装\n'

# 五、安装两次都失败时才报错，并且要说清楚下一步怎么办
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
[ "$code" -ne 0 ] || fail "安装失败却没有报错"
printf '%s' "$output" | grep -q '没装成' \
  || fail "安装失败的提示不明确，实际输出：$output"
install_times="$(grep -c 'proot-distro install' "$CALL_LOG")"
[ "$install_times" -ge 2 ] || fail "失败后没有自动重试，实际安装次数 $install_times"
printf '%s' "$output" | grep -qE '救急办法|代理是否覆盖' \
  || fail "没有给出下一步的指引，实际输出：$output"
printf '通过：安装失败会自动重试，并给出下一步指引\n'

printf '\n运行底座安装验收：全部通过\n'
