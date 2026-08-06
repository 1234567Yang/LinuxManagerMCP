#!/bin/sh
# 建 venv 并装依赖,可重复跑 / Create the venv and install dependencies. Safe to re-run.
#
# 用法 / Usage: sh config_venv.sh
set -eu

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_DIR="$REPO_DIR/venv"

say() { echo "$1"; echo "$2"; }
die() { echo "错误: $1" >&2; echo "Error: $2" >&2; exit 1; }

[ -f "$REPO_DIR/requirements.txt" ] \
    || die "$REPO_DIR 下找不到 requirements.txt" "requirements.txt not found in $REPO_DIR"

PYTHON="$(command -v python3 || true)"
[ -n "$PYTHON" ] || die "找不到 python3" "python3 not found"

# server.py 用了 match 语句,需要 3.10+ / server.py uses match statements, so 3.10+ is required
"$PYTHON" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 10) else 1)' \
    || die "需要 Python 3.10 或更高,当前是 $("$PYTHON" -V 2>&1)" \
           "Python 3.10 or newer is required, found $("$PYTHON" -V 2>&1)"

if [ -x "$VENV_DIR/bin/python" ]; then
    say "venv 已存在,跳过创建: $VENV_DIR" "venv already exists, skipping creation: $VENV_DIR"
else
    say "创建 venv: $VENV_DIR" "Creating venv: $VENV_DIR"
    # Debian/Ubuntu 把 venv 拆成了单独的包 / Debian and Ubuntu ship venv as a separate package
    "$PYTHON" -m venv "$VENV_DIR" \
        || die "创建 venv 失败。Debian/Ubuntu 上可能需要先: apt install python3-venv" \
               "Failed to create the venv. On Debian/Ubuntu try: apt install python3-venv"
fi

say "安装依赖 ..." "Installing dependencies ..."
"$VENV_DIR/bin/python" -m pip install --upgrade pip
"$VENV_DIR/bin/python" -m pip install -r "$REPO_DIR/requirements.txt"

# 装完真的 import 一遍,比看 pip 的退出码靠谱
# Actually import them; more reliable than trusting pip's exit code
"$VENV_DIR/bin/python" -c 'import mcp, uvicorn, starlette, dotenv' \
    || die "依赖装上了但 import 失败,看看上面的 pip 输出" \
           "Dependencies installed but the import failed; check the pip output above"

echo
say "===== 完成 =====" "===== Done ====="
echo "  $VENV_DIR/bin/python"
say "  依赖导入正常" "  All dependencies import correctly"
