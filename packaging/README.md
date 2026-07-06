# Packaging & Distribution

How the downloadable, double-click-installable **ClaudeMonitor.dmg** is built, signed,
notarized and released. Non-technical users never touch a terminal — they download the
`.dmg`, drag the app to Applications, and launch it.

```
packaging/
├── AppIcon.swift    ← gerador do ícone (CoreGraphics) → 1024px master
├── make_icon.sh     ← AppIcon.swift + sips + iconutil → AppIcon.icns
├── package.sh       ← compila → .app → assina → .dmg → notariza → staple
├── release.sh       ← gh release create com o .dmg
└── dist/            ← saída (gitignored): ClaudeMonitor.app, ClaudeMonitor.dmg
```

## Pré-requisitos (uma vez só)

Você já tem uma conta Apple Developer paga. Faltam **dois** itens para distribuição fora
da App Store:

### 1. Certificado "Developer ID Application"

É o certificado específico para apps distribuídos por download direto (não App Store).
Os certificados "Apple Distribution" e "Apple Development" que você já tem **não** servem
para isso.

**Xcode** ▸ Settings ▸ Accounts ▸ (sua conta) ▸ **Manage Certificates** ▸ botão **+** ▸
**Developer ID Application**.

Ou pelo portal: https://developer.apple.com/account/resources/certificates → **+** →
*Developer ID Application* → siga o assistente e instale o `.cer` (duplo-clique).

Confirme que apareceu:
```bash
security find-identity -v -p codesigning | grep "Developer ID Application"
```

### 2. Credenciais de notarização (app-specific password)

1. Crie uma senha de app em https://appleid.apple.com ▸ Sign-In and Security ▸
   App-Specific Passwords.
2. Descubra seu Team ID em https://developer.apple.com/account (canto superior direito)
   — algo como `YN97Y8SYU6`.
3. Salve o perfil no keychain (o nome `claude-monitor-notary` é o que o `package.sh` usa):
   ```bash
   xcrun notarytool store-credentials claude-monitor-notary \
     --apple-id "yuris5n@gmail.com" \
     --team-id "SEU_TEAM_ID" \
     --password "sua-app-specific-password"
   ```

## Gerar o build distribuível

```bash
./packaging/package.sh
```
O script detecta automaticamente o certificado Developer ID e o perfil de notarização.
Sem eles, ele ainda gera um `.dmg` **não assinado** (só para teste local) e avisa.

Saída: `packaging/dist/ClaudeMonitor.dmg` — assinado, notarizado e stapled.

## Publicar a release

```bash
./packaging/release.sh v1.0.0
```
Cria a release no GitHub com o `.dmg`. O botão de download da landing page aponta sempre
para `releases/latest/download/ClaudeMonitor.dmg`, então cada nova release atualiza o
download automaticamente — sem mexer no site.

## Lançar uma nova versão

1. `APP_VERSION=1.1.0 ./packaging/package.sh`
2. `./packaging/release.sh v1.1.0`

## Detalhes técnicos

- **Hardened runtime** (`--options runtime`) é obrigatório para notarização; o app não usa
  entitlements especiais (a leitura do Keychain é feita via subprocesso `security`, e a
  única chamada de rede é para `api.anthropic.com`).
- **LSUIElement=true** no Info.plist → app "accessory": sem ícone no Dock, só menu bar.
- O `.dmg` traz um symlink para `/Applications`, então o usuário só arrasta o app.
- O ícone é gerado por código (CoreGraphics) — squircle coral + medidor de rate-limit +
  losango ◆, a mesma marca do glifo da menu bar.
