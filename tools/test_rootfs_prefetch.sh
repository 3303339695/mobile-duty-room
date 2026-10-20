#!/usr/bin/env bash
# 验证"镜像预取"的四条路：
#   一、能从配置里读出下载地址与摘要
#   二、缓存里已有且校验通过时直接复用，不联网
#   三、手机下载目录里已有文件时自动捡起
#   四、缓存和下载目录都没有时，多源下载（镜像源失败会回退官方）
#   五、校验不一致的坏文件会被丢弃重取
# 用假的下载器，不会真的联网。
# 用法：bash tools/test_rootfs_prefetch.sh
set -uo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

export HOME="$root/home"
export PREFIX="$root/prefix"
export ZBS_HOME_ROOT="$root/home/手机端值班室"
export CALL_LOG="$root/calls.log"
export PAYLOAD="$root/payload.tar.xz"
mkdir -p "$HOME" "$PREFIX" "$ZBS_HOME_ROOT" "$root/public/bin" "$root/bin"
cp "$base/assets/bin/common.sh" "$root/public/bin/common.sh"

# 假的镜像内容
printf 'FAKE-ROOTFS-PAYLOAD\n' > "$PAYLOAD"
real_sha="$(sha256sum "$PAYLOAD" | awk '{print $1}')"
file_name="ubuntu-test-aarch64-rootfs.tar.xz"
file_url="https://github.invalid/termux/proot-distro/releases/download/v9/$file_name"

# 假的发行版配置：故意用不同写法，验证是"按地址和摘要抓"而不是认变量名
mkdir -p "$PREFIX/etc/proot-distro"
cat > "$PREFIX/etc/proot-distro/ubuntu.sh" <<EOF
DISTRO_NAME="Ubuntu Test"
DISTRO_COMMENT="for test only"
ANY_VAR_FOR_URL="$file_url"
ANY_VAR_FOR_SUM="$real_sha"
EOF

# 假的下载器：镜像源故意失败，官方源成功；同时记录被怎么调用
cat > "$root/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
prev=""
for arg in "$@"; do
  if [ "$prev" = "-o" ]; then out="$arg"; fi
  prev="$arg"
done
url="${*: -1}"
printf 'curl %s\n' "$url" >> "$CALL_LOG"
case "$url" in
  *mirror.invalid*) exit 1 ;;
esac
cp "$PAYLOAD" "$out"
FAKE
chmod +x "$root/bin/curl"
export PATH="$root/bin:$PATH"

# shellcheck source=/dev/null
source "$root/public/bin/common.sh"

fail() { printf '失败：%s\n' "$1" >&2; exit 1; }

cache="$PREFIX/var/lib/proot-distro/dlcache"
mkdir -p "$cache"

# 一、能从配置里读出地址与摘要
info="$(proot_distro_rootfs_info "ubuntu")" || fail "读不出镜像信息"
[ "$(printf '%s' "$info" | sed -n '1p')" = "$file_url" ] || fail "地址抓错了：$info"
[ "$(printf '%s' "$info" | sed -n '2p')" = "$real_sha" ] || fail "摘要抓错了：$info"
printf '通过：能从配置里读出地址与摘要（不依赖变量名）\n'

# 二、缓存里已有且校验通过时直接复用，不联网
cp "$PAYLOAD" "$cache/$file_name"
: > "$CALL_LOG"
prefetch_rootfs "ubuntu" "Ubuntu" >/dev/null 2>&1 || fail "缓存命中时居然失败"
if [ -s "$CALL_LOG" ]; then
  fail "缓存已命中却还是去联网了：$(cat "$CALL_LOG")"
fi
printf '通过：缓存命中时直接复用，完全不联网\n'

# 三、手机下载目录里已有文件时自动捡起
rm -f "$cache/$file_name"
mkdir -p "$HOME/storage/downloads"
cp "$PAYLOAD" "$HOME/storage/downloads/$file_name"
: > "$CALL_LOG"
prefetch_rootfs "ubuntu" "Ubuntu" >/dev/null 2>&1 || fail "下载目录捡起时失败"
[ -s "$cache/$file_name" ] || fail "没有把下载目录里的文件放进缓存"
if [ -s "$CALL_LOG" ]; then
  fail "下载目录已有文件却还是去联网了：$(cat "$CALL_LOG")"
fi
printf '通过：自动从手机下载目录捡起现成文件\n'

# 四、都没有时多源下载：镜像源失败，回退官方
rm -f "$cache/$file_name" "$HOME/storage/downloads/$file_name"
: > "$CALL_LOG"
ZBS_GITHUB_MIRROR="https://mirror.invalid" \
  prefetch_rootfs "ubuntu" "Ubuntu" >/dev/null 2>&1 || fail "多源下载失败"
[ -s "$cache/$file_name" ] || fail "多源下载后缓存里没有文件"
grep -q 'mirror.invalid' "$CALL_LOG" || fail "没有尝试镜像源"
grep -q 'github.invalid' "$CALL_LOG" || fail "没有回退到官方源"
printf '通过：镜像源失败后自动回退官方源\n'

# 五、校验不一致的坏文件会被丢弃重取
printf 'BROKEN-CONTENT\n' > "$cache/$file_name"
: > "$CALL_LOG"
prefetch_rootfs "ubuntu" "Ubuntu" >/dev/null 2>&1 || fail "坏文件场景下没能重新获取"
got="$(sha256sum "$cache/$file_name" | awk '{print $1}')"
[ "$got" = "$real_sha" ] || fail "坏文件没有被替换成正确内容"
printf '通过：校验不一致的坏文件会被丢弃并重新获取\n'

# 六、下载目录里的文件能被自动认领（不用手动移动）
target="$root/public/downloads/aaa.zip"
rm -f "$target"
mkdir -p "$HOME/storage/downloads"
printf 'ADOPTED-CONTENT\n' > "$HOME/storage/downloads/aaa.zip"
adopt_downloaded_file "$target" >/dev/null 2>&1 || fail "没能认领下载目录里的文件"
[ -s "$target" ] || fail "认领之后目标位置没有文件"
[ "$(cat "$target")" = "ADOPTED-CONTENT" ] || fail "认领过来的内容不对"
printf '通过：能从手机下载目录自动认领文件\n'

printf '\n镜像预取验收：全部通过\n'
