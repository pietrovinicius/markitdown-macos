## [0.1.9] - 2026-11-17

### Adicionado

- **macos/Resources/AppIcon.icns**: ícone nativo do aplicativo macOS em todas as resoluções padrão (`16x16` a `512x512@2x`).

### Alterado

- **macos/Resources/Info.plist**: inclusão de `CFBundleIconFile` apontando para `AppIcon`.
- **macos/scripts/build_app.sh**: cópia do `AppIcon.icns` para `Contents/Resources/` na montagem do `MarkItDown.app`.
- **macos/Tests/MarkItDownMacTests/MarkItDownPackagedAppTests.swift**: asserção da presença de `AppIcon.icns` e `CFBundleIconFile` no bundle empacotado.
