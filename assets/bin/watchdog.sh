#!/data/data/com.termux/files/usr/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/common.sh"
# shellcheck source=log_rotate.sh
source "$SCRIPT_DIR/log_rotate.sh"

PID_FILE="$HOME_ROOT/config/watchdog.pid"
INTERVAL=20
NAPCAT_LOCK="$HOME_ROOT/config/watchdog-start-napcat.lock"
MINILM_LOCK="$HOME_ROOT/config/watchdog-start-minilm.lock"
NAPCAT_OFFSET="$HOME_ROOT/config/watchdog-napcat.log.offset"
NAPCAT_PATH="$HOME_ROOT/config/watchdog-napcat.log.path"

cleanup() {
  rm -f "$PID_FILE" 2>/dev/null || true
  exit 0
}
trap cleanup INT TERM EXIT

if [ -f "$PID_FILE" ]; then
  existing="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ "$existing" =~ ^[0-9]+$ ]] && [ "$existing" != "$$" ] && kill -0 "$existing" 2>/dev/null; then
    exit 0
  fi
fi
printf '%s\n' "$$" > "$PID_FILE"

# 启动时先把旧版遗留的 logs/<组件>.log 大单文件轮转掉（只轮转，不删除）。
log_rotate_legacy

log "服务守护已接管：NapCat / AstrBot / MiniLM"

refresh_termux_wake_lock() {
  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock >/dev/null 2>&1 || true
  fi
}

napcat_was_kicked() {
  local size offset napcat_log previous
  napcat_log="$LOG_DIR/napcat/$(date +%F).log"
  previous="$(cat "$NAPCAT_PATH" 2>/dev/null || true)"
  if [ "$previous" != "$napcat_log" ]; then
    printf '%s\n' "$napcat_log" > "$NAPCAT_PATH"
    printf '0\n' > "$NAPCAT_OFFSET"
  fi
  [ -f "$napcat_log" ] || return 1
  size="$(wc -c < "$napcat_log" 2>/dev/null || printf '0')"
  offset="$(cat "$NAPCAT_OFFSET" 2>/dev/null || printf '0')"
  [[ "$size" =~ ^[0-9]+$ ]] || return 1
  [[ "$offset" =~ ^[0-9]+$ ]] || offset=0
  if [ "$size" -lt "$offset" ]; then
    offset=0
  fi
  if [ "$size" -eq "$offset" ]; then
    return 1
  fi
  printf '%s\n' "$size" > "$NAPCAT_OFFSET"
  tail -c "+$((offset + 1))" "$napcat_log" 2>/dev/null | grep -Eiq \
    '被踢下线|KickedOffLine|kick(ed)?[[:space:]_-]*off[[:space:]_-]*line|登录失效|login[^[:cntrl:]]*(invalid|expired|kicked)'
}

while :; do
  refresh_termux_wake_lock

  # 日志轮转：超限就地 copytruncate，过期自动删除。纯文件操作，不碰任何服务的输出通路。
  log_rotate_all

  if [ -f "$HOME_ROOT/config/desired-napcat" ] && napcat_was_kicked; then
    rm -f "$HOME_ROOT/config/desired-napcat" "$NAPCAT_LOCK" 2>/dev/null || true
    log "检测到 QQ 被踢下线，已放弃 NapCat 自动保护，不会自动重登"
    "$PUBLIC_ROOT/bin/zbs.sh" stop-napcat >/dev/null 2>&1 &
  fi

  if [ -f "$HOME_ROOT/config/desired-napcat" ] \
      && ! is_port_open 6099 \
      && [ ! -e "$NAPCAT_LOCK" ]; then
    touch "$NAPCAT_LOCK"
    log "检测到 NapCat 端口 6099 掉线，尝试恢复"
    ("$PUBLIC_ROOT/bin/zbs.sh" start-napcat >/dev/null 2>&1; rm -f "$NAPCAT_LOCK") &
  fi

  if [ -f "$HOME_ROOT/config/desired-minilm" ] \
      && ! is_port_open 8000 \
      && [ ! -e "$MINILM_LOCK" ]; then
    touch "$MINILM_LOCK"
    log "检测到 MiniLM 端口 8000 掉线，尝试恢复"
    ("$PUBLIC_ROOT/bin/zbs.sh" start-minilm >/dev/null 2>&1; rm -f "$MINILM_LOCK") &
  fi

  for desired in "$HOME_ROOT"/instances/*/desired; do
    [ -f "$desired" ] || continue
    dir="$(dirname "$desired")"
    id="$(basename "$dir")"
    request="$HOME_ROOT/config/watchdog-$id.json"
    [ -f "$dir/instance.json" ] || continue
    port="$(json_value "$dir/instance.json" port "0")"
    [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] || continue
    lock="$dir/watchdog-start.lock"
    if ! is_port_open "$port" && [ ! -e "$lock" ]; then
      touch "$lock"
      log "检测到 AstrBot 实例 $id 端口 $port 掉线，尝试恢复"
      cp -f "$dir/instance.json" "$request" 2>/dev/null || continue
      ("$PUBLIC_ROOT/bin/zbs.sh" start-astrbot "$request" >/dev/null 2>&1; rm -f "$lock") &
    fi
  done

  sleep "$INTERVAL"
done
