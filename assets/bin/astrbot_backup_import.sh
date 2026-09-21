#!/data/data/com.termux/files/usr/bin/bash

import_backup() {
  local request="$1"
  local id name port username password backup_path backup_name dir destination
  id="$(json_value "$request" id)"
  name="$(json_value "$request" name "$id")"
  port="$(json_value "$request" port)"
  username="$(json_value "$request" username "astrbot")"
  password="$(json_value "$request" password "$(json_value "$request" token "")")"
  backup_path="$(json_value "$request" backupPath)"
  backup_name="$(json_value "$request" backupName "$(basename "$backup_path")")"
  validate_instance_id "$id"
  [ -f "$backup_path" ] || die "备份包不存在：$backup_path"
  [ -n "$username" ] || die "实例后台用户名为空"
  [ -n "$password" ] || die "实例后台密码为空"
  backup_name="$(basename "$backup_name")"
  [ -n "$backup_name" ] || die "备份文件名无效"

  dir="$(instance_dir "$id")"
  destination="$dir/data/backups/$backup_name"
  mkdir -p "$(dirname "$destination")"

  echo "============================================================"
  echo "AstrBot 可见导入流程"
  echo "实例: $name"
  echo "端口: $port"
  echo "来源: $backup_path"
  echo "目标: $destination"
  echo "============================================================"

  local source_size target_free required_free
  source_size="$(stat -c '%s' "$backup_path" 2>/dev/null || echo 0)"
  target_free="$(df -Pk "$HOME_ROOT" 2>/dev/null | awk 'NR==2 {print $4 * 1024}')"
  [[ "$target_free" =~ ^[0-9]+$ ]] || target_free=0
  required_free=$((source_size + 64 * 1024 * 1024))
  warn "备份包大小：$(numfmt --to=iec-i --suffix=B "$source_size" 2>/dev/null || echo "$source_size bytes")"
  warn "实例剩余空间：$(numfmt --to=iec-i --suffix=B "$target_free" 2>/dev/null || echo "$target_free bytes")"
  [ "$target_free" -gt "$required_free" ] || \
    die "实例所在空间不足，至少需要 $(numfmt --to=iec-i --suffix=B "$required_free" 2>/dev/null || echo "$required_free bytes")"

  log "开始复制。保持本会话前台，进度会持续显示"
  dd if="$backup_path" of="$destination" bs=4M status=progress conv=fsync \
    || die "备份包复制失败"
  sync
  local copied_size
  copied_size="$(stat -c '%s' "$destination")"
  [ "$copied_size" = "$source_size" ] || die "复制后文件大小不一致"
  ok "备份包已完整复制到实例目录"

  log "等待 AstrBot 后台就绪"
  local ready=0
  for _ in $(seq 1 300); do
    if curl -fsS --max-time 2 "http://127.0.0.1:$port/api/stat/versions" >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 1
  done
  [ "$ready" -eq 1 ] || die "AstrBot 未在 5 分钟内就绪，请先确认实例正在独立会话中运行"

  log "调用 AstrBot 官方预检查、导入和进度接口"
  ASTRBOT_VERSION="$ASTRBOT_VERSION" \
    python3 "$PUBLIC_ROOT/bin/import_astrbot.py" \
    "http://127.0.0.1:$port" "$username" "$password" "$backup_name" \
    || die "导入未完成，实例保持运行，便于检查日志"

  ok "导入接口确认 success=true，准备停止实例"
  source "$PUBLIC_ROOT/bin/astrbot_instance.sh"
  stop_instance "$request"
  printf '{"instance":"%s","backup":"%s","completedAt":"%s","stopped":true}\n' \
    "$id" "$backup_name" "$(date -Iseconds)" > "$CONFIG_DIR/last-import.json"
  ok "导入完成且实例已停止。请人工核验后手动重启。"
}
