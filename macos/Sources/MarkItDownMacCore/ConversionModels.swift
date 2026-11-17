import Foundation
import UniformTypeIdentifiers

public enum SupportedInputFormat: String, CaseIterable, Sendable {
    case docx
    case xlsx
    case pptx
    case pdf
    case png
    case jpeg

    public static let acceptedExtensions: Set<String> = [
        "docx", "xlsx", "pptx", "pdf", "png", "jpg", "jpeg"
    ]

    public static var acceptedContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .png, .jpeg]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        if let pptx = UTType(filenameExtension: "pptx") { types.append(pptx) }
        return types
    }

    public static func detect(from url: URL) -> SupportedInputFormat? {
        switch url.pathExtension.lowercased() {
        case "docx":
            return .docx
        case "xlsx":
            return .xlsx
        case "pptx":
            return .pptx
        case "pdf":
            return .pdf
        case "png":
            return .png
        case "jpg", "jpeg":
            return .jpeg
        default:
            return nil
        }
    }

    public var isImage: Bool {
        switch self {
        case .png, .jpeg:
            return true
        case .docx, .xlsx, .pptx, .pdf:
            return false
        }
    }

    public var isOffice: Bool {
        switch self {
        case .docx, .xlsx, .pptx:
            return true
        case .pdf, .png, .jpeg:
            return false
        }
    }
}

public enum ConversionItemState: Equatable, Sendable {
    case queued
    case converting(progressText: String?)
    case cancelling
    case completed
    case completedWithWarnings
    case failed(message: String)
    case cancelled

    public var listStatusTitle: String {
        switch self {
        case .queued:
            return "Em fila"
        case .converting(let progressText):
            return progressText ?? "Convertendo"
        case .cancelling:
            return "Cancelando…"
        case .completed:
            return "Concluído"
        case .completedWithWarnings:
            return "Com avisos"
        case .failed:
            return "Falhou"
        case .cancelled:
            return "Cancelado"
        }
    }

    public var panelHeaderStatusTitle: String {
        switch self {
        case .queued:
            return "Em fila"
        case .converting(let progressText):
            return progressText ?? "Convertendo"
        case .cancelling:
            return "Cancelando…"
        case .completed:
            return "Concluído"
        case .completedWithWarnings:
            return "Concluído com avisos"
        case .failed:
            return "Falhou"
        case .cancelled:
            return "Cancelado"
        }
    }

    public var failureMessage: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }

    public var isConverting: Bool {
        if case .converting = self { return true }
        return false
    }

    public var canCancel: Bool {
        switch self {
        case .queued, .converting:
            return true
        case .cancelling, .completed, .completedWithWarnings, .failed, .cancelled:
            return false
        }
    }

    public var isTerminal: Bool {
        switch self {
        case .completed, .completedWithWarnings, .failed, .cancelled:
            return true
        case .queued, .converting, .cancelling:
            return false
        }
    }
}

public struct ConversionQueueItem: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let fileURL: URL
    public let fileName: String
    public var state: ConversionItemState
    public var markdown: String?
    public var ocrApplied: Bool
    public var emptyPageNumbers: [Int]

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        state: ConversionItemState = .queued,
        markdown: String? = nil,
        ocrApplied: Bool = false,
        emptyPageNumbers: [Int] = []
    ) {
        self.id = id
        self.fileURL = fileURL
        self.fileName = fileURL.lastPathComponent
        self.state = state
        self.markdown = markdown
        self.ocrApplied = ocrApplied
        self.emptyPageNumbers = emptyPageNumbers
    }

    public var canCopyAndExport: Bool {
        guard state == .completed || state == .completedWithWarnings else {
            return false
        }
        guard let markdown else { return false }
        return !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var suggestedExportFileName: String {
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let sanitized = baseName.isEmpty ? "documento" : baseName
        return "\(sanitized).md"
    }

    public var panelNotice: String? {
        guard state == .completed || state == .completedWithWarnings else {
            return nil
        }

        let missingClause: String?
        if emptyPageNumbers.count == 1, let page = emptyPageNumbers.first {
            missingClause = "Página \(page) sem texto."
        } else if emptyPageNumbers.count > 1 {
            let pagesList = emptyPageNumbers.map(String.init).joined(separator: ", ")
            missingClause = "Páginas \(pagesList) sem texto."
        } else {
            missingClause = nil
        }

        if ocrApplied, let missingClause {
            return "OCR aplicado. \(missingClause)"
        } else if ocrApplied {
            return "OCR aplicado."
        } else if let missingClause {
            return missingClause
        }
        return nil
    }
}

public struct ExportSnapshot: Equatable, Sendable {
    public let itemID: UUID
    public let sourceFileName: String
    public let suggestedFileName: String
    public let markdown: String

    public init(itemID: UUID, sourceFileName: String, suggestedFileName: String, markdown: String) {
        self.itemID = itemID
        self.sourceFileName = sourceFileName
        self.suggestedFileName = suggestedFileName
        self.markdown = markdown
    }
}

public enum ConversionDomainError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat
    case fileUnreadable
    case pdfLocked
    case corruptedFile(String)
    case emptyOutput
    case cancelled

    public var errorDescription: String? {
        userMessage
    }

    public var userMessage: String {
        switch self {
        case .unsupportedFormat:
            return "Formato não suportado. Adicione arquivos DOCX, XLSX, PPTX, PDF, PNG ou JPEG."
        case .fileUnreadable:
            return "Não foi possível ler o arquivo selecionado. Verifique as permissões e tente novamente."
        case .pdfLocked:
            return "PDF protegido por senha. Adicione uma cópia desbloqueada."
        case .corruptedFile(let custom):
            return custom.isEmpty
                ? "Arquivo corrompido ou ilegível. Verifique se o documento abre no aplicativo de origem."
                : custom
        case .emptyOutput:
            return "Nenhum texto reconhecido"
        case .cancelled:
            return "Conversão cancelada."
        }
    }
}

public enum PathDisambiguator {
    public static func disambiguatingFolders(for items: [ConversionQueueItem]) -> [UUID: String] {
        var groups: [String: [ConversionQueueItem]] = [:]
        for item in items {
            groups[item.fileName.lowercased(), default: []].append(item)
        }

        var result: [UUID: String] = [:]
        for (_, group) in groups where group.count > 1 {
            let parentLists: [(UUID, [String])] = group.map { item in
                let components = item.fileURL
                    .standardizedFileURL
                    .deletingLastPathComponent()
                    .pathComponents
                    .filter { $0 != "/" }
                return (item.id, components)
            }

            for (itemID, components) in parentLists {
                guard !components.isEmpty else { continue }
                var chosenSuffix = components.last ?? ""
                for depth in 1...components.count {
                    let candidate = components.suffix(depth).joined(separator: "/")
                    let collisions = parentLists.filter { otherID, otherComponents in
                        otherID != itemID && otherComponents.suffix(depth).joined(separator: "/") == candidate
                    }
                    chosenSuffix = candidate
                    if collisions.isEmpty {
                        break
                    }
                }
                result[itemID] = chosenSuffix
            }
        }
        return result
    }

    public static func voiceOverLabel(
        for item: ConversionQueueItem,
        disambiguatingFolder: String?
    ) -> String {
        var parts: [String] = [item.fileName]
        if let folder = disambiguatingFolder, !folder.isEmpty {
            parts.append("pasta \(folder)")
        }
        parts.append(item.state.listStatusTitle)
        if let failure = item.state.failureMessage {
            parts.append(failure)
        }
        return parts.joined(separator: ", ")
    }
}
