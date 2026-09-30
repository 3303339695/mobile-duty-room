#!/data/data/com.termux/files/usr/bin/bash

minilm_dir() {
  printf '%s/models/%s' "$HOME_ROOT" "$MINILM_MODEL"
}

minilm_pid_file() {
  printf '%s/config/minilm.pid' "$HOME_ROOT"
}

deploy_minilm() {
  ensure_ubuntu
  local model_dir
  model_dir="$(minilm_dir)"

  local existing
  existing="$(ubuntu_shell '
    /root/minilm-venv/bin/python - <<"PY"
import sentence_transformers
print("ready")
PY
  ' 2>/dev/null | tr -d "\r" | tail -n 1 || true)"
  if [ "$existing" = "ready" ] && \
    [ -f "$model_dir/config.json" ] && \
    { [ -f "$model_dir/model.safetensors" ] || [ -f "$model_dir/pytorch_model.bin" ]; } && \
    [ -f "$HOME_ROOT/bin/minilm_server.py" ]; then
    log "MiniLM 完整性校验通过"
    printf '%s\n' "$MINILM_MODEL" > "$CONFIG_DIR/minilm.version"
    touch_runtime_state "minilm" "$model_dir" "$MINILM_MODEL"
    link_runtime "$model_dir" "minilm-model"
    ok "已有完整 MiniLM 服务与模型，跳过重复部署"
    return
  fi

  echo "============================================================"
  echo "部署 $MINILM_MODEL"
  echo "模型位置: $model_dir"
  echo "服务地址: http://127.0.0.1:8000/v1"
  echo "============================================================"

  log "安装 MiniLM Python 依赖"
  ubuntu_shell '
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y python3 python3-venv python3-pip python3-dev \
      build-essential ca-certificates curl
    PYTHON_BIN="$(command -v python3)" || {
      echo "Ubuntu 中没有可用的 python3"
      exit 1
    }
    if [ ! -x /root/minilm-venv/bin/python ] || \
      ! /root/minilm-venv/bin/python - <<"PY"
import sys
raise SystemExit(0 if sys.version_info >= (3, 12) else 1)
PY
    then
      echo "重建 MiniLM Python 环境"
      rm -rf /root/minilm-venv
      "$PYTHON_BIN" -m venv /root/minilm-venv
    fi
    /root/minilm-venv/bin/python -m pip install --upgrade pip setuptools wheel
    if ! /root/minilm-venv/bin/pip install --prefer-binary \
      --index-url https://download.pytorch.org/whl/cpu torch==2.14.0; then
      [ "$(uname -m)" = "aarch64" ] || {
        echo "PyTorch CPU 安装失败，当前架构不是 aarch64"
        exit 1
      }
      PY_TAG="$(/root/minilm-venv/bin/python -c \
        "import sys; print(f\"cp{sys.version_info.major}{sys.version_info.minor}\")")"
      /root/minilm-venv/bin/pip install --prefer-binary \
        "https://mirrors.aliyun.com/pytorch-wheels/cpu/torch-2.14.0%2Bcpu-${PY_TAG}-${PY_TAG}-manylinux_2_28_aarch64.whl"
    fi
    /root/minilm-venv/bin/pip install --prefer-binary \
      -i https://pypi.tuna.tsinghua.edu.cn/simple \
      sentence-transformers==6.1.0 || \
    /root/minilm-venv/bin/pip install --prefer-binary \
      --index-url https://pypi.org/simple sentence-transformers==6.1.0
  ' || die "MiniLM 依赖安装失败"

  log "下载模型并保存为离线目录"
  if ! ubuntu_shell "
      set -e
      mkdir -p '/opt/zhibanshi/models/$MINILM_MODEL'
      /root/minilm-venv/bin/python - <<'PY'
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2')
model.save('/opt/zhibanshi/models/paraphrase-multilingual-MiniLM-L12-v2', safe_serialization=True)
print('model saved')
PY
    "; then
    warn "模型主站下载失败，改用 Hugging Face 镜像重试"
    ubuntu_shell "
      export HF_ENDPOINT='https://hf-mirror.com'
      set -e
      mkdir -p '/opt/zhibanshi/models/$MINILM_MODEL'
      /root/minilm-venv/bin/python - <<'PY'
from sentence_transformers import SentenceTransformer
model = SentenceTransformer('sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2')
model.save('/opt/zhibanshi/models/paraphrase-multilingual-MiniLM-L12-v2', safe_serialization=True)
print('model saved')
PY
    " || die "模型下载或转换失败"
  fi

  [ -f "$model_dir/config.json" ] || die "模型目录不完整"
  { [ -f "$model_dir/model.safetensors" ] || [ -f "$model_dir/pytorch_model.bin" ]; } || \
    die "模型权重文件不完整"
  printf '%s\n' "$MINILM_MODEL" > "$CONFIG_DIR/minilm.version"
  touch_runtime_state "minilm" "$model_dir" "$MINILM_MODEL"
  link_runtime "$model_dir" "minilm-model"
  ok "MiniLM 模型与离线服务代码已部署"
  warn "启动后，AstrBot 使用 http://127.0.0.1:8000/v1 和密钥 local-minilm。"
}

start_minilm() {
  local pid_file model_dir
  pid_file="$(minilm_pid_file)"
  model_dir="$(minilm_dir)"
  [ -f "$model_dir/config.json" ] || die "MiniLM 模型尚未部署"
  ubuntu_shell '[ -x /root/minilm-venv/bin/python ]' >/dev/null 2>&1 || \
    die "MiniLM Python 环境尚未部署"
  if pid_running "$pid_file" || is_port_open 8000; then
    warn "MiniLM 服务已经在运行"
    sleep 2
    return
  fi
  echo "============================================================"
  echo "启动 MiniLM 本地向量服务"
  echo "模型: $model_dir"
  echo "接口: http://127.0.0.1:8000/v1"
  echo "离线模式: HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1"
  echo "============================================================"
  mkdir -p "$HOME_ROOT/logs"
  ensure_watchdog
  touch "$HOME_ROOT/config/desired-minilm"
  echo $$ > "$pid_file"
  exec proot-distro login "$UBUNTU_ALIAS" \
    --bind "$HOME_ROOT:/opt/zhibanshi" \
    --bind "$PUBLIC_ROOT:/opt/zhibanshi-public" \
    -- /bin/bash -lc "
      export TZ=Asia/Shanghai
      export HF_HUB_OFFLINE=1
      export TRANSFORMERS_OFFLINE=1
      export PYTHONUNBUFFERED=1
      exec /root/minilm-venv/bin/python /opt/zhibanshi/bin/minilm_server.py \
        --model '/opt/zhibanshi/models/$MINILM_MODEL' \
        --host 127.0.0.1 --port 8000 --api-key local-minilm
    " > >(bash "$PUBLIC_ROOT/bin/log_daily.sh" "$PUBLIC_ROOT" minilm quiet) 2>&1
}

stop_minilm() {
  local pid_file
  pid_file="$(minilm_pid_file)"
  log "停止 MiniLM 服务"
  rm -f "$HOME_ROOT/config/desired-minilm" 2>/dev/null || true
  stop_pid_file "$pid_file" '/opt/zhibanshi/bin/minilm_server.py'
  if is_port_open 8000; then
    warn "MiniLM 端口 8000 仍在监听"
  else
    ok "MiniLM 已停止"
  fi
}
