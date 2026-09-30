#!/data/data/com.termux/files/usr/bin/bash

set -u
export TZ="${TZ:-Asia/Shanghai}"

root="$1"
component="$2"
mirror="${3:-quiet}"
instance="${4:-}"
if [ -z "$root" ] || [ -z "$component" ]; then
  exit 2
fi
case "$component" in
  app|napcat|minilm|astrbot) ;;
  *) exit 2 ;;
esac
day=""
next_check=0
log_path=""
instance_path=""

while IFS= read -r line || [ -n "$line" ]; do
  if [ "$SECONDS" -ge "$next_check" ]; then
    today="$(date +%F)"
    next_check=$((SECONDS + 5))
    if [ "$today" != "$day" ]; then
      day="$today"
      log_path="$root/logs/$component/$day.log"
      if [ -n "$instance" ]; then
        instance_path="$root/logs/$component/$instance/$day.log"
      fi
    fi
  fi
  # Recreate folders even when they are deleted while the process is alive.
  mkdir -p "$root/logs/$component" 2>/dev/null || true
  if [ -n "$instance" ]; then
    mkdir -p "$root/logs/$component/$instance" 2>/dev/null || true
  fi
  if [ -n "$instance_path" ]; then
    printf '%s\n' "$line" >> "$instance_path"
    printf '%s\n' "$line" >> "$log_path"
  else
    printf '%s\n' "$line" >> "$log_path"
  fi
  if [ "$mirror" = "stdout" ]; then
    printf '%s\n' "$line"
  fi
done
