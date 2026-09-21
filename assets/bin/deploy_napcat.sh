#!/data/data/com.termux/files/usr/bin/bash

napcat_root() {
  printf '%s/runtime/napcat' "$HOME_ROOT"
}

napcat_pid_file() {
  printf '%s/config/napcat.pid' "$HOME_ROOT"
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
  [ -n "$version" ] && [ -n "$build" ] && [ "$build" -ge "$MIN_QQ_BUILD" ] 2>/dev/null
}

deploy_napcat() {
  local base
  base="$(napcat_root)"
  if napcat_runtime_complete; then
    local kernel_version
    kernel_version="$(qq_kernel_version)"
    log "NapCat 完整性校验通过：$NAPCAT_VERSION"
    log "Linux QQ 内核：$kernel_version · 构建 $(qq_kernel_build "$kernel_version") ≥ $MIN_QQ_BUILD，无需补内核"
    touch_runtime_state \
      "napcat" "$base" "$NAPCAT_VERSION" "qqKernel" "$kernel_version"
    link_runtime "$base" "napcat"
    TASK_RESULT_MESSAGE="QQ 内核 $kernel_version 已满足构建 $MIN_QQ_BUILD，无需补内核"
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
      libx11-xcb1 libxcb-dri3-0 libdrm2 fonts-noto-cjk
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

  local qq_url qq_urls=() qq_ready=0
  if qq_kernel_supported; then
    log "复用已经准备好的 Linux QQ 运行内核"
    qq_ready=1
  else
    if [ -s "$base/opt/QQ/qq" ]; then
      warn "现有 Linux QQ 内核 $(qq_kernel_version) 低于最低构建 $MIN_QQ_BUILD，停止复用"
    fi
    rm -rf "$base"
    mkdir -p "$base"
    log "优先从 NapCat 官方 ARM64 镜像准备 Linux QQ 运行内核"
    if debian_shell "
      set -e
      python3 /opt/zhibanshi/bin/fetch_napcat_qq_docker.py \
        --tag 'v${NAPCAT_VERSION}' \
        --output '/opt/zhibanshi/runtime/napcat' \
        --cache '/opt/zhibanshi/downloads'
    " && qq_kernel_supported; then
      qq_ready=1
    else
      warn "官方镜像暂不可用，改用腾讯官方 Linux QQ arm64 安装包"
    fi
  fi

  if [ "$qq_ready" -ne 1 ]; then
    rm -rf "$base"
    mkdir -p "$base"
    while IFS= read -r candidate; do
      [ -n "$candidate" ] && qq_urls+=("$candidate")
    done < <(debian_shell \
      'python3 /opt/zhibanshi/bin/resolve_linux_qq.py' \
      2>/dev/null || true)
    if [ "${#qq_urls[@]}" -eq 0 ]; then
      qq_urls+=(
        "https://qqdl.gtimg.cn/qqfile/QQNT/9.9.31/release/00e6a3e7/QQ_3.2.29_260528_arm64_01.deb"
        "https://dldir1v6.qq.com/qqfile/qq/QQNT/a5fab4ff/linuxqq_3.2.18-36580_arm64.deb"
        "https://dldir1v6.qq.com/qqfile/qq/QQNT/Linux/QQ_3.2.18_250626_arm64_01.deb"
      )
    fi
    for qq_url in "${qq_urls[@]}"; do
      log "Linux QQ 包：$qq_url"
      if ! download_file "$qq_url" "$DOWNLOAD_DIR/linuxqq-arm64.deb" "" 1; then
        continue
      fi
      if ! debian_shell \
        'dpkg-deb --info /opt/zhibanshi/downloads/linuxqq-arm64.deb >/dev/null 2>&1'; then
        warn "下载内容不是有效的 Linux QQ arm64 安装包，继续尝试备用地址"
        rm -f "$DOWNLOAD_DIR/linuxqq-arm64.deb" 2>/dev/null || true
        continue
      fi
      log "解压 Linux QQ 安装包"
      if debian_shell "
        set -e
        rm -rf '/opt/zhibanshi/runtime/napcat'
        mkdir -p '/opt/zhibanshi/runtime/napcat'
        dpkg-deb -x '/opt/zhibanshi/downloads/linuxqq-arm64.deb' \
          '/opt/zhibanshi/runtime/napcat'
      " && qq_kernel_supported; then
        qq_ready=1
        break
      fi
      warn "该安装包内核 $(qq_kernel_version) 低于最低构建 $MIN_QQ_BUILD，继续尝试备用地址"
      rm -rf "$base"
      mkdir -p "$base"
      rm -f "$DOWNLOAD_DIR/linuxqq-arm64.deb" 2>/dev/null || true
    done
  fi
  [ "$qq_ready" -eq 1 ] || \
    die "Linux QQ 运行内核不可用或版本低于构建 $MIN_QQ_BUILD，请检查网络后重试部署"

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
    jq '.main = \"./loadNapCat.js\"' \
      '/opt/zhibanshi/runtime/napcat/opt/QQ/resources/app/package.json' \
      > /tmp/qq-package.json
    mv /tmp/qq-package.json \
      '/opt/zhibanshi/runtime/napcat/opt/QQ/resources/app/package.json'
    rm -rf '/opt/zhibanshi/runtime/napcat/napcat-shell'
  " || die "NapCat 文件注入失败"

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
  echo $$ > "$pid_file"
  exec proot-distro login "$NAPCAT_ALIAS" \
    --bind "$HOME_ROOT:/opt/zhibanshi" \
    -- /bin/bash -lc "exec /opt/zhibanshi/bin/start_napcat_inner.sh"
}

stop_napcat() {
  local pid_file
  pid_file="$(napcat_pid_file)"
  log "停止 NapCat"
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
    "$DOWNLOAD_DIR"/napcat-qq-*.tar.gz 2>/dev/null || true
  ok "NapCat 运行目录、登录态和 WebUI 配置已删除"
  warn "重新点击“部署/更新”会安装 v$NAPCAT_VERSION"
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
