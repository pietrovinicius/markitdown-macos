import AppKit
import Foundation
import PDFKit
import XCTest
@testable import MarkItDownMacCore

@MainActor
final class MarkItDownMacCoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("markitdown-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MarkItDownMacTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // macos
            .deletingLastPathComponent() // repo root
    }

    private func makeDefaultWorkerRunner() -> SubprocessPythonWorkerRunner {
        let root = repoRootURL()
        let pythonURL = root.appendingPathComponent(".venv/bin/python")
        let scriptURL = root.appendingPathComponent("macos/worker/markitdown_macos_worker.py")
        return SubprocessPythonWorkerRunner(
            executableURL: pythonURL,
            leadingArguments: [scriptURL.path]
        )
    }

    func testWorkerStreamPreservesLargeStdoutAndDrainsStderr() async throws {
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
    }

    func testWorkerStreamMapsFailureAfterLargeStderr() async throws {
        let arquivo = tempDir.appendingPathComponent("entrada.docx")
        try Data("amostra".utf8).write(to: arquivo)
        let script = """
        import signal, sys
        signal.alarm(8)
        sys.stderr.buffer.write(b"." * 262144 + b"\\n")
        sys.stderr.buffer.write(b'{"error_code":"corrupted_file","user_message":"Falha de leitura."}\\n')
        sys.stderr.buffer.flush()
        sys.exit(4)
        """
        let runner = SubprocessPythonWorkerRunner(
            executableURL: repoRootURL().appendingPathComponent(".venv/bin/python"),
            leadingArguments: ["-c", script]
        )

        do {
            _ = try await runner.convert(fileURL: arquivo) { _ in }
            XCTFail("Esperava erro de arquivo corrompido")
        } catch let error as ConversionDomainError {
            guard case .corruptedFile("Falha de leitura.") = error else {
                return XCTFail("Erro inesperado: \(error)")
            }
        }
    }

    func testWorkerStreamCancelsWhenExecutionCancellationIsRegistered() async throws {
        let arquivo = tempDir.appendingPathComponent("entrada.docx")
        try Data("amostra".utf8).write(to: arquivo)
        let script = """
        import signal
        signal.alarm(8)
        signal.pause()
        """
        let runner = SubprocessPythonWorkerRunner(
            executableURL: repoRootURL().appendingPathComponent(".venv/bin/python"),
            leadingArguments: ["-c", script]
        )
        let inicio = Date()

        do {
            _ = try await runner.convert(fileURL: arquivo) { terminate in terminate() }
            XCTFail("Esperava cancelamento")
        } catch let error as ConversionDomainError {
            guard case .cancelled = error else {
                return XCTFail("Erro inesperado: \(error)")
            }
        }

        XCTAssertLessThan(Date().timeIntervalSince(inicio), 6)
    }

    func testWorkerStreamKeepsLaunchFailureMessage() async throws {
        let arquivo = tempDir.appendingPathComponent("entrada.docx")
        try Data("amostra".utf8).write(to: arquivo)
        let runner = SubprocessPythonWorkerRunner(
            executableURL: tempDir.appendingPathComponent("missing-python"),
            leadingArguments: ["-c", "pass"]
        )

        do {
            _ = try await runner.convert(fileURL: arquivo) { _ in }
            XCTFail("Esperava falha de inicialização")
        } catch let error as ConversionDomainError {
            guard case .corruptedFile("Não foi possível iniciar o conversor local.") = error else {
                return XCTFail("Erro inesperado: \(error)")
            }
        }
    }

    private func generateOfficeFixtures(in directory: URL) throws {
        let root = repoRootURL()
        let pythonURL = root.appendingPathComponent(".venv/bin/python")
        let script = """
        import pathlib, sys, zipfile, openpyxl, pptx
        out = pathlib.Path(sys.argv[1])

        # DOCX with Heading and accented PT-BR text
        docx_path = out / "ata-reuniao.docx"
        doc_xml = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
            '<w:body>'
            '<w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Ata de Reunião</w:t></w:r></w:p>'
            '<w:p><w:r><w:t>Deliberação aprovada em São Paulo com revisão técnica.</w:t></w:r></w:p>'
            '</w:body></w:document>'
        )
        ct_xml = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
            '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
            '<Default Extension="xml" ContentType="application/xml"/>'
            '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
            '</Types>'
        )
        rels_xml = (
            '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
            '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
            '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
            '</Relationships>'
        )
        with zipfile.ZipFile(docx_path, "w", zipfile.ZIP_DEFLATED) as zf:
            zf.writestr("[Content_Types].xml", ct_xml)
            zf.writestr("_rels/.rels", rels_xml)
            zf.writestr("word/document.xml", doc_xml)

        # XLSX
        wb = openpyxl.Workbook()
        ws = wb.active
        ws.title = "Orçamento"
        ws.append(["Categoria", "Descrição", "Total"])
        ws.append(["Infraestrutura", "Operação local macOS", 4200])
        wb.save(out / "orcamento.xlsx")

        # PPTX
        prs = pptx.Presentation()
        slide = prs.slides.add_slide(prs.slide_layouts[0])
        slide.shapes.title.text = "Revisão de Arquitetura"
        slide.placeholders[1].text = "Processamento offline garantido no dispositivo."
        prs.save(out / "apresentacao.pptx")
        """

        let proc = Process()
        proc.executableURL = pythonURL
        proc.arguments = ["-c", script, directory.path]
        try proc.run()
        proc.waitUntilExit()
        XCTAssertEqual(proc.terminationStatus, 0)
    }

    private func makeImageWithText(_ text: String, size: NSSize = NSSize(width: 1200, height: 320)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        if !text.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
            NSString(string: text).draw(
                in: NSRect(x: 48, y: 80, width: size.width - 96, height: size.height - 120),
                withAttributes: attrs
            )
        }
        image.unlockFocus()
        return image
    }

    private func writeImage(_ image: NSImage, to url: URL, fileType: NSBitmapImageRep.FileType) throws {
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let data = rep.representation(using: fileType, properties: [.compressionFactor: 0.95])
        else {
            XCTFail("Failed to encode image")
            return
        }
        try data.write(to: url, options: .atomic)
    }

    private func createTextualPDF(at url: URL, pages: [String], password: String? = nil) throws {
        let pdfData = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard
            let consumer = CGDataConsumer(data: pdfData as CFMutableData),
            let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)
        else {
            XCTFail("Could not create PDF context")
            return
        }

        for pageText in pages {
            context.beginPDFPage(nil)
            let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = nsContext
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18),
                .foregroundColor: NSColor.black
            ]
            NSString(string: pageText).draw(
                in: NSRect(x: 50, y: 650, width: 500, height: 100),
                withAttributes: attrs
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        if let password {
            guard let doc = PDFDocument(data: pdfData as Data) else {
                XCTFail("Failed to load generated PDF")
                return
            }
            let written = doc.write(
                to: url,
                withOptions: [
                    PDFDocumentWriteOption.userPasswordOption: password,
                    PDFDocumentWriteOption.ownerPasswordOption: password
                ]
            )
            XCTAssertTrue(written)
        } else {
            try (pdfData as Data).write(to: url, options: .atomic)
        }
    }

    private func makePDFPageFromImage(_ image: NSImage) throws -> PDFPage {
        guard let page = PDFPage(image: image) else {
            throw NSError(domain: "MarkItDownMacCoreTests", code: 1)
        }
        return page
    }

    private func normalizeForOCRComparison(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    func testConvertOfficeAndTextualPDFCorpus() async throws {
        try generateOfficeFixtures(in: tempDir)
        let pdfURL = tempDir.appendingPathComponent("documento-textual.pdf")
        try createTextualPDF(
            at: pdfURL,
            pages: ["Relatório Executivo de Operações em São Paulo 2026"]
        )

        let docxURL = tempDir.appendingPathComponent("ata-reuniao.docx")
        let xlsxURL = tempDir.appendingPathComponent("orcamento.xlsx")
        let pptxURL = tempDir.appendingPathComponent("apresentacao.pptx")

        let queue = ConversionQueueManager(workerRunner: makeDefaultWorkerRunner())
        queue.enqueue(urls: [docxURL, xlsxURL, pptxURL, pdfURL])
        await queue.waitForIdle()

        XCTAssertEqual(queue.items.count, 4)
        for item in queue.items {
            XCTAssertEqual(item.state, .completed, "Item \(item.fileName) failed with state \(item.state)")
            XCTAssertTrue(item.canCopyAndExport)
            XCTAssertFalse(item.ocrApplied)
        }

        XCTAssertTrue(queue.items[0].markdown?.contains("# Ata de Reunião") == true)
        XCTAssertTrue(queue.items[0].markdown?.contains("São Paulo") == true)
        XCTAssertTrue(queue.items[1].markdown?.contains("## Orçamento") == true)
        XCTAssertTrue(queue.items[1].markdown?.contains("Operação local macOS") == true)
        XCTAssertTrue(queue.items[2].markdown?.contains("# Revisão de Arquitetura") == true)
        XCTAssertTrue(queue.items[3].markdown?.contains("Relatório Executivo de Operações") == true)
    }

    func testConvertScansAndImagesInPortugueseAndEnglishWithVisionOCR() async throws {
        let ptPhrase = "Relatório financeiro aprovado pela diretoria em São Paulo"
        let enPhrase = "Quarterly operational review completed successfully"

        let pngURL = tempDir.appendingPathComponent("scan-pt.png")
        let jpgURL = tempDir.appendingPathComponent("scan-en.jpg")
        let scannedPDFURL = tempDir.appendingPathComponent("digitalizado.pdf")

        try writeImage(makeImageWithText(ptPhrase), to: pngURL, fileType: .png)
        try writeImage(makeImageWithText(enPhrase), to: jpgURL, fileType: .jpeg)

        let pdfDoc = PDFDocument()
        pdfDoc.insert(try makePDFPageFromImage(makeImageWithText(ptPhrase)), at: 0)
        pdfDoc.insert(try makePDFPageFromImage(makeImageWithText(enPhrase)), at: 1)
        XCTAssertTrue(pdfDoc.write(to: scannedPDFURL))

        let queue = ConversionQueueManager(workerRunner: makeDefaultWorkerRunner())
        queue.enqueue(urls: [pngURL, jpgURL, scannedPDFURL])
        await queue.waitForIdle()

        for item in queue.items {
            XCTAssertEqual(item.state, .completed)
            XCTAssertTrue(item.ocrApplied)
            XCTAssertEqual(item.panelNotice, "OCR aplicado.")
            XCTAssertTrue(item.canCopyAndExport)
        }

        let pngNorm = normalizeForOCRComparison(queue.items[0].markdown ?? "")
        XCTAssertTrue(pngNorm.contains("relatório financeiro aprovado"), "Got: \(pngNorm)")
        XCTAssertTrue(pngNorm.contains("são paulo"), "Got: \(pngNorm)")

        let jpgNorm = normalizeForOCRComparison(queue.items[1].markdown ?? "")
        XCTAssertTrue(jpgNorm.contains("quarterly operational review completed successfully"), "Got: \(jpgNorm)")

        let pdfMarkdown = queue.items[2].markdown ?? ""
        XCTAssertTrue(pdfMarkdown.contains("## Página 1"))
        XCTAssertTrue(pdfMarkdown.contains("## Página 2"))
        let pdfNorm = normalizeForOCRComparison(pdfMarkdown)
        XCTAssertTrue(pdfNorm.contains("são paulo"))
        XCTAssertTrue(pdfNorm.contains("quarterly operational review"))
    }

    func testConvertMixedPDFWithAndWithoutEmptyPage() async throws {
        let textualPDFURL = tempDir.appendingPathComponent("base-textual.pdf")
        try createTextualPDF(at: textualPDFURL, pages: ["Ata nativa da primeira página"])
        guard
            let baseDoc = PDFDocument(url: textualPDFURL),
            let page1 = baseDoc.page(at: 0)
        else {
            XCTFail("Missing textual page")
            return
        }

        let scanPage = try makePDFPageFromImage(makeImageWithText("Texto reconhecido na segunda página"))
        let blankPage = try makePDFPageFromImage(makeImageWithText(""))

        // Case 1: Mixed PDF with empty page 3 -> completedWithWarnings
        let mixedWithBlankURL = tempDir.appendingPathComponent("misto-com-vazia.pdf")
        let docWithBlank = PDFDocument()
        docWithBlank.insert(page1.copy() as! PDFPage, at: 0)
        docWithBlank.insert(scanPage.copy() as! PDFPage, at: 1)
        docWithBlank.insert(blankPage, at: 2)
        XCTAssertTrue(docWithBlank.write(to: mixedWithBlankURL))

        // Case 2: Same mixed PDF without the empty page -> completed without partial warning
        let mixedCompleteURL = tempDir.appendingPathComponent("misto-completo.pdf")
        let docComplete = PDFDocument()
        docComplete.insert(page1.copy() as! PDFPage, at: 0)
        docComplete.insert(scanPage.copy() as! PDFPage, at: 1)
        XCTAssertTrue(docComplete.write(to: mixedCompleteURL))

        let queue = ConversionQueueManager(workerRunner: makeDefaultWorkerRunner())
        queue.enqueue(urls: [mixedWithBlankURL, mixedCompleteURL])
        await queue.waitForIdle()

        let partialItem = queue.items[0]
        XCTAssertEqual(partialItem.state, .completedWithWarnings)
        XCTAssertEqual(partialItem.state.listStatusTitle, "Com avisos")
        XCTAssertEqual(partialItem.state.panelHeaderStatusTitle, "Concluído com avisos")
        XCTAssertEqual(partialItem.emptyPageNumbers, [3])
        XCTAssertEqual(partialItem.panelNotice, "OCR aplicado. Página 3 sem texto.")
        XCTAssertTrue(partialItem.canCopyAndExport)

        let partialMD = partialItem.markdown ?? ""
        let r1 = partialMD.range(of: "## Página 1")
        let r2 = partialMD.range(of: "## Página 2")
        XCTAssertNotNil(r1)
        XCTAssertNotNil(r2)
        if let r1, let r2 {
            XCTAssertLessThan(r1.lowerBound, r2.lowerBound)
        }
        XCTAssertFalse(partialMD.contains("## Página 3"))

        let fullItem = queue.items[1]
        XCTAssertEqual(fullItem.state, .completed)
        XCTAssertTrue(fullItem.emptyPageNumbers.isEmpty)
        XCTAssertEqual(fullItem.panelNotice, "OCR aplicado.")
    }

    func testBatchSelectionPreservationAndActiveCancellation() async throws {
        let slowFile1 = tempDir.appendingPathComponent("lento-1.docx")
        let fastFile2 = tempDir.appendingPathComponent("rapido-2.docx")
        try Data("placeholder".utf8).write(to: slowFile1)
        try Data("placeholder".utf8).write(to: fastFile2)

        let mockWorker = ControllableMockWorkerRunner()
        let queue = ConversionQueueManager(workerRunner: mockWorker)

        queue.enqueue(urls: [slowFile1, fastFile2])
        XCTAssertEqual(queue.selectedItemID, queue.items.first?.id)

        // User selects the second item while the first is converting
        let secondID = queue.items[1].id
        queue.selectedItemID = secondID

        // Wait until the first item starts converting
        await mockWorker.waitUntilFirstJobStarts()
        XCTAssertEqual(queue.selectedItemID, secondID)

        // Cancel the active first item while second item remains selected
        let firstID = queue.items[0].id
        queue.cancel(itemID: firstID)

        await queue.waitForIdle()

        XCTAssertEqual(queue.selectedItemID, secondID)
        XCTAssertEqual(queue.items[0].state, .cancelled)
        XCTAssertNil(queue.items[0].markdown)
        XCTAssertFalse(queue.items[0].canCopyAndExport)

        XCTAssertEqual(queue.items[1].state, .completed)
        XCTAssertEqual(queue.items[1].markdown, "# Convertido após cancelamento")
    }

    func testInvalidInputsAndEmptyTextProduceDistinctCausesAndQueueContinues() async throws {
        let corruptedDocx = tempDir.appendingPathComponent("corrompido.docx")
        try Data("nao e zip".utf8).write(to: corruptedDocx)

        let lockedPDF = tempDir.appendingPathComponent("protegido.pdf")
        try createTextualPDF(at: lockedPDF, pages: ["Segredo"], password: "123")

        let unknownFormat = tempDir.appendingPathComponent("script.xyz")
        try Data("conteudo".utf8).write(to: unknownFormat)

        let blankPNG = tempDir.appendingPathComponent("em-branco.png")
        try writeImage(makeImageWithText(""), to: blankPNG, fileType: .png)

        let validPDF = tempDir.appendingPathComponent("valido.pdf")
        try createTextualPDF(at: validPDF, pages: ["Documento válido processado na fila"])

        let queue = ConversionQueueManager(workerRunner: makeDefaultWorkerRunner())
        queue.enqueue(urls: [corruptedDocx, lockedPDF, unknownFormat, blankPNG, validPDF])
        await queue.waitForIdle()

        XCTAssertEqual(queue.items.count, 5)

        for idx in 0..<4 {
            XCTAssertFalse(queue.items[idx].canCopyAndExport)
            guard case .failed(let msg) = queue.items[idx].state else {
                XCTFail("Expected item \(idx) to fail, got \(queue.items[idx].state)")
                continue
            }
            switch idx {
            case 0:
                XCTAssertTrue(msg.localizedCaseInsensitiveContains("corrompido"), "Got: \(msg)")
            case 1:
                XCTAssertTrue(msg.localizedCaseInsensitiveContains("desbloqueada"), "Got: \(msg)")
            case 2:
                XCTAssertTrue(msg.localizedCaseInsensitiveContains("formato"), "Got: \(msg)")
            case 3:
                XCTAssertEqual(msg, "Nenhum texto reconhecido")
            default:
                break
            }
        }

        // Valid item at end of queue still converts
        XCTAssertEqual(queue.items[4].state, .completed)
        XCTAssertTrue(queue.items[4].canCopyAndExport)
        XCTAssertTrue(queue.items[4].markdown?.contains("Documento válido processado na fila") == true)
    }

    func testHomonymousFilesDisambiguationAndAtomicExport() async throws {
        let dirA = tempDir.appendingPathComponent("setor-a", isDirectory: true)
        let dirB = tempDir.appendingPathComponent("setor-b", isDirectory: true)
        try FileManager.default.createDirectory(at: dirA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dirB, withIntermediateDirectories: true)

        let pdfA = dirA.appendingPathComponent("relatorio.pdf")
        let pdfB = dirB.appendingPathComponent("relatorio.pdf")
        try createTextualPDF(at: pdfA, pages: ["Conteúdo exclusivo do Setor A"])
        try createTextualPDF(at: pdfB, pages: ["Conteúdo exclusivo do Setor B"])

        let queue = ConversionQueueManager(workerRunner: makeDefaultWorkerRunner())
        queue.enqueue(urls: [pdfA, pdfB])
        await queue.waitForIdle()

        let disambiguation = queue.disambiguatingFoldersByItemID
        XCTAssertEqual(disambiguation[queue.items[0].id], "setor-a")
        XCTAssertEqual(disambiguation[queue.items[1].id], "setor-b")

        let voA = queue.voiceOverLabel(for: queue.items[0])
        let voB = queue.voiceOverLabel(for: queue.items[1])
        XCTAssertTrue(voA.contains("setor-a"))
        XCTAssertTrue(voB.contains("setor-b"))

        // Export first item to destination
        queue.selectedItemID = queue.items[0].id
        guard let snapA = queue.exportSnapshotForSelection() else {
            XCTFail("Missing snapshot A")
            return
        }
        XCTAssertEqual(snapA.suggestedFileName, "relatorio.md")

        let exportDest = tempDir.appendingPathComponent("relatorio.md")
        try queue.saveMarkdown(snapA, to: exportDest)
        let savedFirst = try String(contentsOf: exportDest, encoding: .utf8)
        XCTAssertEqual(savedFirst, snapA.markdown)

        // Select second item, verify existing destination stays intact until saveMarkdown is called
        queue.selectedItemID = queue.items[1].id
        guard let snapB = queue.exportSnapshotForSelection() else {
            XCTFail("Missing snapshot B")
            return
        }
        XCTAssertEqual(try String(contentsOf: exportDest, encoding: .utf8), snapA.markdown)

        // Simulate failed write (directory path as target) -> session output remains intact
        let invalidDest = dirA // cannot atomically overwrite a directory with a file
        XCTAssertThrowsError(try queue.saveMarkdown(snapB, to: invalidDest))
        XCTAssertEqual(queue.items[1].markdown, snapB.markdown)

        // Confirm overwrite to exportDest
        try queue.saveMarkdown(snapB, to: exportDest)
        let savedSecond = try String(contentsOf: exportDest, encoding: .utf8)
        XCTAssertEqual(savedSecond, snapB.markdown)
        XCTAssertTrue(savedSecond.contains("Setor B"))
    }
}

private final class ControllableMockWorkerRunner: DocumentWorkerRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    private var firstStartedContinuation: CheckedContinuation<Void, Never>?
    private var hasFirstStarted = false

    func waitUntilFirstJobStarts() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if hasFirstStarted {
                lock.unlock()
                continuation.resume()
            } else {
                firstStartedContinuation = continuation
                lock.unlock()
            }
        }
    }

    private func recordCallStart() -> (Int, CheckedContinuation<Void, Never>?) {
        lock.lock()
        defer { lock.unlock() }
        callCount += 1
        let currentCall = callCount
        if currentCall == 1 {
            hasFirstStarted = true
            let cont = firstStartedContinuation
            firstStartedContinuation = nil
            return (currentCall, cont)
        }
        return (currentCall, nil)
    }

    func convert(
        fileURL: URL,
        onTerminationHandler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) async throws -> String {
        let (currentCall, cont) = recordCallStart()
        cont?.resume()

        if currentCall == 1 {
            return try await withTaskCancellationHandler {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                return "# Resultado tardio que deve ser descartado"
            } onCancel: {
                // Cancelled immediately
            }
        } else {
            return "# Convertido após cancelamento"
        }
    }
}
