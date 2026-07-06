#!/bin/bash
# release.sh — publica uma release no GitHub com o .dmg (assinado + notarizado).
# Rode DEPOIS de ./package.sh ter gerado packaging/dist/ClaudeMonitor.dmg.
#
# Uso:  ./release.sh v1.0.0
set -e
cd "$(dirname "$0")"

TAG="${1:-v1.0.0}"
DMG="dist/ClaudeMonitor.dmg"
REPO="YuriS5N/claude-monitor"

[ -f "$DMG" ] || { echo "✗ $DMG não existe. Rode ./package.sh primeiro."; exit 1; }

# Aviso se o dmg não estiver notarizado (stapler valida o ticket embutido)
if ! xcrun stapler validate "$DMG" &>/dev/null; then
  echo "⚠  ATENÇÃO: $DMG não parece notarizado."
  echo "   Usuários verão avisos do Gatekeeper. Notarize antes (veja package.sh)."
  read -p "   Publicar mesmo assim? [y/N] " ok
  [ "$ok" = "y" ] || exit 1
fi

echo "→ Publicando release $TAG em $REPO..."
gh release create "$TAG" "$DMG" \
  --repo "$REPO" \
  --title "Claude Monitor $TAG" \
  --notes "Native macOS menu-bar app for your Claude Code rate limits.

**Install:** download \`ClaudeMonitor.dmg\`, open it, and drag **Claude Monitor** to Applications. Apple Silicon · macOS 14+.

Signed & notarized by Apple — just double-click to open.

Website: https://github.com/$REPO
"
echo "✓ Release publicada. O botão de download da landing aponta para:"
echo "  https://github.com/$REPO/releases/latest/download/ClaudeMonitor.dmg"
