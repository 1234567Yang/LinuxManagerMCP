#!/bin/sh
# 创建给 MCP server 降权用的普通账号 / Create the unprivileged account the MCP server drops to.
#   - 独立的 home 目录 /home/<用户名>
#   - 不加入 sudo/wheel/admin,不写 sudoers
#   - 锁密码,禁止交互式登录(只能由 root setuid / su 切过去)
#
# 用法 / Usage: sudo sh create_agent_user.sh [用户名 / username]
set -eu

USERNAME="${1:-mcpagent}"

say() { echo "$1"; echo "$2"; }
die() { echo "错误: $1" >&2; echo "Error: $2" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "请用 root 运行" "Please run as root"
command -v useradd >/dev/null 2>&1 \
    || die "找不到 useradd(Alpine 需先 apk add shadow)" \
           "useradd not found (on Alpine, run: apk add shadow)"

# ---------- 1. 建用户 / Create the account ----------
if id "$USERNAME" >/dev/null 2>&1; then
    say "用户 $USERNAME 已存在,跳过创建" "User $USERNAME already exists, skipping creation"
else
    if [ -x /bin/bash ]; then LOGIN_SHELL=/bin/bash; else LOGIN_SHELL=/bin/sh; fi
    # -m 建 home 目录,不指定 -d 就是默认的 /home/<用户名>
    useradd -m -s "$LOGIN_SHELL" "$USERNAME"
    say "已创建用户 $USERNAME (shell=$LOGIN_SHELL)" \
        "Created user $USERNAME (shell=$LOGIN_SHELL)"
fi

HOME_DIR="$(getent passwd "$USERNAME" | cut -d: -f6)"
[ -d "$HOME_DIR" ] || die "home 目录 $HOME_DIR 不存在" "Home directory $HOME_DIR does not exist"

# 别让别的用户翻它的 home / keep other users out of its home
chmod 0700 "$HOME_DIR"

# ---------- 2. 确保没有任何提权途径 / Make sure it cannot escalate ----------
usermod -L "$USERNAME"          # 锁密码 / lock the password

for g in sudo wheel admin adm; do
    if getent group "$g" >/dev/null 2>&1; then
        gpasswd -d "$USERNAME" "$g" >/dev/null 2>&1 || true
    fi
done

if [ -f "/etc/sudoers.d/$USERNAME" ]; then
    echo "警告: /etc/sudoers.d/$USERNAME 已存在,该用户仍有 sudo 权限,请自行确认" >&2
    echo "Warning: /etc/sudoers.d/$USERNAME exists, so this user still has sudo. Please check it." >&2
fi

# ---------- 3. 验收 / Verify ----------
echo
say "===== 结果 =====" "===== Result ====="
id "$USERNAME"
echo "home: $HOME_DIR  ($(stat -c '%a %U:%G' "$HOME_DIR"))"

printf 'sudo: '
if command -v sudo >/dev/null 2>&1; then
    sudo -l -U "$USERNAME" 2>&1 | tail -n 1
else
    say "(系统未装 sudo)" "(sudo is not installed)"
fi

if su -s /bin/sh -c "touch '$HOME_DIR/.wtest' 2>/dev/null" "$USERNAME"; then
    su -s /bin/sh -c "rm -f '$HOME_DIR/.wtest'" "$USERNAME"
    say "写测试:   home 可写【预期】" "Write test:     home is writable (expected)"
else
    say "写测试:   home 不可写【异常】" "Write test:     home is NOT writable (unexpected)"
fi

if su -s /bin/sh -c "touch /etc/.wtest 2>/dev/null" "$USERNAME"; then
    su -s /bin/sh -c "rm -f /etc/.wtest" "$USERNAME"
    say "越权测试: /etc 可写【有问题】" "Privilege test: /etc is writable (PROBLEM)"
else
    say "越权测试: /etc 不可写【预期】" "Privilege test: /etc is not writable (expected)"
fi

echo
say "把 .env_ignored 里的 MCP_RUN_AS_USER 设成: $USERNAME" \
    "Set MCP_RUN_AS_USER in .env_ignored to: $USERNAME"
