#!/usr/bin/env bash
# 日志逻辑验收：日切路径、超限轮转、过期清理、旧版遗留兼容。
# 在 Termux 里运行：bash tools/test_log_rotate.sh
# 用假的 HOME/PREFIX 隔离测试，不会碰真实部署目录。
set -euo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

export HOME="$root/home"
export PREFIX="$root/prefix"
export ZBS_HOME_ROOT="$root/home/手机端值班室"
mkdir -p "$HOME" "$PREFIX" "$ZBS_HOME_ROOT" "$root/public/bin"

cp "$base/assets/bin/common.sh" "$root/public/bin/common.sh"
cp "$base/assets/bin/log_rotate.sh" "$root/public/bin/log_rotate.sh"

# shellcheck source=/dev/null
source "$root/public/bin/common.sh"
# shellcheck source=/dev/null
source "$root/public/bin/log_rotate.sh"

fail() { printf '失败：%s\n' "$1" >&2; exit 1; }

today="$(date +%F)"

# 1) 日切路径：logs/<组件>/<日期>.log
prepare_log_dir app
[ "$(log_file app)" = "$LOG_DIR/app/$today.log" ] || fail "log_file 路径不对：$(log_file app)"
[ -d "$LOG_DIR/app" ] || fail "prepare_log_dir 没有建立目录"
printf 'hello\n' >> "$(log_file app)"
[ "$(cat "$(log_file app)")" = "hello" ] || fail "日志写入失败"

# 2) 实例日志目录：logs/astrbot/<实例ID>/<日期>.log
prepare_log_dir "astrbot/bot-one"
[ "$(log_file "astrbot/bot-one")" = "$LOG_DIR/astrbot/bot-one/$today.log" ] \
  || fail "实例日志路径不对"
printf 'instance\n' >> "$(log_file "astrbot/bot-one")"

# 3) 超限就地轮转：原文件清空、内容进 .1、只保留单副本
prepare_log_dir napcat
big="$LOG_DIR/napcat/$today.log"
head -c $((LOG_MAX_BYTES + 1024)) /dev/zero | tr '\0' 'x' > "$big"
touch -d '30 minutes ago' "$big"
rotate_sized "$LOG_DIR/napcat"
[ -f "$big.1" ] || fail "超限日志没有生成 .1 副本"
[ "$(wc -c < "$big")" = "0" ] || fail "轮转后原文件没有清空（服务还在写它）"
[ "$(wc -c < "$big.1")" -ge "$LOG_MAX_BYTES" ] || fail ".1 副本大小不对"

# 4) 再轮一次：不得出现 .2 或 .1.1 这类嵌套编号
head -c $((LOG_MAX_BYTES + 1024)) /dev/zero | tr '\0' 'y' > "$big"
touch -d '30 minutes ago' "$big"
rotate_sized "$LOG_DIR/napcat"
copies="$(find "$LOG_DIR/napcat" -type f | wc -l)"
[ "$copies" = "2" ] || fail "轮转后文件数量应为 2，实际 $copies（出现嵌套编号了）"
[ "$(head -c 1 "$big.1")" = "y" ] || fail ".1 没有被最新一轮覆盖"

# 5) 刚写入的日志不轮转（安静期保护）
prepare_log_dir app
fresh="$LOG_DIR/app/$today.log"
head -c $((LOG_MAX_BYTES + 1024)) /dev/zero | tr '\0' 'z' > "$fresh"
rotate_sized "$LOG_DIR/app"
[ ! -f "$fresh.1" ] || fail "刚写入的日志被轮转了（应等安静 15 分钟）"

# 6) 过期自动清理（用显式日期，兼容 Termux 的 busybox date）
prepare_log_dir minilm
old="$LOG_DIR/minilm/2026-01-01.log"
printf 'stale\n' > "$old"
touch -t 202601010000 "$old"
cleanup_old "$LOG_DIR/minilm"
[ ! -f "$old" ] || fail "过期日志没有被删除"

# 7) 当天日志不被清理
cleanup_old "$LOG_DIR/app"
[ -f "$fresh" ] || fail "当天日志被误删"

# 8) 旧版遗留大单文件：只轮转，绝不删除
legacy="$LOG_DIR/napcat.log"
head -c $((LOG_MAX_BYTES + 2048)) /dev/zero | tr '\0' 'w' > "$legacy"
log_rotate_legacy
[ -f "$legacy.1" ] || fail "遗留 napcat.log 没有轮转"
[ -f "$legacy" ] || fail "遗留 napcat.log 被删除了（应该保留）"
[ "$(wc -c < "$legacy")" = "0" ] || fail "遗留 napcat.log 轮转后没有清空"

# 9) 正在被服务占用的旧日志必须保住：服务跨天一直运行时它锁定的就是这种文件
prepare_log_dir app
held="$LOG_DIR/app/2026-01-02.log"
printf 'held-by-service\n' > "$held"
touch -t 202601020000 "$held"
exec 9>>"$held"
cleanup_old "$LOG_DIR/app"
exec 9>&-
[ -f "$held" ] || fail "正在被占用的旧日志被删除了（服务会写进已删除的 inode）"

# 10) 没有进程占用的过期日志才该被清掉
idle="$LOG_DIR/app/2026-01-03.log"
printf 'idle\n' > "$idle"
touch -t 202601030000 "$idle"
cleanup_old "$LOG_DIR/app"
[ ! -f "$idle" ] || fail "没人占用的过期日志没有被清理"

printf '日志逻辑验收：全部通过（日切 / 轮转 / 清理 / 占用保护 / 遗留兼容）\n'
