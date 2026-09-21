#!/data/data/com.termux/files/usr/bin/bash

instance_dir() {
  local id="$1"
  printf '%s/instances/%s' "$HOME_ROOT" "$id"
}

validate_instance_id() {
  local id="$1"
  [[ "$id" =~ ^bot-[a-z0-9]+(-[0-9]+)?$ ]] || die "实例 ID 无效"
}

create_instance() {
  local request="$1"
  local id name port dir
  id="$(json_value "$request" id)"
  name="$(json_value "$request" name)"
  port="$(json_value "$request" port "0")"
  validate_instance_id "$id"
  [ -n "$name" ] || die "实例名称不能为空"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || \
    port=0
  ubuntu_shell '[ -x /root/astrbot-venv/bin/astrbot ]' >/dev/null 2>&1 || \
    die "请先部署 AstrBot 运行底座"
  if [ "$port" -ne 0 ] && is_port_open "$port"; then
    die "端口 $port 已被占用"
  fi

  dir="$(instance_dir "$id")"
  mkdir -p "$dir/data"
  printf '{"id":"%s","name":"%s","port":%s,"createdAt":"%s"}\n' \
    "$id" "$(json_escape "$name")" "$port" "$(date -Iseconds)" > "$dir/instance.json"

  log "创建 AstrBot 实例：$name"
  ubuntu_shell "
    set -e
    cd '/opt/zhibanshi/instances/$id'
    export ASTRBOT_ROOT='/opt/zhibanshi/instances/$id'
    if [ ! -f data/cmd_config.json ]; then
      /root/astrbot-venv/bin/astrbot init -y
    fi
    /root/astrbot-venv/bin/python \
      /opt/zhibanshi/bin/patch_astrbot_config.py \
      /opt/zhibanshi/instances/$id/data/cmd_config.json
  " || die "实例初始化失败"

  touch_runtime_state "$id" "$dir" "v$ASTRBOT_VERSION"
  ok "实例“$name”已创建"
  warn "请点实例配置，填写后台用户名、密码和端口。首次启动前可以先不填账密。"
}

start_instance() {
  local request="$1"
  local id name port dir pid_file username password username_b64 password_b64 credentials
  id="$(json_value "$request" id)"
  name="$(json_value "$request" name "$id")"
  port="$(json_value "$request" port)"
  username="$(json_value "$request" username "astrbot")"
  password="$(json_value "$request" password "$(json_value "$request" token "")")"
  validate_instance_id "$id"
  [[ "$port" =~ ^[0-9]+$ ]] && [ "$port" -ge 1024 ] && [ "$port" -le 65535 ] || \
    die "请先在实例配置中填写有效端口"
  dir="$(instance_dir "$id")"
  pid_file="$dir/run.pid"
  [ -d "$dir" ] || die "实例目录不存在"
  ubuntu_shell '[ -x /root/astrbot-venv/bin/astrbot ]' >/dev/null 2>&1 || \
    die "AstrBot 运行底座尚未部署"

  if pid_running "$pid_file" || is_port_open "$port"; then
    warn "实例“$name”已经在运行，端口 $port"
    sleep 2
    return
  fi

  echo "============================================================"
  echo "启动 AstrBot 实例：$name"
  echo "端口: $port"
  echo "实例目录: $dir"
  echo "============================================================"
  credentials=""
  if [ -n "$password" ]; then
    [ -n "$username" ] || die "实例后台用户名不能为空"
    username_b64="$(printf '%s' "$username" | base64 | tr -d '\r\n')"
    password_b64="$(printf '%s' "$password" | base64 | tr -d '\r\n')"
    credentials="--username-b64 '$username_b64' --password-b64 '$password_b64'"
    log "将使用实例配置中记录的账密自动填充"
  else
    warn "实例配置尚未记录密码，本次保持 AstrBot 当前账密不变"
  fi
  echo $$ > "$pid_file"
  exec proot-distro login "$UBUNTU_ALIAS" \
    --bind "$HOME_ROOT:/opt/zhibanshi" \
    -- /bin/bash -lc "
      cd '/opt/zhibanshi/instances/$id'
      export ASTRBOT_ROOT='/opt/zhibanshi/instances/$id'
      /root/astrbot-venv/bin/python \
        /opt/zhibanshi/bin/patch_astrbot_config.py \
        /opt/zhibanshi/instances/$id/data/cmd_config.json $credentials
      export ASTRBOT_CLI=1
      exec /root/astrbot-venv/bin/astrbot run --port '$port'
    "
}

stop_instance() {
  local request="$1"
  local id name port dir pid_file
  id="$(json_value "$request" id)"
  name="$(json_value "$request" name "$id")"
  port="$(json_value "$request" port)"
  validate_instance_id "$id"
  dir="$(instance_dir "$id")"
  pid_file="$dir/run.pid"
  log "停止 AstrBot 实例：$name"
  stop_pid_file "$pid_file" "/opt/zhibanshi/instances/$id"
  if is_port_open "$port"; then
    warn "端口 $port 仍在监听，请稍后刷新状态"
  else
    ok "实例“$name”已停止"
  fi
}

stop_all_astrbot() {
  local pid_file id dir
  for pid_file in "$HOME_ROOT"/instances/*/run.pid; do
    [ -e "$pid_file" ] || continue
    dir="$(dirname "$pid_file")"
    id="$(basename "$dir")"
    log "停止 AstrBot 实例：$id"
    stop_pid_file "$pid_file" "/opt/zhibanshi/instances/$id"
  done
}
