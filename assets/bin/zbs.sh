#!/data/data/com.termux/files/usr/bin/bash

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

ACTION="${1:-}"
REQUEST="${2:-}"
[ -n "$ACTION" ] || die "缺少任务类型"

sync_runtime_bundle

if [ -n "$REQUEST" ] && [ -f "$REQUEST" ]; then
  TASK_STATUS_FILE="$CONFIG_DIR/status/$(basename "$REQUEST").json"
else
  TASK_STATUS_FILE="$CONFIG_DIR/status/${ACTION}-$(date +%Y%m%d-%H%M%S).json"
fi
export TASK_STATUS_FILE
task_status_running "任务已开始"

exec > >(bash "$SCRIPT_DIR/log_daily.sh" "$PUBLIC_ROOT" app stdout) 2>&1
log "任务：$ACTION"
log "组件目录：$HOME_ROOT"

case "$ACTION" in
  probe)
    echo "============================================================"
    echo "ZeroTermux 外部命令调用测试"
    echo "============================================================"
    echo "如果能看到本行，说明外部命令调用已经成功。"
    echo "终端用户: $(whoami 2>/dev/null || echo unknown)"
    echo "工作目录: $(pwd)"
    ok "终端调用测试通过"
    ;;
  bootstrap)
    source "$SCRIPT_DIR/environment.sh"
    run_environment
    ;;
  deploy-astrbot)
    ensure_termux_tools
    ensure_storage
    source "$SCRIPT_DIR/deploy_astrbot.sh"
    deploy_astrbot
    ;;
  create-astrbot)
    ensure_termux_tools
    require_request "$REQUEST" >/dev/null
    source "$SCRIPT_DIR/astrbot_instance.sh"
    create_instance "$REQUEST"
    ;;
  start-astrbot)
    ensure_termux_tools
    require_request "$REQUEST" >/dev/null
    source "$SCRIPT_DIR/astrbot_instance.sh"
    task_status_launched "AstrBot 实例会话已启动"
    start_instance "$REQUEST"
    ;;
  stop-astrbot)
    ensure_termux_tools
    require_request "$REQUEST" >/dev/null
    source "$SCRIPT_DIR/astrbot_instance.sh"
    stop_instance "$REQUEST"
    ;;
  import-astrbot)
    ensure_termux_tools
    require_request "$REQUEST" >/dev/null
    source "$SCRIPT_DIR/astrbot_instance.sh"
    source "$SCRIPT_DIR/astrbot_backup_import.sh"
    import_backup "$REQUEST"
    ;;
  deploy-napcat)
    ensure_termux_tools
    ensure_storage
    source "$SCRIPT_DIR/deploy_napcat.sh"
    deploy_napcat
    ;;
  uninstall-napcat)
    ensure_termux_tools
    source "$SCRIPT_DIR/deploy_napcat.sh"
    uninstall_napcat
    ;;
  uninstall-napcat-kernel)
    ensure_termux_tools
    source "$SCRIPT_DIR/deploy_napcat.sh"
    uninstall_napcat_kernel
    ;;
  reinstall-napcat-kernel)
    ensure_termux_tools
    ensure_storage
    source "$SCRIPT_DIR/deploy_napcat.sh"
    reinstall_napcat_kernel
    ;;
  start-napcat)
    ensure_termux_tools
    source "$SCRIPT_DIR/deploy_napcat.sh"
    task_status_launched "NapCat 会话已启动"
    start_napcat
    ;;
  stop-napcat)
    ensure_termux_tools
    source "$SCRIPT_DIR/deploy_napcat.sh"
    stop_napcat
    ;;
  napcat-token)
    ensure_termux_tools
    source "$SCRIPT_DIR/deploy_napcat.sh"
    show_napcat_token
    ;;
  configure-napcat-ws)
    ensure_termux_tools
    require_request "$REQUEST" >/dev/null
    source "$SCRIPT_DIR/deploy_napcat.sh"
    configure_napcat_ws "$REQUEST"
    ;;
  uninstall-astrbot)
    ensure_termux_tools
    source "$SCRIPT_DIR/astrbot_instance.sh"
    source "$SCRIPT_DIR/deploy_astrbot.sh"
    uninstall_astrbot
    ;;
  deploy-minilm)
    ensure_termux_tools
    ensure_storage
    source "$SCRIPT_DIR/deploy_minilm.sh"
    deploy_minilm
    ;;
  start-minilm)
    ensure_termux_tools
    source "$SCRIPT_DIR/deploy_minilm.sh"
    task_status_launched "MiniLM 会话已启动"
    start_minilm
    ;;
  start-watchdog)
    ensure_watchdog
    task_status_launched "后台服务守护已启动"
    ;;
  stop-minilm)
    ensure_termux_tools
    source "$SCRIPT_DIR/deploy_minilm.sh"
    stop_minilm
    ;;
  minilm-config)
    cat <<EOF
MiniLM 本地服务参数
ID: local_minilm_embedding
API Key: local-minilm
API Base URL: http://127.0.0.1:8000/v1
嵌入模型: paraphrase-multilingual-MiniLM-L12-v2
嵌入维度: 384
嵌入维度参数发送模式: always
超时时间: 60
代理地址: 留空
模型目录: $HOME_ROOT/models/$MINILM_MODEL
EOF
    ;;
  stop-all)
    ensure_termux_tools
    source "$SCRIPT_DIR/astrbot_instance.sh"
    stop_all_astrbot || true
    source "$SCRIPT_DIR/deploy_napcat.sh"
    stop_napcat || true
    source "$SCRIPT_DIR/deploy_minilm.sh"
    stop_minilm || true
    ok "所有后台服务已停止"
    ;;
  cleanup)
    ensure_termux_tools
    source "$SCRIPT_DIR/astrbot_instance.sh"
    stop_all_astrbot || true
    source "$SCRIPT_DIR/deploy_napcat.sh"
    stop_napcat || true
    source "$SCRIPT_DIR/deploy_minilm.sh"
    stop_minilm || true
    source "$SCRIPT_DIR/cleanup.sh"
    cleanup_runtime
    ;;
  *)
    die "未知任务：$ACTION"
    ;;
esac

task_status_success "${TASK_RESULT_MESSAGE:-${ACTION} 已完成}"
ok "任务结束：$ACTION"
