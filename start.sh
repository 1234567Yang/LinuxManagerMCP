#!/bin/sh
# 重启服务并跟着看日志 / Restart the service and follow its logs.
# 先 stop,再 start,然后 journalctl -f。
#
# 用法 / Usage: sudo sh start.sh
# 需要先跑过 add_service.sh。Ctrl+C 只是退出看日志,服务照常在后台跑。
# Run add_service.sh first. Ctrl+C only stops following the logs; the service keeps running.
set -eu

SERVICE_NAME="linuxmanager-mcp"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

say() { echo "$1"; echo "$2"; }
die() { echo "错误: $1" >&2; echo "Error: $2" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行" "Please run as root"
command -v systemctl >/dev/null 2>&1 \
    || die "找不到 systemctl,这台机器不是 systemd" \
           "systemctl not found; this host does not use systemd"
[ -f "$UNIT_PATH" ] \
    || die "$UNIT_PATH 不存在,先跑: sudo sh add_service.sh" \
           "$UNIT_PATH does not exist. Run this first: sudo sh add_service.sh"

# 无条件 stop:已经停了的话 systemctl 也返回 0,所以改完代码直接跑这个脚本就行
# Unconditional stop: systemctl returns 0 even if it was not running, so this script
# can be run after any code change without checking the current state first.
say "停止 $SERVICE_NAME ..." "Stopping $SERVICE_NAME ..."
systemctl stop "$SERVICE_NAME"

# 上次异常退出会留下 failed 状态,清掉,免得 status 里一直挂着旧错误
# A previous crash leaves the unit in a failed state; clear it so status shows the current run
systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

say "启动 $SERVICE_NAME ..." "Starting $SERVICE_NAME ..."
if ! systemctl start "$SERVICE_NAME"; then
    echo >&2
    echo "启动失败。最后 50 行日志:" >&2
    echo "Failed to start. Last 50 log lines:" >&2
    journalctl -u "$SERVICE_NAME" -n 50 --no-pager >&2
    exit 1
fi

systemctl --no-pager --lines=0 status "$SERVICE_NAME" || true

echo
say "===== 跟随日志 (Ctrl+C 退出,服务继续在后台跑) =====" \
    "===== Following logs (Ctrl+C to stop watching; the service keeps running) ====="
# -n 50 先把刚才启动那几行带出来,不然 -f 要等到下一条新日志才有东西看
# -n 50 shows the lines from the start we just did; a bare -f would wait for new output
journalctl -u "$SERVICE_NAME" -n 50 -f
