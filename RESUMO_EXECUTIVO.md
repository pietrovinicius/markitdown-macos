# Resumo executivo

**Projeto:** MarkItDown para macOS · **Data:** 2026-11-25

## Finalidade

Aplicativo nativo que converte documentos locais em Markdown para leitura, cópia ou salvamento. É uma interface macOS sobre o MarkItDown; não altera o conversor original do projeto.

## Ajustes incorporados

- Interface SwiftUI com importação por seletor ou arrastar e soltar, fila por arquivo, cancelamento, resultado selecionável e exportação `.md` em UTF-8.
- Worker Python incluído no bundle usa o MarkItDown local para DOCX, XLSX, PPTX e PDF com camada textual, com plugins desativados.
- PDFKit e Apple Vision fazem o roteamento de PDFs textuais, digitalizados ou mistos. Vision também extrai texto de imagens localmente.
- Bundle `MarkItDown.app` com ícone e dependências empacotadas para Apple Silicon; a pessoa não precisa instalar Python. O script atual aplica assinatura ad hoc.
- Correções para reabrir a janela pelo Dock e processar saídas extensas sem bloquear os pipes do worker.

## Evidências e limites

- `PRODUCT.md` registra smoke test offline e OCR em pt-BR/en-US no macOS 26.6.2, build 25G83, arm64. Esse registro não foi reexecutado nesta consolidação.
- Há suítes de testes para worker, núcleo Swift, interface e bundle. Elas também não foram executadas nesta consolidação.
- SwiftPM declara macOS 14 como mínimo, mas a validação registrada cobre macOS 26.6.2; compatibilidade com a versão mínima ainda não está demonstrada. O build atual é arm64; Intel não foi validado.
- O resultado preserva texto e estrutura extraível, não a aparência original. OCR de imagens dentro de documentos Office, exportação em lote e histórico persistente ficam fora do MVP.
- O script gera assinatura local ad hoc; assinatura de distribuição e notarização não constam no fluxo atual.

## Referências

- [Especificação do MVP](PRODUCT.md)
- [Design técnico e de interface](DESIGN.md)
- [Implementação macOS](macos/)
- [Histórico consolidado](CHANGELOG.md)
