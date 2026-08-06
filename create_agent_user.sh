#!/bin/sh
# 创建给 MCP server 降权用的普通账号。
#   - 独立的 home 目录 /home/<用户名>
#   - 不加入 sudo/wheel/admin,不写 sudoers
#   - 锁密码,禁止交互式登录(只能由 root setuid / su 切过去)
#
# 用法: sudo sh create-agent-user.sh [用户名]     默认用户名 mcpagent
set -eu

USERNAME="${1:-mcpagent}"

die() { echo "错误: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行"
command -v useradd >/dev/null 2>&1 || die "找不到 useradd(Alpine 需先 apk add shadow)"

# ---------- 1. 建用户 ----------
if id "$USERNAME" >/dev/null 2>&1; then
    echo "用户 $USERNAME 已存在,跳过创建"
else
    if [ -x /bin/bash ]; then LOGIN_SHELL=/bin/bash; else LOGIN_SHELL=/bin/sh; fi
    # -m 建 home 目录,不指定 -d 就是默认的 /home/<用户名>
    useradd -m -s "$LOGIN_SHELL" "$USERNAME"
    echo "已创建用户 $USERNAME (shell=$LOGIN_SHELL)"
fi

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -d "$HOME_DIR" ] || die "home 目录 $HOME_DIR 不存在"

# 别让别的用户翻它的 home
chmod 0700 "$HOME_DIR"

# ---------- 2. 确保没有任何提权途径 ----------
usermod -L "$USERNAME"          # 锁密码,禁掉密码登录

for g in sudo wheel admin adm; do
    if getent group "$g" >/dev/null 2>&1; then
        gpasswd -d "$USERNAME" "$g" >/dev/null 2>&1 || true
    fi
done

if [ -f "/etc/sudoers.d/$USERNAME" ]; then
    echo "警告: /etc/sudoers.d/$USERNAME 已存在,该用户仍有 sudo 权限,请自行确认" >&2
fi

# ---------- 3. 验收 ----------
echo
echo "===== 结果 ====="
id "$USERNAME"
echo "home:  $HOME_DIR  ($(stat -c '%a %U:%G' "$HOME_DIR"))"

printf 'sudo:  '
if command -v sudo >/dev/null 2>&1; then
    sudo -l -U "$USERNAME" 2>&1 | tail -n 1
else
    echo "(系统未装 sudo)"
fi

echo "写测试: $(su -s /bin/sh -c "touch '$HOME_DIR/.wtest' 2>/dev/null && rm -f '$HOME_DIR/.wtest' && echo home 可写【预期】 || echo home 不可写【异常】" "$USERNAME")"
echo "越权测试: $(su -s /bin/sh -c "touch /etc/.wtest 2>/dev/null && rm -f /etc/.wtest && echo /etc 可写【有问题】 || echo /etc 不可写【预期】" "$USERNAME")"

echo
echo "接下来把 server.py 里的 RUN_AS_USER 改成: $USERNAME"
echo "Succeed"