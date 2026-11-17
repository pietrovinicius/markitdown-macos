# MarkItDown para macOS — especificação do MVP

<!-- impeccable:product-schema 1 -->

## Platform

macOS nativo.

## Stack

SwiftUI para a interface, MarkItDown para conversão de documentos e Apple Vision para OCR local. O [design](DESIGN.md) define as responsabilidades de cada componente.

## Users

Pessoas que precisam extrair conteúdo de arquivos do Finder para reutilizá-lo em Markdown, incluindo quem recebe documentos digitalizados junto com arquivos de escritório.

## Product Purpose

Converter arquivos locais em texto Markdown que a pessoa possa conferir, copiar ou salvar. O resultado deve permitir reutilizar texto e estrutura extraível. Em documentos digitalizados, o app deve identificar o uso de OCR e informar quando a extração estiver incompleta.

## Capabilities and Constraints

| Entrada | Resultado esperado |
| --- | --- |
| `.docx`, `.xlsx`, `.pptx` | Conteúdo textual e estrutura que o conversor extrair do documento, da planilha ou da apresentação. |
| `.pdf` com texto | Markdown produzido pelo conversor de PDF do MarkItDown. |
| `.pdf` escaneado ou misto | Texto por página, em ordem, com OCR nas páginas sem camada textual utilizável. |
| `.png`, `.jpg`, `.jpeg` | Texto reconhecido por OCR, em ordem de leitura aproximada. |

- **Importação.** Aceitar um ou mais arquivos pelo seletor do sistema ou por arrastar e soltar. Cada arquivo tem estado e resultado próprios. Uma falha individual permite continuar a fila.
- **Revisão.** Exibir Markdown selecionável e de leitura, com indicação de OCR quando aplicado. Um PDF misto pode concluir integralmente. Quando houver saída parcial, identificar as páginas sem resultado e manter o texto disponível. Se todo o arquivo ficar sem texto, mostrar falha e desabilitar cópia e exportação.
- **Exportação.** Copiar o Markdown integral do item selecionado ou salvar um `.md` por vez em UTF-8. Sugerir o nome de origem com a nova extensão. Pedir confirmação antes de substituir um arquivo existente. Cancelar o salvamento preserva a conversão.
- **Processamento local.** Converter sem serviços externos, chaves de API ou instalação de Python pelo usuário. Preservar os originais. A fila e os resultados vivem durante a sessão. O único arquivo de saída durável é o que a pessoa salva.
- **OCR.** Validar português brasileiro e inglês no macOS mínimo que vier a ser suportado. O compromisso do MVP é extrair texto de páginas e imagens. Reconstrução de tabelas de digitalizações, OCR de imagens embutidas em Office, formatação visual fiel, exportação em lote e histórico persistente ficam fora do MVP.

## Acceptance Criteria

| Cenário | Evidência esperada |
| --- | --- |
| Converter DOCX, XLSX, PPTX e PDF textual | Uma amostra por formato produz Markdown copiável e exportável. O corpus verifica texto acentuado e estrutura representativa do respectivo formato. |
| Converter scans e imagens | PDF digitalizado, PNG e JPEG produzem texto útil a partir de amostras controladas em português e inglês, com indicação de OCR. |
| Converter PDF misto | Uma página textual, uma digitalizada e uma sem texto reconhecível preservam a ordem. Há aviso com o número da página sem resultado. O mesmo caso sem a página vazia conclui sem aviso de extração parcial. |
| Tratar falha e cancelamento | Arquivo corrompido, PDF bloqueado, formato desconhecido e conversão cancelada exibem estados distintos. O próximo arquivo segue e o cancelado fica sem saída publicável. |
| Exportar dois arquivos com o mesmo nome-base | Os dois resultados ficam acessíveis na fila. Ao gravar no mesmo destino, o arquivo existente permanece intacto até a confirmação de substituição. O texto salvo corresponde à cópia integral e abre como UTF-8. |
| Executar o app empacotado | Em um Mac compatível, sem rede e sem Python instalado pelo usuário, iniciar o `.app`, converter um arquivo Office e um scan e salvar a saída de ambos. |
| Operar com teclado e VoiceOver | Adicionar, selecionar, acompanhar, cancelar, copiar e salvar pelo teclado. VoiceOver anuncia nome, estado e ações disponíveis sem mudança inesperada de foco. |

## Release Decisions

O macOS mínimo, as arquiteturas de processador e o canal de distribuição serão definidos com base na prova de empacotamento e OCR. A matriz aprovada de suporte deve constar no plano de implementação antes de fixar os alvos de build.
