#!/data/data/com.termux/files/usr/bin/bash

set -uo pipefail
export TZ="${TZ:-Asia/Shanghai}"

PUBLIC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOME_ROOT="${ZBS_HOME_ROOT:-$HOME/手机端值班室}"
LOG_DIR="$PUBLIC_ROOT/logs"
CONFIG_DIR="$PUBLIC_ROOT/config"
DOWNLOAD_DIR="$HOME_ROOT/downloads"
BACKUP_DIR="$PUBLIC_ROOT/backups"
PROOT_ROOT="$PREFIX/var/lib/proot-distro/installed-rootfs"
UBUNTU_ALIAS="zbs-ubuntu"
NAPCAT_ALIAS="zbs-napcat"
ASTRBOT_VERSION="4.27.3"
NAPCAT_VERSION="4.18.19"
NAPCAT_SHA256="c5b7423d1d5b8c555d62cd9e4059b1908cc0986e7b5c85a0f450f4a8ed170acf"
REQUIRED_QQ_VERSION="3.2.30-50969"
REQUIRED_QQ_BUILD="50969"
NAPCAT_QQ_APPIMAGE_URL="https://github.com/NapNeko/NapCatAppImageBuild/releases/download/v4.18.13/QQ-50969_NapCat-v4.18.13-arm64.AppImage"
NAPCAT_QQ_APPIMAGE_SHA256="89fd9dbe85b461529e0df2bf40f2a68b2d7a901a530bfe2771b60828feb439cd"
MINILM_MODEL="paraphrase-multilingual-MiniLM-L12-v2"
MINILM_ST_VERSION="6.1.0"
MINILM_TORCH_VERSION="2.14.0"
TASK_RESULT_MESSAGE=""

mkdir -p "$HOME_ROOT" "$LOG_DIR" "$CONFIG_DIR" "$DOWNLOAD_DIR" "$BACKUP_DIR" \
  "$HOME_ROOT/bin" "$HOME_ROOT/downloads" "$HOME_ROOT/instances" "$HOME_ROOT/models" \
  "$HOME_ROOT/runtime" "$HOME_ROOT/logs" "$HOME_ROOT/config" \
  "$CONFIG_DIR/status" 2>/dev/null || true

link_runtime() {
  local target="$1"
  local name="$2"
  rm -f "$HOME_ROOT/runtime/$name" 2>/dev/null || true
  ln -s "$target" "$HOME_ROOT/runtime/$name" 2>/dev/null || true
  rm -f "$PUBLIC_ROOT/runtime-$name" 2>/dev/null || true
  ln -s "$HOME_ROOT/runtime/$name" "$PUBLIC_ROOT/runtime-$name" 2>/dev/null || true
}

log() {
  printf '\033[1;36m[值班室]\033[0m %s\n' "$*"
}

ok() {
  printf '\033[1;32m[完成]\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33m[提醒]\033[0m %s\n' "$*"
}

fail() {
  printf '\033[1;31m[失败]\033[0m %s\n' "$*" >&2
}

die() {
  fail "$*"
  exit 1
}

json_escape() {
  printf '%s' "${1:-}" \
    | sed 's/\\/\\\\/g; s/"/\\"/g' \
    | tr '\r\n' '  '
}

write_task_status() {
  local state="$1"
  local code="${2:-0}"
  local line="${3:-0}"
  local message="${4:-}"
  local action
  [ -n "${TASK_STATUS_FILE:-}" ] || return 0
  action="$(json_escape "${ACTION:-unknown}")"
  message="$(json_escape "$message")"
  mkdir -p "$(dirname "$TASK_STATUS_FILE")" 2>/dev/null || true
  printf '{"action":"%s","state":"%s","code":%s,"line":%s,"message":"%s","updatedAt":"%s"}\n' \
    "$action" "$state" "$code" "$line" "$message" "$(date -Iseconds)" \
    > "$TASK_STATUS_FILE" 2>/dev/null || true
}

task_status_running() {
  write_task_status "running" 0 0 "${1:-任务正在执行}"
}

task_status_launched() {
  write_task_status "launched" 0 0 "${1:-终端会话已启动}"
}

task_status_success() {
  write_task_status "success" 0 0 "${1:-${TASK_RESULT_MESSAGE:-任务完成}}"
}

on_error() {
  local code=$?
  local line="${BASH_LINENO[0]:-0}"
  write_task_status "failed" "$code" "$line" "任务在第 $line 行中断，退出码 $code"
  fail "任务在第 ${line:-?} 行中断，退出码 ${code}"
  printf '终端会话将保留，便于查看日志。\n'
  exit "$code"
}

trap on_error ERR

json_value() {
  local file="$1"
  local key="$2"
  local fallback="${3:-}"
  if command -v jq >/dev/null 2>&1; then
    local value
    value="$(jq -r --arg key "$key" '.[$key] // empty' "$file" 2>/dev/null || true)"
    printf '%s' "${value:-$fallback}"
    return
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" "$fallback" <<'PY'
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as fh:
        value = json.load(fh).get(sys.argv[2], sys.argv[3])
    if isinstance(value, bool):
        print("true" if value else "false", end="")
    elif value is None:
        print(sys.argv[3], end="")
    else:
        print(value, end="")
except Exception:
    print(sys.argv[3], end="")
PY
    return
  fi
  die "缺少 jq/python3，无法读取任务参数"
}

require_request() {
  local request="${1:-}"
  [ -n "$request" ] && [ -f "$request" ] || die "任务参数文件不存在"
  printf '%s' "$request"
}

ensure_termux_tools() {
  local missing=0
  for command_name in unzip tar jq python3 wget proot-distro; do
    command -v "$command_name" >/dev/null 2>&1 || missing=1
  done
  command -v curl >/dev/null 2>&1 && curl --version >/dev/null 2>&1 || missing=1
  command -v python3 >/dev/null 2>&1 && python3 -c 'pass' >/dev/null 2>&1 || missing=1
  if [ "$missing" -eq 1 ]; then
    repair_termux_packages
    log "补齐终端基础工具"
    DEBIAN_FRONTEND=noninteractive apt-get install -y \
      curl wget unzip zip tar jq python proot-distro git openssl-tool
  fi
}

repair_termux_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "检查并修复 Termux 软件包状态"
  if ! apt-get update -o Acquire::Retries=3; then
    warn "现有软件源不可用，切换到 Termux 官方源后重试"
    mkdir -p "$PREFIX/etc/apt"
    printf '%s\n' \
      'deb https://packages-cf.termux.dev/apt/termux-main stable main' \
      > "$PREFIX/etc/apt/sources.list"
    apt-get update -o Acquire::Retries=3 || \
      die "Termux 软件源更新失败，请检查网络或零终端软件源设置"
  fi

  log "升级全部 Termux 软件包，修复 libcurl 等动态库错位"
  if ! apt-get -y -o Dpkg::Options::=--force-confold full-upgrade; then
    warn "整体升级未一次完成，尝试修复损坏依赖后重试"
    apt-get -y --fix-broken install || true
    apt-get -y -o Dpkg::Options::=--force-confold full-upgrade || \
      die "Termux 软件包修复失败"
  fi
  hash -r
  ok "Termux 软件包状态已修复"
}

ensure_storage() {
  log "申请并检查手机内部存储权限"
  local android_shared="/storage/emulated/0"
  local storage_link="$HOME/storage/shared"
  if [ ! -e "$storage_link" ] || ! ls "$storage_link" >/dev/null 2>&1; then
    if command -v termux-setup-storage >/dev/null 2>&1; then
      log "配置 ~/storage 并自动确认重建"
      printf 'y\ny\n' | termux-setup-storage || true
    fi
  fi
  for _ in $(seq 1 20); do
    ls "$android_shared" >/dev/null 2>&1 && break
    sleep 0.5
  done
  if ls "$android_shared" >/dev/null 2>&1; then
    mkdir -p "$HOME/storage"
    [ -e "$storage_link" ] || \
      ln -s "$android_shared" "$storage_link" 2>/dev/null || true
  fi
  if { [ -e "$storage_link" ] && ls "$storage_link" >/dev/null 2>&1; } \
      || ls "$android_shared" >/dev/null 2>&1; then
    ok "手机内部存储可访问"
    return 0
  fi
  die "无法访问手机内部存储，请在 ZeroTermux 中允许存储权限"
}

is_port_open() {
  local port="${1:-}"
  [ -n "$port" ] || return 1
  python3 - "$port" <<'PY' >/dev/null 2>&1
import socket, sys
s = socket.socket()
s.settimeout(0.35)
try:
    s.connect(("127.0.0.1", int(sys.argv[1])))
except Exception:
    raise SystemExit(1)
finally:
    s.close()
PY
}

pid_running() {
  local pid_file="$1"
  [ -f "$pid_file" ] || return 1
  local pid
  pid="$(cat "$pid_file" 2>/dev/null || true)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

ensure_watchdog() {
  local pid_file="$HOME_ROOT/config/watchdog.pid"
  local watchdog="$HOME_ROOT/bin/watchdog.sh"
  [ -x "$watchdog" ] || return 0
  if command -v termux-wake-lock >/dev/null 2>&1; then
    termux-wake-lock >/dev/null 2>&1 || true
  fi
  if pid_running "$pid_file"; then
    return 0
  fi
  rm -f "$pid_file" 2>/dev/null || true
  nohup "$watchdog" >> "$LOG_DIR/app.log" 2>&1 &
  echo $! > "$pid_file"
  log "后台服务守护已启动"
}

stop_pid_file() {
  local pid_file="$1"
  local marker="${2:-}"
  local pid=""
  [ -f "$pid_file" ] && pid="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
    log "正在停止进程 $pid"
    kill -TERM "$pid" 2>/dev/null || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.25
    done
    kill -0 "$pid" 2>/dev/null && kill -KILL "$pid" 2>/dev/null || true
  fi
  rm -f "$pid_file" 2>/dev/null || true
  if [ -n "$marker" ]; then
    pkill -TERM -f "$marker" 2>/dev/null || true
    sleep 1
    pkill -KILL -f "$marker" 2>/dev/null || true
  fi
}

ensure_ubuntu() {
  if ! proot_distro_alias_exists "$UBUNTU_ALIAS"; then
    log "安装 Ubuntu proot 运行时"
    proot-distro install ubuntu --override-alias "$UBUNTU_ALIAS" || \
      die "Ubuntu proot 安装失败"
  else
    log "Ubuntu proot 运行时已存在"
  fi
}

ensure_debian() {
  if ! proot_distro_alias_exists "$NAPCAT_ALIAS"; then
    log "安装 Debian proot 运行时"
    proot-distro install debian --override-alias "$NAPCAT_ALIAS" || \
      die "Debian proot 安装失败"
  else
    log "Debian proot 运行时已存在"
  fi
}

proot_distro_alias_exists() {
  local alias="$1"
  [ -d "$PROOT_ROOT/$alias" ] && return 0
  proot-distro login "$alias" -- /bin/true >/dev/null 2>&1 && return 0
  proot-distro list 2>/dev/null \
    | awk -v alias="$alias" '$1 == alias || $1 == alias ":" { found = 1 } END { exit !found }'
}

ubuntu_shell() {
  proot-distro login "$UBUNTU_ALIAS" \
    --bind "$HOME_ROOT:/opt/zhibanshi" \
    -- /bin/bash -lc "$1"
}

debian_shell() {
  proot-distro login "$NAPCAT_ALIAS" \
    --bind "$HOME_ROOT:/opt/zhibanshi" \
    -- /bin/bash -lc "$1"
}

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | awk '{print $NF}'
  fi
}

download_file() {
  local url="$1"
  local output="$2"
  local sha="${3:-}"
  local optional="${4:-0}"
  mkdir -p "$(dirname "$output")"
  if [ -s "$output" ]; then
    if [ -n "$sha" ]; then
      local current
      current="$(sha256_file "$output" | tr 'A-F' 'a-f')"
      if [ "$current" = "$(printf '%s' "$sha" | tr 'A-F' 'a-f')" ]; then
        ok "已有安装包且校验通过：$(basename "$output")"
        return
      fi
      warn "已有安装包校验不一致，重新下载：$(basename "$output")"
      rm -f "$output"
    else
      ok "复用已有安装包：$(basename "$output")"
      return
    fi
  fi
  log "下载：$url"
  if ! curl -fL --retry 3 --connect-timeout 20 -# "$url" -o "$output"; then
    rm -f "$output" 2>/dev/null || true
    warn "curl 下载失败，尝试使用 wget"
    if ! command -v wget >/dev/null 2>&1; then
      [ "$optional" = "1" ] && return 1
      die "下载失败：$(basename "$output")"
    fi
    if ! wget --tries=3 --timeout=20 -O "$output" "$url"; then
      rm -f "$output" 2>/dev/null || true
      [ "$optional" = "1" ] && return 1
      die "下载失败：$(basename "$output")"
    fi
  fi
  if [ ! -s "$output" ]; then
    rm -f "$output" 2>/dev/null || true
    [ "$optional" = "1" ] && return 1
    die "下载文件为空：$(basename "$output")"
  fi
  if [ -n "$sha" ]; then
    local actual
    actual="$(sha256_file "$output" | tr 'A-F' 'a-f')"
    if [ "$actual" != "$(printf '%s' "$sha" | tr 'A-F' 'a-f')" ]; then
      rm -f "$output" 2>/dev/null || true
      [ "$optional" = "1" ] && return 1
      die "校验失败，期望 $sha，实际 $actual"
    fi
    ok "SHA-256 校验通过"
  fi
}

sync_runtime_bundle() {
  local source target version
  mkdir -p "$HOME_ROOT/bin" "$HOME_ROOT/service" "$HOME_ROOT/config" 2>/dev/null || true

  source="$PUBLIC_ROOT/bin"
  target="$HOME_ROOT/bin"
  if [ -d "$source" ]; then
    for source_file in "$source"/*; do
      [ -f "$source_file" ] || continue
      cp -f "$source_file" "$target/" 2>/dev/null || \
        die "运行脚本同步失败：$(basename "$source_file")"
    done
    find "$target" -maxdepth 1 -type f \
      \( -name '*.sh' -o -name '*.py' \) -exec chmod 700 {} + 2>/dev/null || true
  fi

  source="$PUBLIC_ROOT/service"
  target="$HOME_ROOT/service"
  if [ -d "$source" ]; then
    for source_file in "$source"/*; do
      [ -f "$source_file" ] || continue
      cp -f "$source_file" "$target/" 2>/dev/null || true
    done
  fi

  version="$(cat "$PUBLIC_ROOT/VERSION" 2>/dev/null || printf 'unknown')"
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  printf '{"version":"%s","updatedAt":"%s","path":"%s"}\n' \
    "$(json_escape "$version")" "$(date -Iseconds)" "$(json_escape "$HOME_ROOT/bin")" \
    > "$CONFIG_DIR/runtime-bundle.json" 2>/dev/null || true
}

touch_runtime_state() {
  local name="$1"
  local target="$2"
  local version="$3"
  local extra_key="${4:-}"
  local extra_value="${5:-}"
  local extra=""
  if [ -n "$extra_key" ]; then
    extra=",\"$(json_escape "$extra_key")\":\"$(json_escape "$extra_value")\""
  fi
  printf '{"name":"%s","path":"%s","version":"%s","updatedAt":"%s"%s}\n' \
    "$name" "$target" "$version" "$(date -Iseconds)" "$extra" \
    > "$CONFIG_DIR/$name-runtime.json"
}

latest_backup_in_folder() {
  local folder="$1"
  find "$folder" -maxdepth 1 -type f -name '*.zip' -printf '%T@ %p\n' 2>/dev/null \
    | sort -nr | head -n 1 | cut -d' ' -f2-
}
