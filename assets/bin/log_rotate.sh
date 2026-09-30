#!/data/data/com.termux/files/usr/bin/bash

# 日志轮转：按天分文件 + 超限就地轮转 + 过期自动清理。
#
# 关键约束：这里做的所有事都不能碰服务的输出通路。
# 服务进程是直接 `>>` 写日志文件的，它持有的是文件 inode，因此：
#   - 不能 mv/rm 正在写入的文件，否则服务会继续往已改名的 inode 写，日志从此"消失"；
#   - 只能用 copytruncate（先 cp 出副本，再把原文件截断成 0），
#     服务手里的文件描述符始终指向同一个 inode，写日志永远不会被阻塞。
set -u
export TZ="${TZ:-Asia/Shanghai}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

# 只轮转 15 分钟没动过的文件，避开正在高速写入的当前日志，减少 cp 与截断的竞态窗口。
ROTATE_QUIET_SECONDS=900

file_size() {
  wc -c < "$1" 2>/dev/null | tr -d '[:space:]'
}

file_age() {
  local now modified
  now="$(date +%s)"
  modified="$(date -r "$1" +%s 2>/dev/null || printf '0')"
  [[ "$modified" =~ ^[0-9]+$ ]] || modified=0
  printf '%s' "$((now - modified))"
}

# 这个文件是否正被某个进程打开（拿它当文件描述符）。
# 用途：服务长时间不重启时会一直写启动那天的文件，那个文件的 mtime 会永远停在启动日；
# 如果直接按天数删掉它，服务会继续往一个已经被删除的 inode 写，日志从此"凭空消失"。
log_in_use() {
  local target="$1"
  local fd real
  [ -r /proc/self/fd ] || return 1
  for fd in /proc/[0-9]*/fd/*; do
    [ -e "$fd" ] || continue
    real="$(readlink "$fd" 2>/dev/null || true)"
    [ "$real" = "$target" ] && return 0
  done
  return 1
}

# copytruncate：先把内容复制成 .1 留档，再把原文件就地清空。
# 必须用 cp 而不是 mv：服务进程正持有原文件的 inode，
# mv 之后它会继续往一个已经改名的文件里写，日志看起来就凭空消失了。
# 只保留一份 .1（下一轮轮转直接覆盖），不做 .1 -> .2 这种编号滚动，
# 否则一旦通配符把 .1.1 这类嵌套名也扫进来，编号会无限增长。
# 历史归档的"留存长度"交给 cleanup_old 按天数管理。
rotate_file() {
  local path="$1"
  local size
  size="$(file_size "$path")"
  [[ "$size" =~ ^[0-9]+$ ]] || return 0
  [ "$size" -gt 0 ] || return 0
  # 上一轮归档的副本还被某个进程用着（比如 watch 类命令），先别覆盖它
  if log_in_use "$path.1"; then
    return 0
  fi

  if ! cp -f "$path" "$path.1" 2>/dev/null; then
    return 0
  fi
  : > "$path" 2>/dev/null || true
  log "日志已轮转：$(basename "$path") $((size / 1024)) KB -> $(basename "$path").1"
}

# 超限的当天日志就地轮转。只扫 *.log，不碰 *.log.1，避免嵌套编号。
rotate_sized() {
  local directory="$1"
  local path size age
  for path in "$directory"/*.log; do
    [ -f "$path" ] || continue
    size="$(file_size "$path")"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    [ "$size" -ge "$LOG_MAX_BYTES" ] || continue
    age="$(file_age "$path")"
    [ "$age" -ge "$ROTATE_QUIET_SECONDS" ] || continue
    rotate_file "$path"
  done
}

# 2) 过期日志自动清理，用户不需要再手动删。
#    正在被进程打开的文件一律不删：删了它，服务会继续往一个已删除的 inode 写，
#    日志看起来就像"自己消失了"。
cleanup_old() {
  local directory="$1"
  local path age
  for path in "$directory"/*.log "$directory"/*.log.[0-9]*; do
    [ -f "$path" ] || continue
    age="$(file_age "$path")"
    [ "$age" -gt $((LOG_KEEP_DAYS * 86400)) ] || continue
    if log_in_use "$path"; then
      continue
    fi
    rm -f "$path" 2>/dev/null || true
  done
}

log_rotate_component() {
  local directory="$LOG_DIR/$1"
  [ -d "$directory" ] || return 0
  mkdir -p "$directory" 2>/dev/null || true
  rotate_sized "$directory"
  cleanup_old "$directory"
}

log_rotate_instance_dirs() {
  local parent="$LOG_DIR/astrbot"
  local directory
  [ -d "$parent" ] || return 0
  for directory in "$parent"/*; do
    [ -d "$directory" ] || continue
    log_rotate_component "astrbot/$(basename "$directory")"
  done
}

log_rotate_all() {
  local component
  for component in app napcat minilm astrbot; do
    log_rotate_component "$component"
  done
  log_rotate_instance_dirs
}

# 3) 兜底：把老版本遗留的 logs/<组件>.log 单文件（比如 70MB 的 napcat.log）也轮转掉，
#    但绝不删除它——里面可能还有用户想看的内容，只是从今往后不再增长。
log_rotate_legacy() {
  local component path size
  for component in app napcat minilm astrbot; do
    path="$LOG_DIR/$component.log"
    [ -f "$path" ] || continue
    size="$(file_size "$path")"
    [[ "$size" =~ ^[0-9]+$ ]] || continue
    [ "$size" -ge "$LOG_MAX_BYTES" ] || continue
    rotate_file "$path"
  done
}

# 被 source 时（例如 watchdog.sh）只加载函数，不立即执行；
# 直接运行时才做一次轮转。
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = "--legacy-only" ]; then
    log_rotate_legacy
  else
    log_rotate_all
  fi
fi
