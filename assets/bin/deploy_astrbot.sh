#!/data/data/com.termux/files/usr/bin/bash

deploy_astrbot() {
  local installed
  installed="$(ubuntu_shell '
    /root/astrbot-venv/bin/python - <<"PY"
import astrbot
print(astrbot.__version__)
PY
  ' 2>/dev/null | tr -d "\r" | tail -n 1 || true)"
  if [ "$installed" = "$ASTRBOT_VERSION" ]; then
    log "AstrBot 底座完整性校验通过：$installed"
    printf '%s\n' "$installed" > "$CONFIG_DIR/astrbot.version"
    touch_runtime_state "astrbot" "/root/astrbot-venv" "$installed"
    ok "已有完整 AstrBot 运行底座，跳过重复部署"
    return
  fi

  ensure_ubuntu

  echo "============================================================"
  echo "部署 AstrBot v$ASTRBOT_VERSION"
  echo "运行位置: Ubuntu proot · /root/astrbot-venv"
  echo "实例位置: $HOME_ROOT/instances"
  echo "============================================================"

  log "安装 Ubuntu 侧系统依赖"
  ubuntu_shell '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y python3 python3-venv python3-pip curl ca-certificates \
      git unzip jq ffmpeg build-essential libffi-dev libssl-dev libsqlite3-dev \
      libjpeg-dev zlib1g-dev libxml2-dev libxslt1-dev
  ' || die "Ubuntu 依赖安装失败"

  log "创建 AstrBot 独立 Python 环境"
  ubuntu_shell '
    set -e
    PYTHON_BIN="$(command -v python3)" || {
      echo "Ubuntu 中没有可用的 python3"
      exit 1
    }
    "$PYTHON_BIN" - <<"PY"
import sys
if sys.version_info < (3, 12):
    raise SystemExit("AstrBot 需要 Python 3.12 或更高版本")
print("Python", sys.version.split()[0])
PY
    if [ ! -x /root/astrbot-venv/bin/python ] || \
      ! /root/astrbot-venv/bin/python - <<"PY"
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
    then
      echo "重建 AstrBot Python 环境"
      rm -rf /root/astrbot-venv
      "$PYTHON_BIN" -m venv /root/astrbot-venv
    fi
    /root/astrbot-venv/bin/python -m pip install --upgrade pip setuptools wheel
  ' || die "Python 虚拟环境创建失败"

  log "安装固定版本 AstrBot $ASTRBOT_VERSION"
  ubuntu_shell "
    set -e
    PIP=/root/astrbot-venv/bin/pip
    \"\$PIP\" install --prefer-binary \
      -i https://pypi.tuna.tsinghua.edu.cn/simple \
      \"astrbot==$ASTRBOT_VERSION\" || \
    \"\$PIP\" install --prefer-binary --index-url https://pypi.org/simple \
      \"astrbot==$ASTRBOT_VERSION\"
  " || die "AstrBot 安装失败"

  installed="$(ubuntu_shell '
    /root/astrbot-venv/bin/python - <<"PY"
import astrbot
print(astrbot.__version__)
PY
  ' | tr -d "\r" | tail -n 1)"
  [ "$installed" = "$ASTRBOT_VERSION" ] || \
    die "AstrBot 版本校验失败，期望 $ASTRBOT_VERSION，实际 $installed"

  printf '%s\n' "$installed" > "$CONFIG_DIR/astrbot.version"
  touch_runtime_state "astrbot" "/root/astrbot-venv" "$installed"
  ok "AstrBot $installed 运行底座部署完成"
  warn "下一步到“实例”页创建实例，再启动对应会话。"
}

uninstall_astrbot() {
  log "卸载 AstrBot 运行底座"
  stop_all_astrbot || true

  if proot_distro_alias_exists "$UBUNTU_ALIAS"; then
    ubuntu_shell "
      if command -v pkill >/dev/null 2>&1; then
        pkill -TERM -f '/root/astrbot-[v]env' 2>/dev/null || true
        sleep 1
        pkill -KILL -f '/root/astrbot-[v]env' 2>/dev/null || true
      fi
      rm -rf /root/astrbot-venv
    " || die "AstrBot 运行底座卸载失败"
  fi

  rm -f "$CONFIG_DIR/astrbot.version" \
    "$CONFIG_DIR/astrbot-runtime.json" 2>/dev/null || true
  ok "AstrBot 运行底座已卸载，实例数据、账密、端口和备份均保留"
  warn "重新点击“部署/更新底座”可安装 v$ASTRBOT_VERSION"
}
