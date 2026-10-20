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

# 守护服务的心跳必须先处理掉，而且不能走下面的加锁流程。
# 它每隔一阵就来一次，如果也去抢那把任务锁，
# 用户点任何按钮都会跟它抢，表现就是"提交任务后卡死大半天、什么都点不动"。
# 心跳的职责只有一件：确认守护进程还活着，顺手拉起来就走，不留痕迹。
if [ "$ACTION" = "start-watchdog" ]; then
  ensure_watchdog >/dev/null 2>&1 || true
  exit 0
fi

# 抢任务锁：同一时间只允许一个任务在跑。
# 两个任务同时去装软件包会把对方打断，留下"配置未完成"的半截状态，
# 之后所有安装都会被挡住，所以宁可拒绝第二个任务。
#
# 但"停止"和"清理"这两个动作必须能强行接管：
# 万一某个服务进程把锁攥死了，界面上连停止都点不动，
# 用户就彻底没有退路了，只能重启整个终端。
# 留下这条救火通道，局面永远能收回来。
case "$ACTION" in
  cleanup|stop-all) acquire_task_lock "$ACTION" 1 ;;
  *) acquire_task_lock "$ACTION" ;;
esac
trap 'release_task_lock' EXIT
task_status_running "任务已开始"

# 任务日志直接追加到当天文件，不经任何中间进程。
# 之前用 `exec > >(bash log_daily.sh ...)` 会把整个任务脚本的 stdout 接到一根管道上，
# 管道填满或消费者退出会连带拖死脚本，原因详见 common.sh 中 ensure_watchdog 的注释。
exec >> "$(log_file app)" 2>&1
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
    # 停止服务只需要基础命令，不要调用 ensure_termux_tools：
    # 那个函数在缺少命令时会触发软件包升级，和正在进行的初始化任务撞车，
    # 会把安装过程打断成"配置未完成"的半截状态。
    source "$SCRIPT_DIR/astrbot_instance.sh"
    stop_all_astrbot || true
    source "$SCRIPT_DIR/deploy_napcat.sh"
    stop_napcat || true
    source "$SCRIPT_DIR/deploy_minilm.sh"
    stop_minilm || true
    ok "所有后台服务已停止"
    ;;
  cleanup)
    # 同上：清理缓存是轻量操作，绝不能在这里触发软件包升级。
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
