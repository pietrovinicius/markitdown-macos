## [0.1.9] - 2026-11-17

### Corrigido

- **macos/Sources/MarkItDownMac/MarkItDownMacApp.swift**: substituído `WindowGroup` + `CommandGroup(replacing: .newItem)` por `Window("MarkItDown", id: "main")` + `CommandGroup(after: .newItem)` e `@NSApplicationDelegateAdaptor(MarkItDownAppDelegate.self)`, evitando que o comando de nova janela/reabertura do SwiftUI fosse sobrescrito ao clicar no ícone do Dock.
- **macos/Sources/MarkItDownMacCore/MarkItDownWorkspaceView.swift**: adicionado `MarkItDownAppDelegate` com `applicationShouldHandleReopen`, `applicationDidBecomeActive` e `isReleasedWhenClosed = false` para desminimizar (`deminiaturize`) e trazer a janela para frente ao clicar no ícone do Dock após minimizar ou fechar.
- **macos/Tests/MarkItDownMacTests/MarkItDownMacUITests.swift**: adicionado teste de regressão `testDockReopenRestoresMinimizedAndOrderedOutWindow`.
