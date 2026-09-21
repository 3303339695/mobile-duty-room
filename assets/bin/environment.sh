#!/data/data/com.termux/files/usr/bin/bash

run_environment() {
  if [ -s "$CONFIG_DIR/environment.json" ] && \
    command -v curl >/dev/null 2>&1 && \
    command -v wget >/dev/null 2>&1 && \
    command -v unzip >/dev/null 2>&1 && \
    command -v jq >/dev/null 2>&1 && \
    command -v python3 >/dev/null 2>&1 && \
    command -v proot-distro >/dev/null 2>&1 && \
    grep -qxF 'allow-external-apps=true' "$HOME/.termux/termux.properties" 2>/dev/null && \
    { [ -e "$HOME/storage/shared" ] || [ -d /storage/emulated/0 ]; }; then
    log "环境完整性校验通过"
    ok "终端环境已经完整，跳过重复初始化"
    return
  fi

  echo "============================================================"
  echo "手机端值班室 · 环境初始化"
  echo "============================================================"
  echo "架构: $(uname -m)"
  echo "Termux 前缀: $PREFIX"
  echo "可见组件目录: $HOME_ROOT"
  echo

  repair_termux_packages
  ensure_storage
  log "安装终端运行组件"
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    curl wget unzip zip tar jq python proot-distro git openssl-tool

  local props="$HOME/.termux/termux.properties"
  mkdir -p "$(dirname "$props")"
  touch "$props"
  if ! grep -qxF 'allow-external-apps=true' "$props" 2>/dev/null; then
    printf '\nallow-external-apps=true\n' >> "$props"
    ok "已启用 ZeroTermux 外部命令接口"
  else
    ok "ZeroTermux 外部命令接口已启用"
  fi
  command -v termux-reload-settings >/dev/null 2>&1 && termux-reload-settings || true

  printf '{"ready":true,"arch":"%s","prefix":"%s","home":"%s","updatedAt":"%s"}\n' \
    "$(uname -m)" "$PREFIX" "$HOME_ROOT" "$(date -Iseconds)" \
    > "$CONFIG_DIR/environment.json"

  echo
  ok "运行环境已就绪"
  warn "请返回“手机端值班室”，继续部署所需组件。"
}
