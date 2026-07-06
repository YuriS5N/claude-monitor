#!/bin/bash
# Gera packaging/AppIcon.icns a partir de AppIcon.swift (CoreGraphics).
set -e
cd "$(dirname "$0")"

MASTER="/tmp/claude-monitor-icon-1024.png"
ICONSET="/tmp/ClaudeMonitor.iconset"

echo "→ Compilando gerador de ícone..."
swiftc -framework AppKit -O -o /tmp/agicon AppIcon.swift
/tmp/agicon "$MASTER"

echo "→ Montando iconset (todas as resoluções)..."
rm -rf "$ICONSET"; mkdir -p "$ICONSET"
sips -z 16 16     "$MASTER" --out "$ICONSET/icon_16x16.png"      >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$MASTER" --out "$ICONSET/icon_32x32.png"      >/dev/null
sips -z 64 64     "$MASTER" --out "$ICONSET/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$MASTER" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$MASTER" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$MASTER" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$MASTER"                "$ICONSET/icon_512x512@2x.png"
# Cópia PNG p/ a landing (favicon / og-image podem reaproveitar)
cp "$MASTER" ./AppIcon-1024.png

echo "→ iconutil → AppIcon.icns"
iconutil -c icns "$ICONSET" -o AppIcon.icns
echo "✓ packaging/AppIcon.icns"
