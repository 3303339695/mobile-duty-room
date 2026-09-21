#!/bin/bash

set -uo pipefail

cd /opt/zhibanshi/runtime/napcat/opt/QQ
mkdir -p /run/dbus /tmp/.X11-unix

if [ ! -S /run/dbus/system_bus_socket ]; then
  dbus-daemon --system --fork --nopidfile >/dev/null 2>&1 || true
fi
export DBUS_SYSTEM_BUS_ADDRESS="unix:path=/run/dbus/system_bus_socket"

runner=()
if command -v dbus-run-session >/dev/null 2>&1; then
  runner=(dbus-run-session --)
fi

exec "${runner[@]}" xvfb-run -a ./qq --no-sandbox 2> >(
  grep -Ev 'ERROR:(dbus/|object_proxy\.cc|device/udev_linux/)' >&2
)
