## [0.1.9] - 2026-11-17

### Adicionado

- **macos/Sources/MarkItDownMacCore/MarkItDownWorkspaceView.swift**: janela de trabalho SwiftUI (`960x640`, mínimo `720x480`, lista ~`250pt`), importação por arrastar e soltar, barra lateral com estados e cancelamento, painel de resultado monoespaçado selecionável, confirmações de cópia/salvamento e suporte a VoiceOver e redução de movimento.
- **macos/Sources/MarkItDownMac/MarkItDownMacApp.swift**: ponto de entrada do aplicativo macOS com atalhos nativos (`⌘O` e `⌘S`), painéis `NSOpenPanel`/`NSSavePanel` vinculados à seleção e modo `--smoke-test`.
- **macos/Tests/MarkItDownMacTests/MarkItDownMacUITests.swift**: testes de renderização nos tamanhos inicial e mínimo, validação de contraste (>= 4,5:1) nos temas claro e escuro e confirmações de cópia e salvamento.
