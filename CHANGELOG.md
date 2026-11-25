# Changelog

## [0.1.9] - 2026-11-25

### Adicionado

- **PRODUCT.md** e **DESIGN.md**: escopo do MVP local, critérios de aceitação, fluxo da interface, arquitetura de conversão, acessibilidade e validação do app empacotado.
- **macos/Package.swift**: núcleo `MarkItDownMacCore`, executável `MarkItDownMac` e suíte `MarkItDownMacTests`.
- **macos/Sources/MarkItDownMacCore/ConversionModels.swift**: estados e modelos da fila, distinção de arquivos homônimos pela origem e rótulos VoiceOver.
- **macos/Sources/MarkItDownMacCore/VisionOCRService.swift**: OCR local via Apple Vision para `pt-BR` e `en-US`, com ordenação de leitura aproximada.
- **macos/Sources/MarkItDownMacCore/PDFConversionRouter.swift**: inspeção por página via PDFKit e roteamento entre MarkItDown e OCR para PDFs textuais, escaneados ou mistos.
- **macos/Sources/MarkItDownMacCore/PythonWorkerRunner.swift**: execução assíncrona do worker local, isolamento em cópia temporária e cancelamento do subprocesso.
- **macos/Sources/MarkItDownMacCore/ConversionQueueManager.swift**: fila serial, preservação da seleção, cancelamento, cópia e exportação atômica em UTF-8.
- **macos/worker/markitdown_macos_worker.py**: conversão local de DOCX, XLSX, PPTX e PDF textual via `convert_local()`, plugins desativados, validação estrutural e diagnóstico JSON sanitizado.
- **macos/Sources/MarkItDownMacCore/MarkItDownWorkspaceView.swift**: janela SwiftUI redimensionável, arrastar e soltar, estados e cancelamento por arquivo, resultado selecionável, confirmações e suporte a VoiceOver e redução de movimento.
- **macos/Sources/MarkItDownMac/MarkItDownMacApp.swift**: entrada do app, atalhos `⌘O` e `⌘S`, painéis nativos de abrir e salvar e modo `--smoke-test`.
- **macos/Resources/Info.plist** e **macos/Resources/AppIcon.icns**: metadados e ícone nativo nas resoluções padrão de `16x16` a `512x512@2x`.
- **macos/scripts/build_app.sh**: empacotamento do worker com PyInstaller para `arm64`, compilação Release do SwiftUI, montagem do `.app` e assinatura local ad hoc.
- **Testes**: coberturas do worker, núcleo, interface e app empacotado para formatos, OCR, cancelamento, acessibilidade, exportação e execução offline sem Python do usuário no `PATH`.

### Alterado

- **Worker Python**: valida extensões e estrutura dos arquivos, sem carregar `magika` no binário congelado.
- **PRODUCT.md**: critérios verificáveis para OCR, fila, arquivos homônimos e exportação; registra a validação offline e OCR em macOS `26.6.2` (`25G83`), `arm64`.
- **DESIGN.md**: wireframe, dimensões de referência da janela e regras de seleção, feedback, cancelamento, falha parcial e salvamento.
- **Bundle**: `Info.plist` aponta para `AppIcon`; o script copia o ícone para `Contents/Resources/` e o teste do bundle verifica sua presença.
- **Processo Swift**: stdout e stderr são consumidos em paralelo durante a conversão, inclusive para saídas maiores que a capacidade do pipe.

### Corrigido

- **Reabertura pelo Dock**: a janela volta à frente após minimizar ou fechar o app; foi adicionado teste de regressão para o fluxo.
- **Documentos extensos**: a leitura simultânea dos pipes permite concluir conversões com saída Markdown grande, continuar a fila e cancelar durante a inicialização do worker.
