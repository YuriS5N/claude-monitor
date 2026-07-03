#!/bin/bash
# Instala LaunchAgent: inicia no login e REINICIA sozinho se o app crashar
set -e

PLIST_NAME="com.agape.claude-monitor"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_NAME}.plist"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Descarregar versao anterior se existir
launchctl bootout "gui/$(id -u)/${PLIST_NAME}" 2>/dev/null || true

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_NAME}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${SCRIPT_DIR}/ClaudeMonitor</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <!-- Reinicia se sair com erro (crash); saida limpa (botao Sair) NAO reinicia -->
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>10</integer>
    <key>WorkingDirectory</key>
    <string>${SCRIPT_DIR}</string>
    <key>StandardOutPath</key>
    <string>/tmp/claude-monitor.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/claude-monitor.err</string>
</dict>
</plist>
EOF

# Matar instancia manual antes de carregar (evita duplicata)
pkill -f "ClaudeMonitor" 2>/dev/null || true
sleep 1

launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
echo "LaunchAgent instalado: $PLIST_PATH"
echo "- Inicia no login"
echo "- Reinicia sozinho se crashar (KeepAlive SuccessfulExit=false)"
echo "- Logs: /tmp/claude-monitor.log e /tmp/claude-monitor.err"
