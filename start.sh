#!/bin/bash
# Inicia o Claude Monitor na menu bar
cd "$(dirname "$0")"

PLIST_NAME="com.agape.claude-monitor"

# Se o LaunchAgent estiver instalado, usar launchd (gerencia restart em crash)
if launchctl print "gui/$(id -u)/${PLIST_NAME}" &>/dev/null; then
    launchctl kickstart -k "gui/$(id -u)/${PLIST_NAME}"
    echo "Claude Monitor (re)iniciado via launchd"
else
    # Fallback: execucao manual
    pkill -f "ClaudeMonitor" 2>/dev/null || true
    sleep 1
    ./ClaudeMonitor &
    echo "Claude Monitor iniciado (PID: $!)"
    echo "Dica: ./install_launchagent.sh para auto-start e restart em crash"
fi
