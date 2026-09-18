#!/bin/zsh
# uninstall.sh — 卸载 zcode-watchdog
launchctl bootout "gui/$UID/local.zcode-watchdog" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/local.zcode-watchdog.plist"
rm -f "$HOME/bin/zcode-watchdog.sh"
echo "已卸载。"
echo "以下文件保留备查，不需要可自行删除："
echo "  日志: $HOME/Library/Logs/zcode-watchdog.log"
echo "  状态: $HOME/Library/Application Support/zcode-watchdog"
