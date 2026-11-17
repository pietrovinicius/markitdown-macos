## [0.1.9] - 2026-11-17

### Adicionado

- **macos/Resources/Info.plist**: metadados do aplicativo nativo `MarkItDown.app` para macOS.
- **macos/scripts/build_app.sh**: script de build que congela o worker Python via PyInstaller (`arm64`), compila o executável SwiftUI em modo Release, monta `macos/dist/MarkItDown.app` e aplica assinatura local.
- **macos/Tests/MarkItDownMacTests/MarkItDownPackagedAppTests.swift**: teste de verificação do `.app` empacotado e execução offline sem Python do usuário no `PATH`.

### Alterado

- **macos/worker/markitdown_macos_worker.py**: dispensa carregamento do módulo `magika` no binário congelado por usar validação explícita de extensão e estrutura.
- **PRODUCT.md**: registro da validação offline do `.app` em macOS `26.6.2` (`25G83`) e arquitetura `arm64`.
- **DESIGN.md**: referência ao ambiente validado no smoke test do `.app`.
