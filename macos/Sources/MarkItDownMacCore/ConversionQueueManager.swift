import AppKit
import Combine
import Foundation

private final class ActiveJobCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var terminateAction: (@Sendable () -> Void)?

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func setTerminateAction(_ action: @escaping @Sendable () -> Void) {
        var shouldRunImmediately = false
        lock.lock()
        if cancelled {
            shouldRunImmediately = true
        } else {
            terminateAction = action
        }
        lock.unlock()

        if shouldRunImmediately {
            action()
        }
    }

    func cancel() {
        let action: (@Sendable () -> Void)?
        lock.lock()
        cancelled = true
        action = terminateAction
        terminateAction = nil
        lock.unlock()
        action?()
    }
}

@MainActor
public final class ConversionQueueManager: ObservableObject {
    @Published public private(set) var items: [ConversionQueueItem] = []
    @Published public var selectedItemID: UUID?
    @Published public private(set) var copyFeedbackItemID: UUID?
    @Published public private(set) var saveFeedbackItemID: UUID?
    @Published public var saveErrorMessage: String?
    @Published public private(set) var accessibilityAnnouncement: String?

    private let workerRunner: DocumentWorkerRunning
    private let ocrService: OCRRecognizing
    private var isProcessingLoopRunning = false
    private var activeItemID: UUID?
    private var activeTask: Task<ConversionOutput, Error>?
    private var activeToken: ActiveJobCancellationToken?
    private var idleContinuations: [CheckedContinuation<Void, Never>] = []

    public init(
        workerRunner: DocumentWorkerRunning = SubprocessPythonWorkerRunner(),
        ocrService: OCRRecognizing = AppleVisionOCRService()
    ) {
        self.workerRunner = workerRunner
        self.ocrService = ocrService
    }

    public var selectedItem: ConversionQueueItem? {
        guard let selectedItemID else { return nil }
        return items.first { $0.id == selectedItemID }
    }

    public var disambiguatingFoldersByItemID: [UUID: String] {
        PathDisambiguator.disambiguatingFolders(for: items)
    }

    public func disambiguatingFolder(for item: ConversionQueueItem) -> String? {
        disambiguatingFoldersByItemID[item.id]
    }

    public func voiceOverLabel(for item: ConversionQueueItem) -> String {
        PathDisambiguator.voiceOverLabel(
            for: item,
            disambiguatingFolder: disambiguatingFolder(for: item)
        )
    }

    public func enqueue(urls: [URL]) {
        guard !urls.isEmpty else { return }
        let wasEmpty = items.isEmpty

        let newItems = urls.map { ConversionQueueItem(fileURL: $0) }
        items.append(contentsOf: newItems)

        if wasEmpty, let first = newItems.first {
            selectedItemID = first.id
        }

        startProcessingLoopIfNeeded()
    }

    public func cancel(itemID: UUID) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }

        switch items[index].state {
        case .queued:
            items[index].state = .cancelled
            items[index].markdown = nil
        case .converting:
            items[index].state = .cancelling
            if activeItemID == itemID {
                activeToken?.cancel()
                activeTask?.cancel()
            }
        case .cancelling, .completed, .completedWithWarnings, .failed, .cancelled:
            break
        }
    }

    public func copySelectedMarkdownToPasteboard() -> Bool {
        guard let item = selectedItem, item.canCopyAndExport, let markdown = item.markdown else {
            return false
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(markdown, forType: .string)
        if ok {
            copyFeedbackItemID = item.id
        }
        return ok
    }

    public func exportSnapshotForSelection() -> ExportSnapshot? {
        exportSnapshot(for: selectedItemID)
    }

    public func exportSnapshot(for itemID: UUID?) -> ExportSnapshot? {
        guard
            let itemID,
            let item = items.first(where: { $0.id == itemID }),
            item.canCopyAndExport,
            let markdown = item.markdown
        else {
            return nil
        }
        return ExportSnapshot(
            itemID: item.id,
            sourceFileName: item.fileName,
            suggestedFileName: item.suggestedExportFileName,
            markdown: markdown
        )
    }

    public func saveMarkdown(_ snapshot: ExportSnapshot, to destinationURL: URL) throws {
        saveErrorMessage = nil
        let didAccess = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }

        guard let data = snapshot.markdown.data(using: .utf8) else {
            let err = ConversionDomainError.corruptedFile("Não foi possível codificar o Markdown em UTF-8.")
            saveErrorMessage = err.userMessage
            throw err
        }

        do {
            try data.write(to: destinationURL, options: .atomic)
            saveFeedbackItemID = snapshot.itemID
        } catch {
            saveErrorMessage = "Não foi possível salvar em \"\(destinationURL.lastPathComponent)\". Escolha outro destino e tente novamente."
            throw error
        }
    }

    public func waitForIdle() async {
        if !isProcessingLoopRunning && !items.contains(where: { $0.state == .queued || $0.state.isConverting || $0.state == .cancelling }) {
            return
        }
        await withCheckedContinuation { continuation in
            idleContinuations.append(continuation)
        }
    }

    private func startProcessingLoopIfNeeded() {
        guard !isProcessingLoopRunning else { return }
        isProcessingLoopRunning = true

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runQueueLoop()
        }
    }

    private func runQueueLoop() async {
        while let nextIndex = items.firstIndex(where: { $0.state == .queued }) {
            let item = items[nextIndex]
            let itemID = item.id
            let fileURL = item.fileURL

            // Validate format before starting converter
            guard let format = SupportedInputFormat.detect(from: fileURL) else {
                updateItem(id: itemID) { entry in
                    entry.state = .failed(message: ConversionDomainError.unsupportedFormat.userMessage)
                    entry.markdown = nil
                }
                continue
            }

            let token = ActiveJobCancellationToken()
            activeItemID = itemID
            activeToken = token

            updateItem(id: itemID) { entry in
                entry.state = .converting(progressText: nil)
            }

            let workerRunner = self.workerRunner
            let ocrService = self.ocrService
            let progressCallback: @Sendable (Int, Int) -> Void = { [weak self] current, total in
                Task { @MainActor in
                    self?.updateProgressIfConverting(
                        itemID: itemID,
                        progressText: "Lendo página \(current) de \(total)"
                    )
                }
            }

            let task = Task.detached(priority: .userInitiated) { () throws -> ConversionOutput in
                if token.isCancelled || Task.isCancelled {
                    throw ConversionDomainError.cancelled
                }

                switch format {
                case .docx, .xlsx, .pptx:
                    let markdown = try await workerRunner.convert(fileURL: fileURL) { terminate in
                        token.setTerminateAction(terminate)
                    }
                    return ConversionOutput(markdown: markdown, ocrApplied: false, emptyPageNumbers: [])

                case .png, .jpeg:
                    let text = try ocrService.recognizeImageFile(at: fileURL)
                    return ConversionOutput(markdown: text, ocrApplied: true, emptyPageNumbers: [])

                case .pdf:
                    let router = PDFConversionRouter(workerRunner: workerRunner, ocrService: ocrService)
                    return try await router.convertPDF(
                        at: fileURL,
                        isCancelled: { token.isCancelled },
                        onPageProgress: progressCallback,
                        onTerminationHandler: { terminate in
                            token.setTerminateAction(terminate)
                        }
                    )
                }
            }

            activeTask = task
            let result = await task.result

            activeTask = nil
            activeToken = nil
            activeItemID = nil

            // Discard late results if the item was cancelled while active
            if token.isCancelled || items.first(where: { $0.id == itemID })?.state == .cancelling {
                updateItem(id: itemID) { entry in
                    entry.state = .cancelled
                    entry.markdown = nil
                    entry.ocrApplied = false
                    entry.emptyPageNumbers = []
                }
                continue
            }

            switch result {
            case .success(let output):
                updateItem(id: itemID) { entry in
                    entry.markdown = output.markdown
                    entry.ocrApplied = output.ocrApplied
                    entry.emptyPageNumbers = output.emptyPageNumbers
                    entry.state = output.emptyPageNumbers.isEmpty ? .completed : .completedWithWarnings
                }
            case .failure(let error):
                if let domainError = error as? ConversionDomainError, domainError == .cancelled {
                    updateItem(id: itemID) { entry in
                        entry.state = .cancelled
                        entry.markdown = nil
                    }
                } else if error is CancellationError {
                    updateItem(id: itemID) { entry in
                        entry.state = .cancelled
                        entry.markdown = nil
                    }
                } else {
                    let message = (error as? ConversionDomainError)?.userMessage
                        ?? "Arquivo corrompido ou ilegível. Verifique o documento de origem."
                    updateItem(id: itemID) { entry in
                        entry.state = .failed(message: message)
                        entry.markdown = nil
                    }
                }
            }
        }

        isProcessingLoopRunning = false
        let continuations = idleContinuations
        idleContinuations.removeAll()
        for continuation in continuations {
            continuation.resume()
        }
    }

    private func updateProgressIfConverting(itemID: UUID, progressText: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        if case .converting = items[index].state {
            items[index].state = .converting(progressText: progressText)
        }
    }

    private func updateItem(id: UUID, mutation: (inout ConversionQueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        mutation(&items[index])

        if selectedItemID == id, items[index].state.isTerminal {
            let announcement = "\(items[index].fileName): \(items[index].state.panelHeaderStatusTitle)"
            accessibilityAnnouncement = announcement
            if let app = NSApp {
                NSAccessibility.post(
                    element: app,
                    notification: .announcementRequested,
                    userInfo: [
                        .announcement: announcement,
                        .priority: NSAccessibilityPriorityLevel.high.rawValue
                    ]
                )
            }
        }
    }
}
