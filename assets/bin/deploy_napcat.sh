#!/data/data/com.termux/files/usr/bin/bash

napcat_root() {
  printf '%s/runtime/napcat' "$HOME_ROOT"
}

napcat_pid_file() {
  printf '%s/config/napcat.pid' "$HOME_ROOT"
}

napcat_config_file() {
  printf '%s/opt/QQ/resources/app/app_launcher/napcat/config/napcat.json' "$(napcat_root)"
}

ensure_napcat_o3_hook() {
  local config
  config="$(napcat_config_file)"
  [ -d "$(dirname "$config")" ] || return 0
  python3 "$HOME_ROOT/bin/configure_napcat_o3.py" --config "$config" >/dev/null
}

napcat_runtime_complete() {
  local base
  base="$(napcat_root)"
  [ -s "$base/opt/QQ/qq" ] && \
    [ -s "$base/opt/QQ/resources/app/loadNapCat.js" ] && \
    [ -s "$base/opt/QQ/resources/app/app_launcher/napcat/napcat.mjs" ] && \
    grep -q 'loadNapCat.js' "$base/opt/QQ/resources/app/package.json" && \
    qq_kernel_supported && \
    [ "$(cat "$CONFIG_DIR/napcat.version" 2>/dev/null || true)" = "$NAPCAT_VERSION" ]
}

qq_kernel_version() {
  local package_json
  package_json="$(napcat_root)/opt/QQ/resources/app/package.json"
  [ -s "$package_json" ] || return 0
  sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$package_json" | head -n 1 | tr -d '\r'
}

qq_kernel_build() {
  local version="$1"
  printf '%s' "$version" | sed -n 's/.*-\([0-9][0-9]*\).*/\1/p'
}

qq_kernel_supported() {
  local version build
  version="$(qq_kernel_version)"
  build="$(qq_kernel_build "$version")"
  [ "$version" = "$REQUIRED_QQ_VERSION" ] && \
    [ "$build" = "$REQUIRED_QQ_BUILD" ] 2>/dev/null
}

deploy_napcat() {
  local base
  base="$(napcat_root)"
  ensure_napcat_o3_hook || die "NapCat o3HookMode 配置写入失败"
  if napcat_runtime_complete; then
    local kernel_version
    kernel_version="$(qq_kernel_version)"
    log "NapCat 完整性校验通过：$NAPCAT_VERSION"
    log "Linux QQ 内核：$kernel_version · 与 NapCat $NAPCAT_VERSION 精确匹配，无需补内核"
    touch_runtime_state \
      "napcat" "$base" "$NAPCAT_VERSION" "qqKernel" "$kernel_version"
    link_runtime "$base" "napcat"
    TASK_RESULT_MESSAGE="QQ 内核 $kernel_version 已匹配 NapCat $NAPCAT_VERSION，无需补内核"
    ok "已有完整 NapCat 环境，跳过重复部署"
    return
  fi

  ensure_debian

  echo "============================================================"
  echo "部署 NapCat QQ v$NAPCAT_VERSION"
  echo "运行位置: Debian proot · $HOME_ROOT/runtime/napcat"
  echo "WebUI: http://127.0.0.1:6099"
  echo "============================================================"

  log "安装 Debian 侧依赖"
  debian_shell '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl unzip jq python3 xvfb dbus-x11 \
      libasound2 libgbm1 libnss3 libxss1 libxshmfence1 libgtk-3-0 \
      libx11-xcb1 libxcb-dri3-0 libdrm2 fonts-noto-cjk squashfs-tools
    apt-get install -y libxtst6 xdg-utils libatspi2.0-0 libsecret-1-0 \
      libnotify4 || true
    apt-get install -y libappindicator3-1 \
      || apt-get install -y libayatana-appindicator3-1 \
      || true
  ' || die "NapCat 系统依赖安装失败"

  local napcat_archive
  napcat_archive="$DOWNLOAD_DIR/NapCat.Shell.v${NAPCAT_VERSION}.zip"
  download_file \
    "https://github.com/NapNeko/NapCatQQ/releases/download/v${NAPCAT_VERSION}/NapCat.Shell.zip" \
    "$napcat_archive" \
    "$NAPCAT_SHA256"
  [ -s "$napcat_archive" ] || die "NapCat Shell 安装包尚未就绪"

  local qq_archive qq_ready=0
  if [ -s "$base/opt/QQ/qq" ]; then
    warn "当前运行组合不完整或不是目标版本，删除旧内核后重新准备 $REQUIRED_QQ_VERSION"
  fi
  rm -rf "$base"
  mkdir -p "$base/opt"
  qq_archive="$DOWNLOAD_DIR/QQ-${REQUIRED_QQ_BUILD}_NapCat-v4.18.13-arm64.AppImage"
  download_file \
    "$NAPCAT_QQ_APPIMAGE_URL" \
    "$qq_archive" \
    "$NAPCAT_QQ_APPIMAGE_SHA256"
  [ -s "$qq_archive" ] || die "Linux QQ AppImage 尚未就绪"

  log "从官方 ARM64 AppImage 提取 Linux QQ $REQUIRED_QQ_VERSION"
  if debian_shell "
    set -e
    python3 /opt/zhibanshi/bin/extract_appimage_qq.py \
      --archive '/opt/zhibanshi/downloads/$(basename "$qq_archive")' \
      --output '/opt/zhibanshi/runtime/napcat/opt/QQ' \
      --expected-version '${REQUIRED_QQ_VERSION}'
  " && qq_kernel_supported; then
    qq_ready=1
  fi
  [ "$qq_ready" -eq 1 ] || \
    die "Linux QQ 运行内核不是要求的 $REQUIRED_QQ_VERSION，已停止部署"

  debian_shell \
    "test -s '/opt/zhibanshi/downloads/$(basename "$napcat_archive")'" || \
    die "NapCat Shell 安装包没有进入 Debian 下载目录"
  log "注入 NapCat Shell"
  debian_shell "
    set -e
    mkdir -p '/opt/zhibanshi/runtime/napcat/napcat-shell'
    unzip -q -o '/opt/zhibanshi/downloads/NapCat.Shell.v${NAPCAT_VERSION}.zip' \
      -d '/opt/zhibanshi/runtime/napcat/napcat-shell'
    target='/opt/zhibanshi/runtime/napcat/opt/QQ/resources/app/app_launcher'
    mkdir -p \"\$target/napcat\"
    cp -a '/opt/zhibanshi/runtime/napcat/napcat-shell/.' \"\$target/napcat/\"
    chmod -R +x \"\$target/napcat\"
    printf '%s\n' \"(async () => {await import('file:///opt/zhibanshi/runtime/napcat/opt/QQ/resources/app/app_launcher/napcat/napcat.mjs');})();\" \
      > '/opt/zhibanshi/runtime/napcat/opt/QQ/resources/app/loadNapCat.js'
    python3 /opt/zhibanshi/bin/patch_napcat_reply.py \
      '/opt/zhibanshi/runtime/napcat/opt/QQ/resources/app/app_launcher/napcat/napcat.mjs'
    jq '.main = \"./loadNapCat.js\"' \
      '/opt/zhibanshi/runtime/napcat/opt/QQ/resources/app/package.json' \
      > /tmp/qq-package.json
    mv /tmp/qq-package.json \
      '/opt/zhibanshi/runtime/napcat/opt/QQ/resources/app/package.json'
    rm -rf '/opt/zhibanshi/runtime/napcat/napcat-shell'
  " || die "NapCat 文件注入失败"

  ensure_napcat_o3_hook || die "NapCat o3HookMode 配置写入失败"
  printf '%s\n' "$NAPCAT_VERSION" > "$CONFIG_DIR/napcat.version"
  touch_runtime_state \
    "napcat" "$base" "$NAPCAT_VERSION" "qqKernel" "$(qq_kernel_version)"
  link_runtime "$base" "napcat"
  TASK_RESULT_MESSAGE="NapCat 与 QQ 内核 $(qq_kernel_version) 已就绪"
  ok "NapCat $NAPCAT_VERSION 部署完成"
  warn "首次启动后可在 WebUI 完成 QQ 登录，WebUI Token 可通过首页“读取密钥”查看。"
}

start_napcat() {
  local pid_file qq_bin
  qq_bin="$(napcat_root)/opt/QQ/qq"
  pid_file="$(napcat_pid_file)"
  [ -f "$qq_bin" ] || die "NapCat 尚未部署"
  ensure_napcat_o3_hook || die "NapCat o3HookMode 配置写入失败"
  if pid_running "$pid_file" || is_port_open 6099; then
    warn "NapCat 已经在运行"
    sleep 2
    return
  fi
  echo "============================================================"
  echo "启动 NapCat QQ v$NAPCAT_VERSION"
  echo "NapCat 目录: $(napcat_root)"
  echo "WebUI: http://127.0.0.1:6099"
  echo "============================================================"
  mkdir -p "$HOME_ROOT/logs"
  ensure_watchdog
  printf '%s\n' "$(wc -c < "$PUBLIC_ROOT/logs/napcat.log" 2>/dev/null || printf '0')" \
    > "$HOME_ROOT/config/watchdog-napcat.log.offset"
  touch "$HOME_ROOT/config/desired-napcat"
  echo $$ > "$pid_file"
  exec proot-distro login "$NAPCAT_ALIAS" \
    --bind "$HOME_ROOT:/opt/zhibanshi" \
    --bind "$PUBLIC_ROOT:/opt/zhibanshi-public" \
    -- /bin/bash -lc "export TZ=Asia/Shanghai; exec /opt/zhibanshi/bin/start_napcat_inner.sh" \
    >> "$PUBLIC_ROOT/logs/napcat.log" 2>&1
}

stop_napcat() {
  local pid_file
  pid_file="$(napcat_pid_file)"
  log "停止 NapCat"
  rm -f "$HOME_ROOT/config/desired-napcat" 2>/dev/null || true
  stop_pid_file "$pid_file" '/opt/zhibanshi/runtime/napcat/opt/QQ/qq'
  pkill -TERM -f 'xvfb-run.*/opt/zhibanshi/runtime/napcat' 2>/dev/null || true
  if is_port_open 6099; then
    warn "NapCat 端口 6099 仍在监听"
  else
    ok "NapCat 已停止"
  fi
}

uninstall_napcat() {
  local base
  base="$(napcat_root)"
  [ -n "$base" ] && [ "$base" != "$HOME_ROOT" ] || die "NapCat 运行目录无效"

  log "卸载 NapCat 已部署版本"
  stop_napcat || true
  pkill -TERM -f 'xvfb-run.*/opt/zhibanshi/runtime/[n]apcat' 2>/dev/null || true
  pkill -KILL -f 'xvfb-run.*/opt/zhibanshi/runtime/[n]apcat' 2>/dev/null || true
  rm -rf "$base"
  rm -f "$PUBLIC_ROOT/runtime-napcat" \
    "$CONFIG_DIR/napcat.version" \
    "$CONFIG_DIR/napcat-runtime.json" \
    "$CONFIG_DIR/napcat-webui.json" \
    "$CONFIG_DIR/napcat-reverse-ws.json" \
    "$HOME_ROOT/config/napcat-reverse-ws-state.json" 2>/dev/null || true
  rm -f "$DOWNLOAD_DIR"/NapCat.Shell.v*.zip \
    "$DOWNLOAD_DIR"/QQ-*_NapCat-*-arm64.AppImage \
    "$DOWNLOAD_DIR"/linuxqq-arm64.deb \
    "$DOWNLOAD_DIR"/napcat-qq-*.tar.gz 2>/dev/null || true
  ok "NapCat 运行目录、登录态和 WebUI 配置已删除"
  warn "重新点击“部署/更新”会安装 v$NAPCAT_VERSION"
}

uninstall_napcat_kernel() {
  local base
  base="$(napcat_root)"
  [ -n "$base" ] && [ "$base" != "$HOME_ROOT" ] || die "NapCat 运行目录无效"

  log "卸载 Linux QQ 内核"
  stop_napcat || true
  pkill -TERM -f 'xvfb-run.*/opt/zhibanshi/runtime/[n]apcat' 2>/dev/null || true
  pkill -KILL -f 'xvfb-run.*/opt/zhibanshi/runtime/[n]apcat' 2>/dev/null || true
  rm -rf "$base/opt/QQ"
  rm -f "$PUBLIC_ROOT/runtime-napcat" \
    "$CONFIG_DIR/napcat.version" \
    "$CONFIG_DIR/napcat-runtime.json" \
    "$CONFIG_DIR/napcat-webui.json" \
    "$CONFIG_DIR/napcat-reverse-ws.json" \
    "$HOME_ROOT/config/napcat-reverse-ws-state.json" 2>/dev/null || true
  ok "Linux QQ 内核、登录态、WebUI 密钥和连接配置已删除"
  warn "NapCat 下载包已保留；点击“重装内核”会安装 $REQUIRED_QQ_VERSION"
}

reinstall_napcat_kernel() {
  log "重装 Linux QQ 内核 $REQUIRED_QQ_VERSION"
  uninstall_napcat_kernel
  deploy_napcat
}

show_napcat_token() {
  local webui_path
  webui_path="$(napcat_root)/opt/QQ/resources/app/app_launcher/napcat/config/webui.json"
  [ -f "$webui_path" ] || \
    die "尚未生成 WebUI 配置，请先启动 NapCat 一次"
  cp -f "$webui_path" "$CONFIG_DIR/napcat-webui.json"
  ok "NapCat WebUI 配置已读取，可在应用内查看并复制"
}

configure_napcat_ws() {
  local request="$1"
  local name url token message_format report_self_message
  local heart_interval reconnect_interval debug enable
  local name_b64 url_b64 token_b64 message_format_b64
  name="$(json_value "$request" name "值班室-AstrBot")"
  url="$(json_value "$request" url "ws://127.0.0.1:6199/ws")"
  token="$(json_value "$request" token "")"
  message_format="$(json_value "$request" messagePostFormat "array")"
  report_self_message="$(json_value "$request" reportSelfMessage "false")"
  heart_interval="$(json_value "$request" heartInterval "30000")"
  reconnect_interval="$(json_value "$request" reconnectInterval "5000")"
  debug="$(json_value "$request" debug "true")"
  enable="$(json_value "$request" enable "true")"

  case "$url" in
    ws://*|wss://*) ;;
    *) die "连接地址必须以 ws:// 或 wss:// 开头" ;;
  esac
  [[ "$heart_interval" =~ ^[0-9]+$ ]] || heart_interval=30000
  [[ "$reconnect_interval" =~ ^[0-9]+$ ]] || reconnect_interval=5000
  case "$report_self_message" in true|1|yes|on) report_self_message=1 ;; *) report_self_message=0 ;; esac
  case "$debug" in true|1|yes|on) debug=1 ;; *) debug=0 ;; esac
  case "$enable" in true|1|yes|on) enable=1 ;; *) enable=0 ;; esac
  case "$message_format" in array|string) ;; *) message_format=array ;; esac

  name_b64="$(printf '%s' "$name" | base64 | tr -d '\r\n')"
  url_b64="$(printf '%s' "$url" | base64 | tr -d '\r\n')"
  token_b64="$(printf '%s' "$token" | base64 | tr -d '\r\n')"
  message_format_b64="$(printf '%s' "$message_format" | base64 | tr -d '\r\n')"

  log "停止 NapCat 后写入反向 WebSocket 配置"
  stop_napcat || true
  debian_shell "
    python3 /opt/zhibanshi/bin/configure_napcat_ws.py \
      --root '/opt/zhibanshi/runtime/napcat' \
      --state '/opt/zhibanshi/config/napcat-reverse-ws-state.json' \
      --name-b64 '$name_b64' \
      --url-b64 '$url_b64' \
      --token-b64 '$token_b64' \
      --message-format-b64 '$message_format_b64' \
      --report-self-message '$report_self_message' \
      --heart-interval '$heart_interval' \
      --reconnect-interval '$reconnect_interval' \
      --debug '$debug' \
      --enable '$enable'
  " || die "NapCat 反向 WebSocket 配置写入失败"
  cp -f "$HOME_ROOT/config/napcat-reverse-ws-state.json" \
    "$CONFIG_DIR/napcat-reverse-ws.json"
  ok "NapCat 反向 WebSocket 配置已写入"
  warn "请重新启动 NapCat 使配置生效"
}
