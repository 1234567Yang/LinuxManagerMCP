#!/bin/sh
# 卸载 systemd unit / Remove the systemd unit.
# 停服务、取消开机自启、删 unit 文件 / stop, disable, delete the unit file.
#
# 用法 / Usage: sudo sh uninstall_service.sh
# 只动 systemd,不删仓库、不删 .env_ignored、不删降权账号。
# Only touches systemd. The repo, .env_ignored and the unprivileged account are left alone.
set -eu

SERVICE_NAME="linuxmanager-mcp"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

say() { echo "$1"; echo "$2"; }
die() { echo "错误: $1" >&2; echo "Error: $2" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行" "Please run as root"
command -v systemctl >/dev/null 2>&1 \
    || die "找不到 systemctl,这台机器不是 systemd" \
           "systemctl not found; this host does not use systemd"

if [ ! -f "$UNIT_PATH" ]; then
    say "$UNIT_PATH 不存在,没什么可卸的。" "$UNIT_PATH does not exist, nothing to remove."
    exit 0
fi

# 下面每一步都容错:服务可能本来就没跑、本来就没 enable,那都不算错
# Every step below tolerates failure: not running and not enabled are both fine
say "停止 $SERVICE_NAME ..." "Stopping $SERVICE_NAME ..."
systemctl stop "$SERVICE_NAME" 2>/dev/null || true

say "取消开机自启 ..." "Disabling start on boot ..."
systemctl disable "$SERVICE_NAME" 2>/dev/null || true

systemctl reset-failed "$SERVICE_NAME" 2>/dev/null || true

say "删除 $UNIT_PATH ..." "Removing $UNIT_PATH ..."
rm -f "$UNIT_PATH"
systemctl daemon-reload

echo
say "===== 已卸载 =====" "===== Uninstalled ====="
say "仓库、.env_ignored、降权账号都还在,要清干净得自己动手:" \
    "The repo, .env_ignored and the unprivileged account are still there. To remove them:"
echo "  userdel -r <MCP_RUN_AS_USER>"
echo
say "历史日志也还在,要删:" "Past logs are kept too. To drop them:"
echo "  journalctl --vacuum-time=1s --unit=$SERVICE_NAME"
