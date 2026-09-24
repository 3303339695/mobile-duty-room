#!/data/data/com.termux/files/usr/bin/bash

cache_size_kb() {
  local total=0 path size
  for path in \
    "$DOWNLOAD_DIR" \
    "$HOME/.cache/pip" \
    "$HOME/.cache/huggingface" \
    "$HOME/.cache/torch" \
    "$PREFIX/var/cache/apt/archives" \
    "$PROOT_ROOT/$UBUNTU_ALIAS/root/.cache" \
    "$PROOT_ROOT/$NAPCAT_ALIAS/root/.cache"; do
    [ -e "$path" ] || continue
    size="$(du -sk "$path" 2>/dev/null | awk 'NR == 1 {print $1}')"
    [[ "$size" =~ ^[0-9]+$ ]] || size=0
    total=$((total + size))
  done
  printf '%s' "$total"
}

cleanup_stale_processes() {
  log "清理漏停的服务进程"
  pkill -TERM -f '/opt/zhibanshi/instances/' 2>/dev/null || true
  pkill -TERM -f '/opt/zhibanshi/bin/minilm_server.py' 2>/dev/null || true
  pkill -TERM -f '/opt/zhibanshi/runtime/napcat' 2>/dev/null || true
  pkill -TERM -f 'xvfb-run.*/opt/zhibanshi/runtime/napcat' 2>/dev/null || true
  sleep 1
  pkill -KILL -f '/opt/zhibanshi/instances/' 2>/dev/null || true
  pkill -KILL -f '/opt/zhibanshi/bin/minilm_server.py' 2>/dev/null || true
  pkill -KILL -f '/opt/zhibanshi/runtime/napcat' 2>/dev/null || true
  pkill -KILL -f 'xvfb-run.*/opt/zhibanshi/runtime/napcat' 2>/dev/null || true
  rm -f "$HOME_ROOT"/instances/*/run.pid 2>/dev/null || true
  rm -f "$HOME_ROOT"/runtime/*.pid 2>/dev/null || true
}

cleanup_download_residue() {
  log "清理下载残片与安装包缓存"
  find "$HOME_ROOT" -type f \
    \( -name '*.part' -o -name '*.partial' -o -name '*.tmp' \
       -o -name '*.download' -o -name '*.crdownload' \) \
    -delete 2>/dev/null || true
  rm -f "$DOWNLOAD_DIR"/linuxqq-arm64.deb 2>/dev/null || true
  rm -f "$DOWNLOAD_DIR"/NapCat.Shell.v*.zip 2>/dev/null || true
  rm -f "$DOWNLOAD_DIR"/QQ-*_NapCat-*-arm64.AppImage 2>/dev/null || true
  rm -f "$DOWNLOAD_DIR"/napcat-qq-*.tar.gz 2>/dev/null || true
  rm -rf "$HOME_ROOT/tmp" 2>/dev/null || true
  mkdir -p "$HOME_ROOT/tmp"
}

cleanup_package_caches() {
  log "清理 apt、pip 和模型下载缓存"
  apt-get clean >/dev/null 2>&1 || true
  rm -f "$PREFIX"/var/cache/apt/archives/*.deb 2>/dev/null || true
  rm -rf "$HOME/.cache/pip" "$HOME/.cache/huggingface" "$HOME/.cache/torch" \
    2>/dev/null || true

  if proot_distro_alias_exists "$UBUNTU_ALIAS"; then
    ubuntu_shell "
      apt-get clean >/dev/null 2>&1 || true
      rm -rf /root/.cache/pip /root/.cache/huggingface /root/.cache/torch
      find /tmp -maxdepth 1 -type f \
        \( -name '*.tmp' -o -name '*.part' -o -name 'qq-package.json' \) \
        -delete 2>/dev/null || true
    " >/dev/null 2>&1 || true
  fi

  if proot_distro_alias_exists "$NAPCAT_ALIAS"; then
    debian_shell "
      apt-get clean >/dev/null 2>&1 || true
      rm -rf /root/.cache/pip /root/.cache/huggingface /root/.cache/torch
      find /tmp -maxdepth 1 -type f \
        \( -name '*.tmp' -o -name '*.part' -o -name 'qq-package.json' \) \
        -delete 2>/dev/null || true
    " >/dev/null 2>&1 || true
  fi
}

cleanup_runtime() {
  local before after freed
  before="$(cache_size_kb)"
  cleanup_stale_processes
  cleanup_download_residue
  cleanup_package_caches
  after="$(cache_size_kb)"
  freed=$((before - after))
  [ "$freed" -gt 0 ] || freed=0
  ok "残留进程与缓存清理完成，释放约 $((freed / 1024)) MB"
  warn "实例目录、账密、端口配置、备份和已保存模型均未删除"
}
