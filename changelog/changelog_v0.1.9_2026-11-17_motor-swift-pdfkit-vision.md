## [0.1.9] - 2026-11-17

### Adicionado

- **macos/Package.swift**: manifesto SwiftPM para o núcleo (`MarkItDownMacCore`), executável (`MarkItDownMac`) e suíte de testes (`MarkItDownMacTests`).
- **macos/Sources/MarkItDownMacCore/ConversionModels.swift**: modelos de domínio da fila, estados de conversão, desambiguação de homônimos pela pasta de origem e rótulos de acessibilidade VoiceOver.
- **macos/Sources/MarkItDownMacCore/VisionOCRService.swift**: OCR local via Apple Vision (`pt-BR` e `en-US`) com ordenação de leitura aproximada para imagens e páginas digitalizadas.
- **macos/Sources/MarkItDownMacCore/PDFConversionRouter.swift**: inspeção de camada textual por página via PDFKit, roteamento entre MarkItDown e OCR por página com cabeçalhos `## Página N` e aviso de páginas sem texto.
- **macos/Sources/MarkItDownMacCore/PythonWorkerRunner.swift**: executor assíncrono do subprocesso Python local com cópia temporária isolada e encerramento por sinal no cancelamento.
- **macos/Sources/MarkItDownMacCore/ConversionQueueManager.swift**: fila serial com preservação de seleção, cancelamento ativo e em fila, cópia e exportação atômica em UTF-8.
- **macos/Tests/MarkItDownMacTests/MarkItDownMacCoreTests.swift**: suíte de testes com corpus sintético cobrindo Office, PDF textual/escaneado/misto, OCR em português e inglês, homônimos, cancelamento e falhas distintas.
