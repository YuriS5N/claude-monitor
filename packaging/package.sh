#!/bin/bash
# package.sh — compila, monta ClaudeMonitor.app, assina, cria o .dmg e (se
# houver credenciais) notariza + staple. Saída em packaging/dist/.
#
# Requisitos para DISTRIBUIÇÃO pública (download no site):
#   1) Certificado "Developer ID Application" no Keychain.
#      Gere em: Xcode ▸ Settings ▸ Accounts ▸ Manage Certificates ▸ + Developer ID Application
#      (ou em https://developer.apple.com/account/resources/certificates)
#   2) Perfil de notarização salvo:
#      xcrun notarytool store-credentials claude-monitor-notary \
#        --apple-id "SEU_APPLE_ID" --team-id "SEU_TEAM_ID" --password "APP_SPECIFIC_PASSWORD"
#
# Sem (1) o script gera um .app/.dmg NÃO assinado (só p/ teste local).
# Sem (2) ele assina mas pula a notarização.
#
# Overrides por env: SIGN_ID, NOTARY_PROFILE, APP_VERSION
#
# Nota: rode num shell SEM sandbox. Sandboxado, o codesign não alcança a chave
# privada no keychain e falha com "errSecInternalComponent".
set -e
cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

APP_NAME="ClaudeMonitor"
BUNDLE_ID="com.agape.claude-monitor"
APP_VERSION="${APP_VERSION:-1.1.0}"   # bumpe aqui ou passe APP_VERSION=x.y.z
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-monitor-notary}"

DIST="$PWD/dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME.dmg"

rm -rf "$DIST"; mkdir -p "$DIST"

# ─── 1. Compilar (arm64, otimizado) ────────────────────────────────────────
echo "→ [1/6] Compilando binário..."
clang -c -O2 -o /tmp/claude-monitor-exceptioncatcher.o "$ROOT/Sources/ExceptionCatcher.m"
swiftc -parse-as-library -framework SwiftUI -framework AppKit -O \
    -import-objc-header "$ROOT/Sources/ExceptionCatcher.h" \
    -o "$DIST/$APP_NAME.bin" "$ROOT"/Sources/*.swift \
    /tmp/claude-monitor-exceptioncatcher.o

# ─── 2. Ícone ──────────────────────────────────────────────────────────────
if [ ! -f AppIcon.icns ]; then ./make_icon.sh; fi

# ─── 3. Montar o .app ──────────────────────────────────────────────────────
echo "→ [2/6] Montando $APP_NAME.app..."
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$DIST/$APP_NAME.bin" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>Claude Monitor</string>
    <key>CFBundleDisplayName</key>     <string>Claude Monitor</string>
    <key>CFBundleIdentifier</key>      <string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key>      <string>$APP_NAME</string>
    <key>CFBundleIconFile</key>        <string>AppIcon</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$APP_VERSION</string>
    <key>CFBundleVersion</key>         <string>$APP_VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHumanReadableCopyright</key> <string>© 2026 Yuri Gomes de Abreu · MIT License</string>
    <key>NSHighResolutionCapable</key> <true/>
</dict>
</plist>
PLIST

# ─── 4. Assinar (hardened runtime) ─────────────────────────────────────────
if [ -z "$SIGN_ID" ]; then
    SIGN_ID="$(security find-identity -v -p codesigning | grep 'Developer ID Application' | head -1 | sed -E 's/.*"(.*)"/\1/')"
fi

if [ -n "$SIGN_ID" ]; then
    echo "→ [3/6] Assinando com: $SIGN_ID"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" "$APP/Contents/MacOS/$APP_NAME"
    codesign --force --options runtime --timestamp \
        --sign "$SIGN_ID" "$APP"
    codesign --verify --deep --strict --verbose=2 "$APP"
    SIGNED=1
else
    echo "⚠  [3/6] Nenhum certificado 'Developer ID Application' encontrado."
    echo "   Gerando .app/.dmg NÃO assinado (só p/ teste local — Gatekeeper vai bloquear no download)."
    echo "   Veja o cabeçalho deste script para criar o certificado."
    SIGNED=0
fi

# ─── 5. Criar .dmg ('arraste p/ Applications') ─────────────────────────────
echo "→ [4/6] Criando $APP_NAME.dmg..."
STAGE="$DIST/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Claude Monitor" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
[ "$SIGNED" = "1" ] && codesign --force --sign "$SIGN_ID" "$DMG"

# ─── 6. Notarizar + staple ─────────────────────────────────────────────────
if [ "$SIGNED" = "1" ] && xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" &>/dev/null; then
    echo "→ [5/6] Notarizando (pode levar 1-5 min)..."
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "→ [6/6] Staple..."
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    echo "✓ Notarizado e stapled."
else
    echo "⚠  [5/6] Notarização pulada (sem perfil '$NOTARY_PROFILE' ou app não assinado)."
    echo "   Configure com: xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id ... --team-id ... --password ..."
fi

echo ""
echo "════════════════════════════════════════════"
echo "✓ Pronto: $DMG"
du -h "$DMG" | cut -f1 | xargs echo "  Tamanho:"
[ "$SIGNED" = "1" ] && echo "  Assinado: sim" || echo "  Assinado: NÃO (só teste local)"
echo "════════════════════════════════════════════"
