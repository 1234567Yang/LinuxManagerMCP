#!/bin/sh
# 一键安装 / One-shot installer.
# 建降权账号 -> 建 venv 装依赖 -> 写配置 -> 装 systemd unit。
# Create the unprivileged account, set up the venv, write the config, install the systemd unit.
#
# 用法 / Usage: sudo sh install.sh
#
# 装完不会自动启动,最后会告诉你怎么起。每一步都可以重复执行,已经做过的会跳过。
# It does not start the service; the last section tells you how. Safe to re-run.
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_LOCAL="$REPO_DIR/.env_ignored"
DEFAULT_USER="mcpagent"
DEFAULT_PORT="1949"

say() { echo "$1"; echo "$2"; }
die() { echo "错误: $1" >&2; echo "Error: $2" >&2; exit 1; }
step() { echo; echo "=============================================="; say "$1" "$2"; echo "=============================================="; }

# 按 server.py 的优先级读配置:.env_ignored 盖过 .env
# Same precedence as server.py: .env_ignored wins over .env
read_conf() {
    for _f in "$ENV_LOCAL" "$REPO_DIR/.env"; do
        [ -f "$_f" ] || continue
        _v="$(sed -n "s/^$1=//p" "$_f" | head -n 1)"
        if [ -n "$_v" ]; then
            echo "$_v"
            return 0
        fi
    done
}

# 写配置项,先删掉同名旧行,避免一个 key 在文件里出现两次
# Write a setting, dropping any previous line for the same key first
set_conf() {
    [ -f "$ENV_LOCAL" ] && sed -i "/^$1=/d" "$ENV_LOCAL"
    printf '%s=%s\n' "$1" "$2" >> "$ENV_LOCAL"
}

ask_yes_no() {
    echo
    echo "$1"
    echo "$2"
    printf '  [y/N]: '
    read -r _answer
    case "$_answer" in
        [yY] | [yY][eE][sS]) return 0 ;;
        *) say "已取消,什么都没有改动。" "Cancelled. Nothing was changed."; exit 1 ;;
    esac
}

[ "$(id -u)" -eq 0 ] || die "请用 root 运行: sudo sh install.sh" "Please run as root: sudo sh install.sh"
[ -t 0 ] || die "这个脚本要交互回答问题,请在终端里直接运行" \
                "This script asks questions, so run it directly in a terminal"
command -v systemctl >/dev/null 2>&1 \
    || die "找不到 systemctl,这台机器不是 systemd" \
           "systemctl not found; this host does not use systemd"
[ -f "$REPO_DIR/server.py" ] || die "$REPO_DIR 下找不到 server.py" "server.py not found in $REPO_DIR"

RUN_AS_USER="$(read_conf MCP_RUN_AS_USER)"
[ -n "$RUN_AS_USER" ] || RUN_AS_USER="$DEFAULT_USER"
BIND_PORT="$(read_conf MCP_BIND_PORT)"
[ -n "$BIND_PORT" ] || BIND_PORT="$DEFAULT_PORT"


# ==============================================================
#  安装前的三个问题 / Three questions before installing
# ==============================================================
say "===== Linux Manager MCP 安装程序 =====" "===== Linux Manager MCP installer ====="
say "开始之前有三个问题。" "Three questions before we begin."

# ---- 问题 1 / Question 1 ----
ask_yes_no \
"[1/3] 安装过程会在本机创建一个新的普通用户 \"$RUN_AS_USER\"。
      大模型发来的命令会以这个身份运行,而不是 root,这样它动不了系统文件。
      这个账号没有 sudo 权限,也不能用密码登录。是否继续?" \
"[1/3] The installer will create a new unprivileged user \"$RUN_AS_USER\" on this machine.
      Commands sent by the model run as this user instead of root, so they cannot touch
      system files. The account has no sudo rights and cannot log in with a password.
      Continue?"

# ---- 问题 2 / Question 2 ----
ask_yes_no \
"[2/3] 这个服务只监听本机的 127.0.0.1:$BIND_PORT,不会直接暴露到公网。
      要从外面连上它,你需要自己装好 Cloudflare Tunnel,并把它指向
          http://localhost:$BIND_PORT
      本脚本不会替你安装或配置 Cloudflare Tunnel。是否继续?" \
"[2/3] This service only listens on 127.0.0.1:$BIND_PORT and is never exposed directly.
      To reach it from outside you need to install Cloudflare Tunnel yourself and point
      it at
          http://localhost:$BIND_PORT
      This script will not install or configure Cloudflare Tunnel for you. Continue?"

# ---- 问题 3 / Question 3 ----
echo
say \
"[3/3] 请输入这台服务器对外的网址(域名或子域名)。
      就是你在 Cloudflare 后台给这条 Tunnel 设置的那个公开地址,
      也是之后在 Claude 里填的地址。

      示例: mcp.example.com
      注意: 只填地址本身,不要写 https:// ,也不要写后面的斜杠和 /mcp" \
"[3/3] Enter the public address of this server (a domain or subdomain).
      This is the public hostname you gave the Tunnel in the Cloudflare dashboard,
      and the same one you will later enter in Claude.

      Example: mcp.example.com
      Note: enter the hostname only. No https:// , no trailing slash, no /mcp"

while true; do
    printf '  > '
    read -r DOMAIN
    # 用户很可能整个 URL 粘进来,帮他清理掉 / users often paste a whole URL, so clean it up
    DOMAIN="$(printf '%s' "$DOMAIN" | tr -d ' \t')"
    DOMAIN="${DOMAIN#http://}"
    DOMAIN="${DOMAIN#https://}"
    DOMAIN="${DOMAIN%%/*}"
    case "$DOMAIN" in
        "")
            say "  不能为空,请重新输入。" "  Must not be empty, please try again." ;;
        *.*)
            break ;;
        *)
            say "  这看起来不像一个网址,应该长得像 mcp.example.com 这样。" \
                "  That does not look like a hostname; it should look like mcp.example.com" ;;
    esac
done
say "  好的,使用: $DOMAIN" "  Got it, using: $DOMAIN"


# ==============================================================
step "第 1 步 / Step 1 — 创建降权账号 / Create the unprivileged account" \
     "Step 1 — Create the unprivileged account"
# ==============================================================
sh "$REPO_DIR/create_agent_user.sh" "$RUN_AS_USER"


# ==============================================================
step "第 2 步 / 配置 Python 环境和依赖" \
     "Step 2 — Set up the Python environment and dependencies"
# ==============================================================
sh "$REPO_DIR/config_venv.sh"


# ==============================================================
step "第 3 步 / 写入配置" "Step 3 — Write the configuration"
# ==============================================================
if [ -n "$(read_conf MCP_TOKEN)" ]; then
    say "MCP_TOKEN 已存在,保留原值。" "MCP_TOKEN already set, keeping the existing value."
else
    set_conf MCP_TOKEN "$("$REPO_DIR/venv/bin/python" -c \
        'import secrets; print(secrets.token_urlsafe(32))')"
    say "已生成新的 MCP_TOKEN。" "Generated a new MCP_TOKEN."
fi

set_conf MCP_RUN_AS_USER "$RUN_AS_USER"
set_conf MCP_ALLOWED_HOSTS "$DOMAIN,$DOMAIN:*,127.0.0.1:*,localhost:*"
set_conf MCP_ALLOWED_ORIGINS "https://$DOMAIN"

# 这文件里有密钥,别让别的用户读到 —— 尤其是降权账号自己
# This file holds the token; keep other users out, especially the unprivileged account itself
chmod 600 "$ENV_LOCAL"
say "配置已写入 $ENV_LOCAL" "Configuration written to $ENV_LOCAL"


# ==============================================================
step "第 4 步 / 安装系统服务" "Step 4 — Install the system service"
# ==============================================================
sh "$REPO_DIR/add_service.sh"


# ==============================================================
echo
echo "=============================================="
say "            安装完成" "            Installation complete"
echo "=============================================="
echo
say "本机 MCP 密钥(也可以在 .env_ignored 里查看):" \
    "Your MCP token (also stored in .env_ignored):"
echo
echo "    $(read_conf MCP_TOKEN)"
echo
say "在 Claude 里填的服务器地址:" "The server address to enter in Claude:"
echo
echo "    https://$DOMAIN/mcp"
echo
echo "----------------------------------------------"
say "还没启动。确认 Cloudflare Tunnel 已经指向 http://localhost:$BIND_PORT 之后,运行:" \
    "Not started yet. Once Cloudflare Tunnel points at http://localhost:$BIND_PORT, run:"
echo
echo "    sudo sh start.sh"
echo
say "卸载服务: sudo sh uninstall_service.sh" "To uninstall: sudo sh uninstall_service.sh"
