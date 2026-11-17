import AppKit
import MarkItDownMacCore
import SwiftUI
import UniformTypeIdentifiers

@main
struct MarkItDownMacApp: App {
    @StateObject private var queue = ConversionQueueManager()

    init() {
        let args = CommandLine.arguments
        if let smokeIndex = args.firstIndex(of: "--smoke-test") {
            let customDir = (smokeIndex + 1 < args.count) ? args[smokeIndex + 1] : nil
            Self.runSmokeTestAndExit(customDirectoryPath: customDir)
        }
    }

    var body: some Scene {
        WindowGroup("MarkItDown") {
            MarkItDownWorkspaceView(
                queue: queue,
                onRequestAddFiles: presentOpenFilesPanel,
                onRequestSaveSelected: presentSaveMarkdownPanel
            )
            .frame(
                minWidth: MarkItDownWindowLayout.minWidth,
                idealWidth: MarkItDownWindowLayout.initialWidth,
                minHeight: MarkItDownWindowLayout.minHeight,
                idealHeight: MarkItDownWindowLayout.initialHeight
            )
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(action: presentOpenFilesPanel) {
                        Label("Adicionar arquivos…", systemImage: "plus")
                    }
                    .help("Adicionar arquivos para converter (⌘O)")
                    .accessibilityLabel("Adicionar arquivos")
                }
            }
        }
        .defaultSize(
            width: MarkItDownWindowLayout.initialWidth,
            height: MarkItDownWindowLayout.initialHeight
        )
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Adicionar arquivos…") {
                    presentOpenFilesPanel()
                }
                .keyboardShortcut("o", modifiers: [.command])
            }
            CommandGroup( replacing: .saveItem) {
                Button("Salvar Markdown…") {
                    presentSaveMarkdownPanel()
                }
                .keyboardShortcut("s", modifiers: [.command])
                .disabled(!(queue.selectedItem?.canCopyAndExport ?? false))
            }
        }
    }

    @MainActor
    private func presentOpenFilesPanel() {
        let panel = NSOpenPanel()
        panel.title = "Adicionar arquivos"
        panel.prompt = "Adicionar"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = SupportedInputFormat.acceptedContentTypes

        if panel.runModal() == .OK, !panel.urls.isEmpty {
            queue.enqueue(urls: panel.urls)
        }
    }

    @MainActor
    private func presentSaveMarkdownPanel() {
        // Bind the save action to the result selected at the moment the panel opens
        guard let snapshot = queue.exportSnapshotForSelection() else { return }

        let panel = NSSavePanel()
        panel.title = "Salvar Markdown"
        panel.prompt = "Salvar"
        panel.nameFieldStringValue = snapshot.suggestedFileName
        panel.canCreateDirectories = true
        if let mdType = UTType(filenameExtension: "md") {
            panel.allowedContentTypes = [mdType, .plainText]
        } else {
            panel.allowedContentTypes = [.plainText]
        }

        if panel.runModal() == .OK, let destinationURL = panel.url {
            try? queue.saveMarkdown(snapshot, to: destinationURL)
        }
    }

    private static func runSmokeTestAndExit(customDirectoryPath: String?) -> Never {
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task { @MainActor in
            do {
                let workDir: URL
                let shouldCleanup: Bool
                if let customDirectoryPath {
                    workDir = URL(fileURLWithPath: customDirectoryPath, isDirectory: true)
                    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                    shouldCleanup = false
                } else {
                    workDir = FileManager.default.temporaryDirectory
                        .appendingPathComponent("markitdown-smoke-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                    shouldCleanup = true
                }
                defer {
                    if shouldCleanup {
                        try? FileManager.default.removeItem(at: workDir)
                    }
                }

                // 1. Create synthetic DOCX (Office) and PNG scan (OCR)
                let docxURL = workDir.appendingPathComponent("smoke-office.docx")
                try SmokeFixtureBuilder.writeMinimalDocx(
                    at: docxURL,
                    heading: "Smoke Test macOS",
                    paragraph: "Conversão local de arquivo Office concluída sem rede."
                )

                let scanURL = workDir.appendingPathComponent("smoke-scan.png")
                try SmokeFixtureBuilder.writeScanPNG(
                    at: scanURL,
                    text: "Reconhecimento óptico local validado no macOS"
                )

                // 2. Run both through ConversionQueueManager and render MarkItDownWorkspaceView
                let queue = ConversionQueueManager()
                let hosting = NSHostingView(
                    rootView: MarkItDownWorkspaceView(
                        queue: queue,
                        onRequestAddFiles: {},
                        onRequestSaveSelected: {}
                    )
                )
                hosting.frame = NSRect(x: 0, y: 0, width: 960, height: 640)
                hosting.layoutSubtreeIfNeeded()

                queue.enqueue(urls: [docxURL, scanURL])
                await queue.waitForIdle()
                hosting.layoutSubtreeIfNeeded()

                guard queue.items.count == 2 else {
                    throw NSError(domain: "SmokeTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 2 items in queue"])
                }

                for item in queue.items {
                    guard item.state == .completed, item.canCopyAndExport else {
                        throw NSError(
                            domain: "SmokeTest",
                            code: 2,
                            userInfo: [NSLocalizedDescriptionKey: "Item \(item.fileName) did not complete: \(item.state)"]
                        )
                    }
                    guard let snap = queue.exportSnapshot(for: item.id) else {
                        throw NSError(domain: "SmokeTest", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing snapshot"])
                    }
                    let outURL = workDir.appendingPathComponent(snap.suggestedFileName)
                    try queue.saveMarkdown(snap, to: outURL)
                    let saved = try String(contentsOf: outURL, encoding: .utf8)
                    guard !saved.isEmpty else {
                        throw NSError(domain: "SmokeTest", code: 4, userInfo: [NSLocalizedDescriptionKey: "Empty exported file"])
                    }
                }

                print("SMOKE_TEST_OK: converted and exported \(queue.items.count) files (Office + OCR scan)")
            } catch {
                fputs("SMOKE_TEST_FAILED: \(error.localizedDescription)\n", stderr)
                exitCode = 1
            }
            semaphore.signal()
        }

        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.current.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        Foundation.exit(exitCode)
    }
}

private enum SmokeFixtureBuilder {
    static func writeMinimalDocx(at url: URL, heading: String, paragraph: String) throws {
        let documentXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>
            <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>\(heading)</w:t></w:r></w:p>
            <w:p><w:r><w:t>\(paragraph)</w:t></w:r></w:p>
          </w:body>
        </w:document>
        """
        let contentTypesXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
        """
        let relsXML = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
        """

        let tempZipDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx-build-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempZipDir.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempZipDir.appendingPathComponent("word"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempZipDir) }

        try Data(contentTypesXML.utf8).write(to: tempZipDir.appendingPathComponent("[Content_Types].xml"))
        try Data(relsXML.utf8).write(to: tempZipDir.appendingPathComponent("_rels/.rels"))
        try Data(documentXML.utf8).write(to: tempZipDir.appendingPathComponent("word/document.xml"))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        proc.currentDirectoryURL = tempZipDir
        proc.arguments = ["-q", "-r", url.path, "[Content_Types].xml", "_rels", "word"]
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw NSError(domain: "SmokeFixtureBuilder", code: Int(proc.terminationStatus))
        }
    }

    static func writeScanPNG(at url: URL, text: String) throws {
        let size = NSSize(width: 1200, height: 320)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
            .foregroundColor: NSColor.black
        ]
        NSString(string: text).draw(in: NSRect(x: 48, y: 90, width: 1100, height: 180), withAttributes: attrs)
        image.unlockFocus()

        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let pngData = rep.representation(using: .png, properties: [:])
        else {
            throw NSError(domain: "SmokeFixtureBuilder", code: 2)
        }
        try pngData.write(to: url, options: .atomic)
    }
}
