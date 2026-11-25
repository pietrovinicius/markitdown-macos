# MarkItDown para macOS | Plano de correção da conversão

> Execução pelo `orquestrador`, em uma tarefa com TDD e revisão pelo agente principal. A aprovação deste plano autoriza corrigir, empacotar e atualizar a instalação local com cópia recuperável.

**Objetivo.** Converter o catálogo DOCX de aceite pela janela instalada e salvar os 110.023 bytes de Markdown em UTF-8. A fila deve continuar após sucesso, erro ou cancelamento.

**Arquitetura.** A janela SwiftUI mantém seleção e fila. PDFKit e Vision cuidam dos scans. O processo MarkItDown empacotado converte Office e PDF textual. A correção fica na comunicação do processo Swift com esse conversor.

**Stack.** Swift, Foundation Process, XCTest, SwiftUI, PDFKit, Vision e worker Python já empacotado.

**Especificação.** [Produto](../../../PRODUCT.md) e [design técnico e de interface](../../../DESIGN.md).

## Evidência e restrições

- App 0.1.9 presente em `/Applications/MarkItDown.app`. macOS 26.7.3 (25G342), Apple Silicon. A assinatura local passou em `codesign --verify --deep --strict`.
- Passaram 11 testes Swift e 13 Python, Ruff e mypy do worker. O bundle instalado converteu e exportou Office e OCR sob bloqueio de rede IP. DOCX, XLSX, PPTX e PDF textual também passaram pelo worker instalado.
- Na janela, um DOCX de quatro registros gerou um arquivo de 463 bytes. Com mil registros, o worker isolado produziu 110.023 bytes. Na fila, permaneceu em “Convertendo”. Uma amostra do processo mostrou o worker em `write` durante toda a coleta. O Swift lê os dois pipes apenas em `terminationHandler`, depois da saída que o worker aguardava para concluir. O botão Cancelar encerrou a operação.
- Preservar a fila sequencial, mensagens existentes, cópia/exportação integrais, OCR pt-BR/en-US, processamento local e remoção da cópia temporária da entrada. O bundle usa assinatura ad hoc para este Mac.

## T1. Consumir a saída durante a conversão

**Arquivos permitidos ao executor**

- `macos/Sources/MarkItDownMacCore/PythonWorkerRunner.swift` para execução e coleta de stdout e stderr.
- `macos/Tests/MarkItDownMacTests/MarkItDownMacCoreTests.swift` para regressões do processo real.

**Interface preservada**

```swift
func convert(
    fileURL: URL,
    onTerminationHandler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
) async throws -> String
```

**RISCO:** não. **BASE:** `4d1112f4e8b404d37dc7cc233778edb435961301`. **STATUS BASE:** `?? docs/superpowers/plans/2026-11-25-markitdown-macos-conversao.md`. Plano aprovado para a correção e atualização local. **COMMIT:** pendente de execução.

- [x] **RED.** Na classe de testes existente, criar testes com prefixo `testWorkerStream`. Usar `tempDir`, `repoRootURL()` e o inicializador público do runner. O conversor controlado usa o Python da venv com `-c`, recebe a URL separada e encerra sozinho com `signal.alarm(8)` se a leitura bloquear. A comparação de sucesso é integral, incluindo a última linha e os acentos.

```swift
let arquivo = tempDir.appendingPathComponent("entrada.docx")
try Data("amostra".utf8).write(to: arquivo)
let script = """
import signal, sys
signal.alarm(8)
sys.stdout.buffer.write(("Revisão do catálogo em São Paulo.\\n" * 8192 + "Fim.").encode())
sys.stdout.buffer.flush()
sys.stderr.buffer.write(b"." * 262144)
"""
let runner = SubprocessPythonWorkerRunner(
    executableURL: repoRootURL().appendingPathComponent(".venv/bin/python"),
    leadingArguments: ["-c", script]
)
let texto = try await runner.convert(fileURL: arquivo) { _ in }
XCTAssertEqual(texto, String(repeating: "Revisão do catálogo em São Paulo.\n", count: 8192) + "Fim.")
```

- [x] Testar também stderr volumoso antes de stdout. Enviar 262.144 bytes e uma quebra de linha a stderr, depois `{"error_code":"corrupted_file","user_message":"Falha de leitura."}` e terminar com código 4. Exigir o erro específico `.corruptedFile("Falha de leitura.")`. Em outro teste, invocar o callback de cancelamento assim que registrado num worker que aguarda com `signal.pause()` e usa alarme de segurança. Verificar retorno `.cancelled` antes do alarme. Preservar todas as asserções existentes.
- [x] Registrar o RED com `rtk proxy swift test --package-path macos --filter testWorkerStream`. O caso de stdout grande deve falhar pela ausência do Markdown integral.
- [x] **GREEN.** Iniciar `Process` com os dois pipes. Registrar a ação de cancelamento após `run()` bem-sucedido, para que um cancelamento já solicitado encontre o filho em execução. Usar uma única solicitação de término. Ler cada descritor em fila concorrente enquanto o filho executa. Esperar EOF dos dois e a saída do processo fora da thread da interface. Aplicar o mapeamento existente de sinal, código, erro JSON e Markdown vazio. Manter um único caminho de retorno por execução, inclusive falha de lançamento.

```swift
private static func drain(_ reader: FileHandle) async -> Data {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: reader.readDataToEndOfFile())
        }
    }
}
// Após iniciar o processo e registrar seu cancelamento:
async let stdout = Self.drain(stdoutPipe.fileHandleForReading)
async let stderr = Self.drain(stderrPipe.fileHandleForReading)
let (outData, errData) = await (stdout, stderr)
```

- [x] **Aceite do executor.** `rtk proxy swift test --package-path macos --filter MarkItDownMacCoreTests`. Esperado: todos os casos existentes e novos executados, zero falhas, exit 0.

## Revisão e entrega neste Mac

- [x] Conferir cinco condições: saída extensa integral, diagnóstico extenso com erro útil, cancelamento durante a partida, término normal com ambos os canais e falha ao iniciar o executável. Para a última, acrescentar a T1 um teste com URL de executável inexistente e exigir a mensagem de inicialização já definida no runner.
- [x] Replanejar se for necessário mudar contrato público, dependências, política de arquivos temporários ou permissões do app. Aplicar os seis gatilhos do contrato de handoff do orquestrador.
- [x] Executar `rtk proxy bash macos/scripts/build_app.sh`, depois `rtk proxy swift test --package-path macos`, `rtk proxy .venv/bin/python -m pytest -q macos/worker/tests`, `rtk proxy .venv/bin/python -m ruff check macos/worker` e `rtk proxy .venv/bin/python -m mypy --ignore-missing-imports macos/worker/markitdown_macos_worker.py`. Todos devem retornar zero. Revisar o diff e validar a assinatura.
- [x] Preservar o bundle anterior até verificar o novo em Aplicativos. Antes de encerrar uma sessão com documentos reais, preservar o trabalho do usuário. Abrir a nova janela, importar o catálogo e o resumo, verificar a seleção e a continuidade da fila, salvar o catálogo e comparar os bytes com a saída do worker para o mesmo arquivo. Executar o entrypoint instalado `--smoke-test` com rede IP bloqueada e sem Python do usuário no PATH. Esperar `SMOKE_TEST_OK` e exit 0.
- [x] Registrar o resultado em `changelog/changelog_v0.1.9_2026-11-25_conversao-documentos-extensos.md` e concluir o commit local segundo a lei do projeto.

## Resultado em 25/11/2026

O teste de regressão inicial executou quatro casos. Três falharam no código anterior, incluindo o cancelamento que levou 8,05 segundos. A falha de lançamento já retornava a mensagem esperada. Após a correção, a revisão executou os dez testes de núcleo com sucesso. Nenhum escalonamento foi necessário.

O build Release, a validação da assinatura, os 15 testes Swift, os 13 testes do worker, Ruff e mypy retornaram código zero. O bundle instalado em Aplicativos retornou `SMOKE_TEST_OK` para Office e scan com rede IP bloqueada no processo e seus filhos.

No worker da versão instalada, os casos de DOCX, XLSX, PPTX e PDF textual também passaram com rede IP bloqueada. Um teste isolado exercitou o manipulador de arraste com dois `NSItemProvider` reais do tipo URL de arquivo, em fila vazia e ocupada. Os dois resultados coincidiram com os arquivos exportados e o app preservou a seleção. A inspeção de acessibilidade confirmou rótulos de itens, estados e ações na janela. O gesto físico entre janelas e a fala do VoiceOver não foram validados nesta rodada.

Pelo seletor nativo, o catálogo e o resumo concluíram em sequência e o primeiro permaneceu selecionado. Os 110.023 bytes exportados do catálogo coincidiram integralmente com a área de transferência e com a saída direta do worker. SHA-256 `ad1e721407b90277b948cdfee47d4f6f4adf03f7c5266d969b8236199970b08d`. O painel pediu confirmação para substituir o arquivo. Cancelar preservou o resultado.

A troca dos bundles foi atômica. Ambas as assinaturas passaram na verificação após a troca. O executável anterior conservou o SHA-256 `30a6a71a46b2977c0efa7fde1a5d8ef4be2cac0c4dcbca690ca695babd28ddfc` no backup local. O app atualizado reabriu com a fila vazia.
