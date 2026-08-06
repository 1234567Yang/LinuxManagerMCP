#!/bin/sh
# 安装 systemd unit,只安装不启动 / Install the systemd unit. Does not start it.
#
# 用法 / Usage: sudo sh add_service.sh
# 装完用 start.sh 起,用 uninstall_service.sh 卸。
# Start it with start.sh, remove it with uninstall_service.sh.
set -eu

SERVICE_NAME="linuxmanager-mcp"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"

say() { echo "$1"; echo "$2"; }
die() { echo "错误: $1" >&2; echo "Error: $2" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行" "Please run as root"
command -v systemctl >/dev/null 2>&1 \
    || die "找不到 systemctl,这台机器不是 systemd" \
           "systemctl not found; this host does not use systemd"

# ---------- 1. 定位仓库和解释器 / Locate the repo and the interpreter ----------
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -f "$REPO_DIR/server.py" ] || die "$REPO_DIR 下找不到 server.py" "server.py not found in $REPO_DIR"

# ExecStart 写绝对路径,systemd 不查 PATH,所以不需要 activate
# ExecStart uses an absolute path; systemd does not search PATH, so no activation is needed
if [ -x "$REPO_DIR/venv/bin/python" ]; then
    PYTHON="$REPO_DIR/venv/bin/python"
elif [ -x "$REPO_DIR/.venv/bin/python" ]; then
    PYTHON="$REPO_DIR/.venv/bin/python"
else
    PYTHON="$(command -v python3 || true)"
    [ -n "$PYTHON" ] || die "找不到 python3" "python3 not found"
    echo "警告: $REPO_DIR 下没有 venv,退回系统解释器 $PYTHON,依赖得装在系统 python 里" >&2
    echo "Warning: no venv in $REPO_DIR, falling back to $PYTHON; dependencies must be installed system-wide" >&2
fi

# ---------- 2. 起服务前的检查 / Pre-flight checks ----------
if [ ! -f "$REPO_DIR/.env" ] && [ ! -f "$REPO_DIR/.env_ignored" ]; then
    echo "警告: 没找到 .env / .env_ignored,启动时会因为 MCP_TOKEN 为空直接退出" >&2
    echo "Warning: no .env or .env_ignored found; the server will exit because MCP_TOKEN is empty" >&2
fi

RUN_AS_USER="$(sed -n 's/^MCP_RUN_AS_USER=//p' "$REPO_DIR/.env_ignored" "$REPO_DIR/.env" 2>/dev/null | head -n 1)"
[ -n "$RUN_AS_USER" ] || RUN_AS_USER="mcpagent"
if ! id "$RUN_AS_USER" >/dev/null 2>&1; then
    echo "警告: 降权用户 $RUN_AS_USER 不存在,启动时会 KeyError。先跑 create_agent_user.sh" >&2
    echo "Warning: unprivileged user $RUN_AS_USER does not exist; the server will raise KeyError. Run create_agent_user.sh first." >&2
fi

if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    say "提示: $SERVICE_NAME 正在运行,新的 unit 要重启才生效,跑一下 start.sh" \
        "Note: $SERVICE_NAME is running; the new unit takes effect after a restart, so run start.sh"
fi

# ---------- 3. 写 unit / Write the unit ----------
# 不设 User=,服务必须以 root 跑:降权和 sudo session 都要求 server 自己有 root 权限
# No User= here: the server must run as root, because both dropping privileges and
# sudo sessions require root in the first place.
cat > "$UNIT_PATH" <<EOF
[Unit]
Description=Linux Manager MCP Server
After=network-online.target
Wants=network-online.target

[Service]
Type=exec
WorkingDirectory=$REPO_DIR
ExecStart=$PYTHON $REPO_DIR/server.py

# 崩了不自动拉起。这玩意跑的是 LLM 发来的命令,反复重启只会掩盖真正的问题。
# No automatic restart. This runs commands sent by an LLM; restarting in a loop
# would only hide the real problem. Use Restart=on-failure if you want it.
Restart=no

[Install]
WantedBy=multi-user.target
EOF

chmod 0644 "$UNIT_PATH"
systemctl daemon-reload

# ---------- 4. 交代后续 / What to do next ----------
echo
say "===== 已安装 $UNIT_PATH =====" "===== Installed $UNIT_PATH ====="
say "  解释器:   $PYTHON"          "  Interpreter:      $PYTHON"
say "  工作目录: $REPO_DIR"        "  Working dir:      $REPO_DIR"
say "  崩溃重启: 否 (Restart=no)"  "  Restart on crash: no (Restart=no)"
say "  开机自启: 否"               "  Start on boot:    no"
echo
say "启动并跟日志: sudo sh start.sh"              "Start and follow logs: sudo sh start.sh"
say "卸载:         sudo sh uninstall_service.sh"  "Uninstall:             sudo sh uninstall_service.sh"
say "开机自启:     systemctl enable $SERVICE_NAME" "Enable on boot:        systemctl enable $SERVICE_NAME"
