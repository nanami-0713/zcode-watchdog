#!/bin/zsh
# install.sh — 安装 zcode-watchdog：复制脚本、生成 launchd 配置、加载常驻
set -e

REPO_DIR="${0:A:h}"
DEST_BIN="$HOME/bin/zcode-watchdog.sh"
DEST_PLIST="$HOME/Library/LaunchAgents/local.zcode-watchdog.plist"

echo "==> 安装脚本到 $DEST_BIN"
mkdir -p "$HOME/bin"
cp "$REPO_DIR/zcode-watchdog.sh" "$DEST_BIN"
chmod +x "$DEST_BIN"

echo "==> 生成 launchd 配置到 $DEST_PLIST"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$REPO_DIR/local.zcode-watchdog.plist" > "$DEST_PLIST"

echo "==> 加载 launchd 服务（每 60 秒巡检一次）"
launchctl bootout "gui/$UID/local.zcode-watchdog" 2>/dev/null || true
launchctl bootstrap "gui/$UID" "$DEST_PLIST"

echo "==> 首轮巡检 + 状态报告"
zsh "$DEST_BIN" --once
zsh "$DEST_BIN" --report

echo ""
echo "安装完成。日志：$HOME/Library/Logs/zcode-watchdog.log"
echo "如有未知端点误报，确认无害后执行：zsh $DEST_BIN --learn"
