#!/usr/bin/env bash
# 任务锁验收：确认同一时间只允许一个任务在跑，并且能自动接管被系统杀掉的残锁。
# 用法：bash tools/test_task_lock.sh
set -uo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

export HOME="$root/home"
export PREFIX="$root/prefix"
export ZBS_HOME_ROOT="$root/home/手机端值班室"
mkdir -p "$HOME" "$PREFIX" "$ZBS_HOME_ROOT" "$root/public/bin"
cp "$base/assets/bin/common.sh" "$root/public/bin/common.sh"

# shellcheck source=/dev/null
source "$root/public/bin/common.sh"

fail() { printf '失败：%s\n' "$1" >&2; exit 1; }

# 1) 首次加锁应当成功，锁文件里要写着自己的进程号
acquire_task_lock "测试任务"
[ -f "$TASK_LOCK_FILE" ] || fail "锁文件没有创建"
[ "$(cat "$TASK_LOCK_FILE")" = "$$" ] || fail "锁文件里记录的不是当前进程号"
printf '通过：首次加锁成功（进程号 %s）\n' "$$"

# 2) 另开一个进程来抢锁，应该被拒绝
if bash -c "source '$root/public/bin/common.sh'; acquire_task_lock 抢锁任务" 2>/dev/null; then
  fail "第二个任务没有被拒绝，锁失效了"
fi
printf '通过：第二个任务被锁挡住\n'

# 3) 释放之后应当可以重新加锁
release_task_lock
[ ! -f "$TASK_LOCK_FILE" ] || fail "释放后锁文件仍然存在"
acquire_task_lock "第二回合"
[ -f "$TASK_LOCK_FILE" ] || fail "释放后无法重新加锁"
printf '通过：释放后能重新加锁\n'
release_task_lock

# 4) 被系统强杀留下的残锁（持有者已不存在）应当被自动接管
printf '%s\n' "999999" > "$TASK_LOCK_FILE"
acquire_task_lock "接管残锁"
[ "$(cat "$TASK_LOCK_FILE")" = "$$" ] || fail "残锁没有被自动接管"
printf '通过：残锁被自动接管\n'
release_task_lock

printf '\n任务锁验收：全部通过（互斥生效 / 释放干净 / 残锁自动接管）\n'
