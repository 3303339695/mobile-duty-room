#!/usr/bin/env bash
# 验证"自动发现本机代理端口"的三条行为：
#   一、没有代理端口时，不碰任何环境变量
#   二、发现端口且验证能连通时，让终端流量走代理
#   三、发现端口但验证连不通时，立刻撤销，避免把原本正常的网络搞坏
# 用法：bash tools/test_proxy_autodetect.sh
set -uo pipefail

base="$(cd "$(dirname "$0")/.." && pwd)"
root="$(mktemp -d)"
trap 'rm -rf "$root"' EXIT

export HOME="$root/home"
export PREFIX="$root/prefix"
export ZBS_HOME_ROOT="$root/home/手机端值班室"
mkdir -p "$HOME" "$PREFIX" "$ZBS_HOME_ROOT" "$root/public/bin"
cp "$base/assets/bin/common.sh" "$root/public/bin/common.sh"

# shellcheck source=/dev/null
source "$root/public/bin/common.sh"

fail() { printf '失败：%s\n' "$1" >&2; exit 1; }

# 便于控制：用变量模拟"哪个端口开着"，用变量模拟"联网是否成功"
proxy_port=""
net_ok=1

is_port_open() {
  [ -n "$proxy_port" ] && [ "$1" = "$proxy_port" ]
}
network_reachable() {
  [ "$net_ok" = "1" ]
}

reset_env() {
  unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY 2>/dev/null || true
  ZBS_PROXY_READY=0
}

# 一、没有代理端口：不该碰环境变量
reset_env
proxy_port=""
net_ok=1
ensure_proxy_for_downloads >/dev/null 2>&1 || true
[ -z "${https_proxy:-}" ] || fail "没有代理端口却设置了代理：$https_proxy"
printf '通过：没有代理端口时不改动任何环境变量\n'

# 二、有端口且能连通：应当让终端走代理
reset_env
proxy_port="7890"
net_ok=1
ensure_proxy_for_downloads >/dev/null 2>&1 || fail "有可用代理时却返回失败"
[ "${https_proxy:-}" = "http://127.0.0.1:7890" ] \
  || fail "没有把终端指向本机代理，实际：${https_proxy:-空}"
[ "${http_proxy:-}" = "http://127.0.0.1:7890" ] \
  || fail "普通请求的代理没有设置"
printf '通过：发现可用代理后，终端流量走代理（%s）\n' "$https_proxy"

# 三、有端口但连不通：必须撤销，不能把网络弄坏
reset_env
proxy_port="7890"
net_ok=0
ensure_proxy_for_downloads >/dev/null 2>&1 || true
[ -z "${https_proxy:-}" ] || fail "代理连不通却还保留着设置：$https_proxy"
printf '通过：代理连不通时自动撤销，不会破坏原本的网络\n'

# 四、用户自己设过代理：不要覆盖
reset_env
export https_proxy="http://10.0.0.1:7890"
proxy_port="7890"
net_ok=1
ensure_proxy_for_downloads >/dev/null 2>&1 || true
[ "$https_proxy" = "http://10.0.0.1:7890" ] \
  || fail "把用户自己设置的代理覆盖掉了：$https_proxy"
printf '通过：用户自己设定的代理会被尊重，不会被覆盖\n'

printf '\n代理自动发现验收：全部通过\n'
