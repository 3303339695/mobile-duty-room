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

# 单个日志文件超过这个大小就地轮转成 .1 .2，避免再攒出 70MB 的单文件。
LOG_MAX_BYTES=$((10 * 1024 * 1024))
# 超过这个天数的日志自动删除，用户不需要再手动清。
LOG_KEEP_DAYS=7

prepare_log_dir() {
  local component="$1"
  mkdir -p "$LOG_DIR/$component" 2>/dev/null || true
}

log_file() {
  local component="$1"
  prepare_log_dir "$component"
  printf '%s/%s/%s.log' "$LOG_DIR" "$component" "$(date +%F)"
}

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
  local message="$*"
  local line="${BASH_LINENO[0]:-0}"
  fail "$message"
  # 直接把失败原因写进任务状态文件。
  # 否则任务明明已经失败退出，界面却还停在"进行中"转圈，看不出到底出了什么事。
  # 行号也一并记下来，界面就不会显示"未知位置"这种没用的信息。
  if [ -n "${TASK_STATUS_FILE:-}" ]; then
    write_task_status "failed" 1 "${line:-0}" "$message" 2>/dev/null || true
  fi
  exit 1
}

TASK_LOCK_FILE="$CONFIG_DIR/task.lock"

# 同一时间只允许一个任务在跑。
# 手机上很容易出现"点了初始化，觉得卡住，又去点停服务并清缓存"这种情况，
# 于是两个任务同时去动软件包管理：一个在装，另一个也在装/清缓存，
# 互相把对方打断，留下"配置未完成"的半截状态，
# 之后不管点什么都只会报同一句"安装被中断"，而且不会自己好。
# 有了这把锁，第二个任务会直接被挡在门外并告诉用户先等一等。
acquire_task_lock() {
  local label="${1:-任务}"
  local holder=""
  mkdir -p "$CONFIG_DIR" 2>/dev/null || true
  if [ -f "$TASK_LOCK_FILE" ]; then
    holder="$(cat "$TASK_LOCK_FILE" 2>/dev/null || true)"
    # 只有持有者还活着才算真的在忙；上一次被系统杀掉留下的残锁会被自动接管。
    if [[ "$holder" =~ ^[0-9]+$ ]] && [ "$holder" != "$$" ] && kill -0 "$holder" 2>/dev/null; then
      die "已有一个任务正在执行，请等它结束后再操作，不要重复点击（占用的进程号 $holder）"
    fi
  fi
  printf '%s\n' "$$" > "$TASK_LOCK_FILE" 2>/dev/null || true
}

release_task_lock() {
  local holder
  holder="$(cat "$TASK_LOCK_FILE" 2>/dev/null || true)"
  [ "$holder" = "$$" ] || return 0
  rm -f "$TASK_LOCK_FILE" 2>/dev/null || true
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
    # 这里必须判失败：否则工具没装上，后面每一条命令都会"找不到"，
    # 报出来的错完全看不出根因。
    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y \
        curl wget unzip zip tar jq python proot-distro git openssl-tool; then
      die "终端基础工具没装上（多半是软件源或网络问题）。请确认网络后重新点一次部署；如果反复失败，可以在 ZeroTermux 里手动执行下面这条，成功后再回来：
apt-get update && apt-get install -y curl wget unzip zip tar jq python proot-distro git openssl-tool"
    fi
  fi
}

repair_termux_packages() {
  export DEBIAN_FRONTEND=noninteractive
  log "检查并修复 Termux 软件包状态"

  # 手机上的终端经常因为息屏、切到后台被系统冻结，软件包装到一半就停在那里。
  # 这种"配置未完成"的状态会让之后任何一次安装都直接报错退出，
  # 必须先把这个半截的配置跑完，后面的升级和安装才有可能成功。
  log "先完成上次被打断的软件包配置"
  if ! dpkg --configure -a; then
    warn "仍有软件包配置没有完成，稍后升级失败时会再补一次"
  fi

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
    warn "整体升级未一次完成，先补完被打断的配置再修复依赖"
    dpkg --configure -a || true
    apt-get -y --fix-broken install || true
    apt-get -y -o Dpkg::Options::=--force-confold full-upgrade || \
      die "Termux 软件包修复失败：请在 ZeroTermux 里手动执行「dpkg --configure -a」，完成后重新点“一键初始化”"
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
  # 守护进程的 stdout 直接追加到当天文件。
  # 这里绝不能接 `> >(bash log_daily.sh ...)` 这类管道消费者：
  # 消费者变慢会填满管道把守护进程堵死，消费者被系统杀掉会让守护进程吃 SIGPIPE 直接退出，
  # 两种情况都会让保活失效（息屏一会儿服务就全停）。详见 README 的日志说明。
  prepare_log_dir "app"
  nohup "$watchdog" >> "$(log_file app)" 2>&1 &
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

# 探测某个站点是否可达。
# 只用来在长时间等待之前先给用户一句提醒，绝不参与"能不能下载"的最终判断。
# 注意：某些代理或分应用分流环境下，探测结果与真实下载并不一致，
# 所以调用方只把它当作提示，不当作拦截条件。
network_reachable() {
  local host="${1:-github.com}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsS -o /dev/null --connect-timeout 8 --max-time 15 "https://$host" >/dev/null 2>&1 \
      && return 0
    return 1
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -O /dev/null --timeout=15 "https://$host" >/dev/null 2>&1 && return 0
    return 1
  fi
  return 0
}

# 找出手机代理软件在本机开的通道端口。
# 手机上开了代理，浏览器知道走它，但终端默认不知道——这就是
# "浏览器能下载、终端死活连不上"的最常见原因。
# 这里把主流代理软件的常见端口挨个试一遍，谁开着就是谁。
detect_local_proxy_port() {
  local port
  for port in 7890 7891 7897 10809 10808 1080 8889 8080 2080 20171 6152; do
    if is_port_open "$port"; then
      printf '%s' "$port"
      return 0
    fi
  done
  return 1
}

# 让终端的网络流量也走本机代理。
# 安全性：设置之后立刻验证一次能不能连通，连不通就撤销，
# 避免把本来能用的网络搞坏。
ZBS_PROXY_READY=0
ensure_proxy_for_downloads() {
  [ "$ZBS_PROXY_READY" = "1" ] && return 0
  ZBS_PROXY_READY=1

  # 用户自己设过代理就别插手
  if [ -n "${https_proxy:-}" ] || [ -n "${HTTPS_PROXY:-}" ]; then
    log "沿用已有的代理设置"
    return 0
  fi

  local port
  port="$(detect_local_proxy_port 2>/dev/null || true)"
  [ -n "$port" ] || return 0

  local proxy_url="http://127.0.0.1:$port"
  export http_proxy="$proxy_url"
  export https_proxy="$proxy_url"
  export HTTP_PROXY="$proxy_url"
  export HTTPS_PROXY="$proxy_url"

  if network_reachable "github.com"; then
    log "检测到本机代理端口 $port，已让终端流量走代理"
    return 0
  fi

  # 连不通就撤销，别把原本正常的网络弄坏
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
  warn "本机端口 $port 看起来像代理但连不通，已忽略它"
  return 1
}

# 从发行版配置里读出真实的下载地址和摘要。
# 不依赖配置里的变量名，直接按"以 .tar.xz 结尾的地址"和"64 位十六进制摘要"去抓，
# 这样底层工具改了变量名也不会失效；抓不到就让调用方回退到原来的联网安装。
proot_distro_rootfs_info() {
  local distro="$1"
  local conf="$PREFIX/etc/proot-distro/$distro.sh"
  [ -f "$conf" ] || return 1
  local url sha
  url="$(grep -oE 'https://[^"[:space:]]+\.tar\.xz' "$conf" 2>/dev/null | head -n 1)"
  sha="$(grep -oE '[0-9a-f]{64}' "$conf" 2>/dev/null | head -n 1)"
  [ -n "$url" ] || return 1
  printf '%s\n%s\n' "$url" "$sha"
}

# 在本地找已经下好的镜像：先看缓存目录，再看手机下载目录。
# 手机下载目录这一条是关键——浏览器走的是系统的网络，往往能打开用户手动下载，
# 用户下完不用移动文件，这里会自动捡起来。
find_local_rootfs() {
  local name="$1"
  local cache="$PREFIX/var/lib/proot-distro/dlcache"
  local candidate
  if [ -s "$cache/$name" ]; then
    printf '%s' "$cache/$name"
    return 0
  fi
  for candidate in \
    "$HOME/storage/downloads/$name" \
    "$HOME/storage/shared/Download/$name" \
    "$HOME/storage/shared/下载/$name" \
    "/storage/emulated/0/Download/$name" \
    "/storage/emulated/0/下载/$name"; do
    if [ -s "$candidate" ]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# 下载前先问一下文件多大，好告诉用户要等多久。
# 这里绝不能开下载器自带的进度条：它每涨一点点就刷一行，
# 一个几十兆的文件能把日志刷到爆，界面就只剩"仅显示最后 256 KB"，
# 反而什么有用信息都看不见。
announce_download_size() {
  local url="$1"
  local label="$2"
  local bytes
  bytes="$(curl -sIL --connect-timeout 8 --max-time 15 "$url" 2>/dev/null \
    | tr -d '\r' \
    | awk 'tolower($1) == "content-length:" { size = $2 } END { print size }')"
  if [[ "$bytes" =~ ^[0-9]+$ ]] && [ "$bytes" -gt 0 ]; then
    if [ "$bytes" -ge 1048576 ]; then
      log "正在下载${label}（约 $((bytes / 1048576)) MB），请耐心等待"
    else
      log "正在下载${label}（约 $((bytes / 1024)) KB）"
    fi
    return 0
  fi
  log "正在下载${label}，请耐心等待"
  return 0
}

# 断点续传下载单个文件。静默进行，不往日志里刷进度条。
fetch_with_resume() {
  local url="$1"
  local output="$2"
  mkdir -p "$(dirname "$output")" 2>/dev/null || true
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 4 --retry-delay 3 --connect-timeout 20 -C - \
      -o "$output" "$url" >&2 && [ -s "$output" ]
    return $?
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -c --tries=4 --timeout=20 -O "$output" "$url" >&2 && [ -s "$output" ]
    return $?
  fi
  return 1
}

# 把运行镜像提前备到缓存里，让底层工具安装时直接命中，不再联网。
# 三步走：一、缓存里已经有且校验通过；二、从手机下载目录捡现成的；
# 三、自己断点续传多源下载。任何一步成功，安装就几乎不会再因网络失败。
prefetch_rootfs() {
  local distro="$1"
  local label="$2"
  local info url sha name cache target found source
  local -a sources=()

  info="$(proot_distro_rootfs_info "$distro" 2>/dev/null || true)" || return 1
  url="$(printf '%s' "$info" | sed -n '1p')"
  sha="$(printf '%s' "$info" | sed -n '2p')"
  [ -n "$url" ] || return 1

  name="${url##*/}"
  cache="$PREFIX/var/lib/proot-distro/dlcache"
  mkdir -p "$cache" 2>/dev/null || true
  target="$cache/$name"

  # 一、缓存里已经有且校验通过
  if [ -s "$target" ]; then
    if [ -z "$sha" ] || \
        [ "$(sha256_file "$target" | tr 'A-F' 'a-f')" = "$(printf '%s' "$sha" | tr 'A-F' 'a-f')" ]; then
      ok "${label}镜像已在本地缓存，直接使用"
      return 0
    fi
    warn "本地缓存的镜像校验不一致，丢弃重来"
    rm -f "$target" 2>/dev/null || true
  fi

  # 二、手机下载目录里可能已经有用户用浏览器下好的
  if found="$(find_local_rootfs "$name")" && [ -n "$found" ]; then
    log "在手机下载目录发现镜像：$found"
    if cp -f "$found" "$target" 2>/dev/null; then
      if [ -z "$sha" ] || \
          [ "$(sha256_file "$target" | tr 'A-F' 'a-f')" = "$(printf '%s' "$sha" | tr 'A-F' 'a-f')" ]; then
        ok "已把下载好的镜像放进缓存"
        return 0
      fi
      warn "这个文件校验不一致，不用它"
      rm -f "$target" 2>/dev/null || true
    fi
  fi

  # 三、自己下载：先试用户指定的加速源，再试官方地址，逐字节校验
  if [ -n "${ZBS_GITHUB_MIRROR:-}" ]; then
    sources+=("${ZBS_GITHUB_MIRROR%/}/$url")
  fi
  sources+=("$url")
  for source in "${sources[@]}"; do
    log "下载${label}镜像：$source"
    if ! fetch_with_resume "$source" "$target"; then
      warn "这个源没下成功，换下一个"
      continue
    fi
    if [ -n "$sha" ] && \
        [ "$(sha256_file "$target" | tr 'A-F' 'a-f')" != "$(printf '%s' "$sha" | tr 'A-F' 'a-f')" ]; then
      warn "下载内容校验不一致，丢弃"
      rm -f "$target" 2>/dev/null || true
      continue
    fi
    ok "${label}镜像已就绪"
    return 0
  done
  return 1
}

# 只查底层工具的登记表，不碰磁盘。
# 用来发现"登记还在、文件已经没了"这种鬼状态——它会让底层工具报"同名实例已存在"。
proot_distro_registered() {
  local alias="$1"
  proot-distro list 2>/dev/null \
    | awk -v alias="$alias" '$1 == alias || $1 == alias ":" { found = 1 } END { exit !found }'
}

# 磁盘空间预检。
# 一张系统镜像解开要占几百兆，空间不够时后面会发生各种看不懂的失败。
check_free_space() {
  local need_mb="${1:-900}"
  local target="${2:-$PREFIX}"
  local avail
  avail="$(df -Pm "$target" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [[ "$avail" =~ ^[0-9]+$ ]] || return 0
  if [ "$avail" -lt "$need_mb" ]; then
    die "存储空间不够：这一步至少需要 ${need_mb} MB 可用，现在只剩 ${avail} MB。请先清理手机存储（相册、视频、其他应用缓存），再重新点一次部署"
  fi
  log "可用存储 ${avail} MB，够用"
}

# 装运行底座。这里是整个部署里最容易翻车的一步，所以做了五层兜底：
#   一、清磁盘残留、二、清底层工具的登记残留、三、空间预检、
#   四、尽量把镜像提前备到本地、五、失败自动重试一次并给出针对性指引。
install_proot_distro() {
  local distro="$1"
  local alias="$2"
  local label="$3"
  local root="$PROOT_ROOT/$alias"
  local cleaned=0

  # 动手之前，先把"代理只覆盖浏览器、终端没走"这个问题解决掉。
  # 这是手机上"浏览器能下载、终端连不上"的头号原因。
  ensure_proxy_for_downloads || true

  # 一、清磁盘残留（下载中断留下的空壳）
  if [ -d "$root" ] && [ ! -e "$root/rootfs/etc" ]; then
    warn "发现上次没装完的${label}残留，先清理再重装"
    rm -rf "$root" 2>/dev/null || true
    cleaned=1
  fi

  # 二、清底层工具里的登记残留。
  # 只删磁盘目录、不清登记的话，底层工具会报"同名实例已存在"，
  # 然后无论点多少次都装不上——这正是最容易让人崩溃的那种状态。
  if [ ! -e "$root/rootfs/etc" ] && proot_distro_registered "$alias"; then
    warn "底层工具里还登记着${label}，但文件已经不完整，先把这条登记注销"
    proot-distro remove "$alias" >/dev/null 2>&1 || true
    proot-distro reset "$alias" >/dev/null 2>&1 || true
    cleaned=1
  fi
  if [ "$cleaned" = "1" ]; then
    log "残留已清理干净"
  fi

  # 三、空间预检
  check_free_space 900 "$PREFIX"

  log "安装${label}运行底座"
  warn "这一步要从网上下载运行镜像，请保持屏幕常亮、网络稳定"

  # 四、尽量提前把镜像备到本地：缓存命中 / 从手机下载目录认领 / 多源续传。
  if prefetch_rootfs "$distro" "$label"; then
    log "镜像已备好，开始安装"
  else
    warn "没能提前备好镜像，交给安装器自己下载（它会重试多次）"
  fi

  # 五、安装，失败先清理再重试一次
  local attempt
  for attempt in 1 2; do
    if proot-distro install "$distro" --override-alias "$alias"; then
      ok "${label}运行底座安装完成"
      return 0
    fi
    if [ "$attempt" = "1" ]; then
      warn "第一次没装成，先清干净再重试一次"
      rm -rf "$root" 2>/dev/null || true
      proot-distro remove "$alias" >/dev/null 2>&1 || true
      proot-distro reset "$alias" >/dev/null 2>&1 || true
    fi
  done

  # 两次都失败：给出最具体的下一步
  local info url
  info="$(proot_distro_rootfs_info "$distro" 2>/dev/null || true)"
  url="$(printf '%s' "$info" | sed -n '1p')"
  if [ -n "$url" ]; then
    die "${label}运行底座没装成。救急办法：用手机浏览器打开下面这个地址下载（浏览器一般能走代理），下完不用移动文件，直接回来再点一次部署，程序会自动从手机的下载文件夹里把它捡起来：
$url"
  fi
  die "${label}运行底座没装成。这几乎都是网络问题，不是手机不兼容。判断依据：日志里出现「manifest」「layer」「image config」「Authenticating」「SSL」「connection abort」这类字样，就说明底层工具在向镜像仓库要镜像时被网络掐断了。请按顺序试：一、把 ZeroTermux 加进代理的分应用名单（很多代理默认只代理浏览器，终端其实没走代理）；二、改用手机流量；三、换个时间段再试。验证方法：用手机浏览器打开 github.com 和 registry-1.docker.io，浏览器能开而终端不行，就是代理没覆盖终端"
}

# 把系统里的软件源换成国内镜像。
# 官方源在国内经常慢到"看着像卡死"——尤其是几十兆的中文字体包。
# 换源之后同样的东西往往快十倍以上。
# 支持两种写法：老的 sources.list，和新的 sources.list.d 里的配置文件。
switch_apt_mirror() {
  local distro="$1"
  local alias="$2"
  local mirror="${ZBS_APT_MIRROR:-https://mirrors.tuna.tsinghua.edu.cn}"
  local script=""

  case "$distro" in
    debian)
      script="
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
                 /etc/apt/sources.list.d/*.sources; do
          [ -f \"\$f\" ] || continue
          sed -i \
            -e 's|http://deb.debian.org/debian|${mirror}/debian|g' \
            -e 's|http://deb.debian.org/debian-security|${mirror}/debian-security|g' \
            -e 's|http://security.debian.org|${mirror}/debian-security|g' \
            -e 's|https://deb.debian.org/debian|${mirror}/debian|g' \
            -e 's|https://deb.debian.org/debian-security|${mirror}/debian-security|g' \
            \"\$f\" 2>/dev/null || true
        done
      "
      ;;
    ubuntu)
      script="
        for f in /etc/apt/sources.list /etc/apt/sources.list.d/*.list \
                 /etc/apt/sources.list.d/*.sources; do
          [ -f \"\$f\" ] || continue
          sed -i \
            -e 's|http://archive.ubuntu.com/ubuntu|${mirror}/ubuntu|g' \
            -e 's|http://security.ubuntu.com/ubuntu|${mirror}/ubuntu|g' \
            -e 's|https://archive.ubuntu.com/ubuntu|${mirror}/ubuntu|g' \
            -e 's|https://security.ubuntu.com/ubuntu|${mirror}/ubuntu|g' \
            \"\$f\" 2>/dev/null || true
        done
      "
      ;;
    *)
      return 0
      ;;
  esac

  proot-distro login "$alias" -- /bin/bash -lc "$script" >/dev/null 2>&1 || true
}

ensure_ubuntu() {
  if proot_distro_alias_exists "$UBUNTU_ALIAS"; then
    log "Ubuntu proot 运行时已存在"
    switch_apt_mirror "ubuntu" "$UBUNTU_ALIAS"
    return 0
  fi
  install_proot_distro "ubuntu" "$UBUNTU_ALIAS" "Ubuntu"
  switch_apt_mirror "ubuntu" "$UBUNTU_ALIAS"
}

ensure_debian() {
  if proot_distro_alias_exists "$NAPCAT_ALIAS"; then
    log "Debian proot 运行时已存在"
    switch_apt_mirror "debian" "$NAPCAT_ALIAS"
    return 0
  fi
  install_proot_distro "debian" "$NAPCAT_ALIAS" "Debian"
  switch_apt_mirror "debian" "$NAPCAT_ALIAS"
}

proot_distro_alias_exists() {
  local alias="$1"
  local root="$PROOT_ROOT/$alias"
  # 只有真正解压出系统文件、或者真的能登进去，才算装好。
  # 绝不能只看底层工具的登记表：下载中断同样会留下登记，
  # 于是变成"看起来装着、一登录就崩、想重装又报同名已存在"的死循环。
  if [ -d "$root/rootfs" ] && [ -e "$root/rootfs/etc" ]; then
    return 0
  fi
  proot-distro login "$alias" -- /bin/true >/dev/null 2>&1 && return 0
  return 1
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

# 从手机下载目录里"认领"用户已经下好的同名文件。
# 原因：终端里的直连经常失败，但手机浏览器一般能走代理。
# 用户只要用浏览器把文件下载到下载目录，这里就自动搬过来，
# 不用手动移动、不用记路径、也不用额外敲命令。
adopt_downloaded_file() {
  local target="$1"
  local name
  name="$(basename "$target")"
  [ -s "$target" ] && return 0
  local candidate
  for candidate in \
    "$HOME/storage/downloads/$name" \
    "$HOME/storage/shared/Download/$name" \
    "$HOME/storage/shared/下载/$name" \
    "/storage/emulated/0/Download/$name" \
    "/storage/emulated/0/下载/$name"; do
    if [ -s "$candidate" ]; then
      mkdir -p "$(dirname "$target")" 2>/dev/null || true
      if cp -f "$candidate" "$target" 2>/dev/null; then
        log "从手机下载目录认领：$name"
        return 0
      fi
    fi
  done
  return 1
}

download_file() {
  local url="$1"
  local output="$2"
  local sha="${3:-}"
  local optional="${4:-0}"
  # 需要联网之前，先把"终端没走代理"这个问题处理掉
  ensure_proxy_for_downloads || true
  mkdir -p "$(dirname "$output")"
  # 下载之前先看看手机下载目录里有没有现成的同名文件
  adopt_downloaded_file "$output" || true
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
  # 先告诉用户要下多大，再静默下载——进度条会把日志刷爆
  announce_download_size "$url" " $(basename "$output")"
  if ! curl -fsSL --retry 3 --connect-timeout 20 "$url" -o "$output"; then
    rm -f "$output" 2>/dev/null || true
    warn "curl 下载失败，尝试使用 wget"
    if ! command -v wget >/dev/null 2>&1; then
      [ "$optional" = "1" ] && return 1
      die "下载失败：$(basename "$output")"
    fi
    if ! wget -q --tries=3 --timeout=20 -O "$output" "$url"; then
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
