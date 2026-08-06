#!/bin/sh
# 安装 systemd service。装完不会自动启动,也不设开机自启,都要你手动来。
#
# 用法: 



# sudo sh add_service.sh
# sudo systemctl start linuxmanager-mcp
# sudo journalctl -u linuxmanager-mcp -f




set -eu

SERVICE_NAME="linuxmanager-mcp"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

die() { echo "错误: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
command -v systemctl >/dev/null 2>&1 || die "找不到 systemctl,这台机器不是 systemd"

# ---------- 1. 定位仓库和解释器 ----------
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$REPO_DIR/server.py" ] || die "$REPO_DIR 下找不到 server.py"

# 优先用 venv 里的解释器。ExecStart 写绝对路径,systemd 不查 PATH,
# 所以不需要 activate,也不会有 sudo 重置 PATH 那类问题。
if [ -x "$REPO_DIR/venv/bin/python" ]; then
    PYTHON="$REPO_DIR/venv/bin/python"
elif [ -x "$REPO_DIR/.venv/bin/python" ]; then
    PYTHON="$REPO_DIR/.venv/bin/python"
else
    PYTHON="$(command -v python3 || true)"
    [ -n "$PYTHON" ] || die "找不到 python3"
    echo "警告: $REPO_DIR 下没有 venv,退回系统解释器 $PYTHON" >&2
    echo "      依赖得装在系统 python 里才行,否则起不来" >&2
fi

# ---------- 2. 起服务前的检查 ----------
if [ ! -f "$REPO_DIR/.env" ] && [ ! -f "$REPO_DIR/.env_ignored" ]; then
    echo "警告: 没找到 .env / .env_ignored,启动时会因为 MCP_TOKEN 为空直接退出" >&2
fi

RUN_AS_USER="$(sed -n 's/^MCP_RUN_AS_USER=//p' "$REPO_DIR/.env_ignored" "$REPO_DIR/.env" 2>/dev/null | head -n 1)"
[ -n "$RUN_AS_USER" ] || RUN_AS_USER="mcpagent"
if ! id "$RUN_AS_USER" >/dev/null 2>&1; then
    echo "警告: 降权用户 $RUN_AS_USER 不存在,启动时会 KeyError。先跑 create_agent_user.sh" >&2
fi

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    echo "提示: $SERVICE_NAME 正在运行,新的 unit 要 systemctl restart 才生效"
fi

# ---------- 3. 写 unit ----------
# 不设 User=,服务必须以 root 跑:降权到 MCP_RUN_AS_USER 和 sudo session
# 这两个功能都要求 server 自己有 root 权限。
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Linux Manager MCP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
WorkingDirectory=$REPO_DIR
ExecStart=$PYTHON $REPO_DIR/server.py

# 崩了不自动拉起。这玩意跑的是 LLM 发来的命令,反复重启只会掩盖真正的问题,
# 而且残留的 shell 子进程会越堆越多。要自动重启就改成 Restart=on-failure。
Restart=no

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$UNIT_PATH"
systemctl daemon-reload

# ---------- 4. 交代后续 ----------
echo
echo "===== 已安装 $UNIT_PATH ====="
echo "  解释器:  $PYTHON"
echo "  工作目录: $REPO_DIR"
echo "  崩溃重启: 否 (Restart=no)"
echo "  开机自启: 否"
echo
echo "启动:     systemctl start   $SERVICE_NAME"
echo "状态:     systemctl status  $SERVICE_NAME"
echo "日志:     journalctl -u $SERVICE_NAME -f"
echo "停止:     systemctl stop    $SERVICE_NAME"
echo "重启:     systemctl restart $SERVICE_NAME"
echo
echo "要开机自启再单独执行: systemctl enable $SERVICE_NAME"
