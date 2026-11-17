import AppKit
import SwiftUI
import UniformTypeIdentifiers

public enum MarkItDownWindowLayout {
    public static let initialWidth: CGFloat = 960
    public static let initialHeight: CGFloat = 640
    public static let minWidth: CGFloat = 720
    public static let minHeight: CGFloat = 480
    public static let sidebarIdealWidth: CGFloat = 250
    public static let sidebarMinWidth: CGFloat = 220
    public static let sidebarMaxWidth: CGFloat = 320

    public static let spacingSmall: CGFloat = 8
    public static let spacingMedium: CGFloat = 16
    public static let spacingLarge: CGFloat = 24
}

public enum MarkItDownThemeContrast {
    public static func normalTextContrastRatio(appearanceName: NSAppearance.Name) -> Double {
        guard let appearance = NSAppearance(named: appearanceName) else {
            return 21.0
        }
        var fgRGB: (Double, Double, Double) = (0, 0, 0)
        var bgRGB: (Double, Double, Double) = (1, 1, 1)

        appearance.performAsCurrentDrawingAppearance {
            fgRGB = rgbComponents(of: NSColor.labelColor)
            bgRGB = rgbComponents(of: NSColor.textBackgroundColor)
        }

        let l1 = relativeLuminance(fgRGB)
        let l2 = relativeLuminance(bgRGB)
        let lighter = max(l1, l2)
        let darker = min(l1, l2)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func rgbComponents(of color: NSColor) -> (Double, Double, Double) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return (
            Double(converted.redComponent),
            Double(converted.greenComponent),
            Double(converted.blueComponent)
        )
    }

    private static func relativeLuminance(_ rgb: (Double, Double, Double)) -> Double {
        func channel(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(rgb.0) + 0.7152 * channel(rgb.1) + 0.0722 * channel(rgb.2)
    }
}

public struct MarkItDownWorkspaceView: View {
    @ObservedObject public var queue: ConversionQueueManager
    public let onRequestAddFiles: () -> Void
    public let onRequestSaveSelected: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isDropTargeted = false

    public init(
        queue: ConversionQueueManager,
        onRequestAddFiles: @escaping () -> Void,
        onRequestSaveSelected: @escaping () -> Void
    ) {
        self.queue = queue
        self.onRequestAddFiles = onRequestAddFiles
        self.onRequestSaveSelected = onRequestSaveSelected
    }

    public var body: some View {
        Group {
            if queue.items.isEmpty {
                EmptyQueueDropView(
                    isDropTargeted: isDropTargeted,
                    onRequestAddFiles: onRequestAddFiles
                )
            } else {
                HSplitView {
                    QueueSidebarView(queue: queue)
                        .frame(
                            minWidth: MarkItDownWindowLayout.sidebarMinWidth,
                            idealWidth: MarkItDownWindowLayout.sidebarIdealWidth,
                            maxWidth: MarkItDownWindowLayout.sidebarMaxWidth,
                            maxHeight: .infinity
                        )

                    ResultDetailPaneView(
                        queue: queue,
                        onRequestSaveSelected: onRequestSaveSelected
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(
            minWidth: MarkItDownWindowLayout.minWidth,
            minHeight: MarkItDownWindowLayout.minHeight
        )
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if isDropTargeted && !queue.items.isEmpty {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(MarkItDownWindowLayout.spacingSmall)
                    .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: queue.items.isEmpty)
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDroppedProviders(providers)
        }
    }

    private func handleDroppedProviders(_ providers: [NSItemProvider]) -> Bool {
        guard !providers.isEmpty else { return false }
        let lock = NSLock()
        var collected: [URL] = []
        let group = DispatchGroup()

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                let resolvedURL: URL?
                if let data = item as? Data {
                    resolvedURL = URL(dataRepresentation: data, relativeTo: nil)
                } else if let url = item as? URL {
                    resolvedURL = url
                } else if let str = item as? String {
                    resolvedURL = URL(string: str)
                } else {
                    resolvedURL = nil
                }

                if let resolvedURL {
                    lock.lock()
                    collected.append(resolvedURL)
                    lock.unlock()
                }
            }
        }

        group.notify(queue: .main) {
            if !collected.isEmpty {
                queue.enqueue(urls: collected)
            }
        }
        return true
    }
}

public struct EmptyQueueDropView: View {
    public let isDropTargeted: Bool
    public let onRequestAddFiles: () -> Void

    public init(isDropTargeted: Bool, onRequestAddFiles: @escaping () -> Void) {
        self.isDropTargeted = isDropTargeted
        self.onRequestAddFiles = onRequestAddFiles
    }

    public var body: some View {
        VStack(spacing: MarkItDownWindowLayout.spacingMedium) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(isDropTargeted ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)

            Text("Arraste arquivos para cá ou adicione pelo Finder")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)

            Text("Formatos aceitos: DOCX, XLSX, PPTX, PDF, PNG e JPEG")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button(action: onRequestAddFiles) {
                Label("Adicionar arquivos…", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: [.command])
            .accessibilityLabel("Adicionar arquivos")
        }
        .padding(MarkItDownWindowLayout.spacingLarge)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isDropTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: isDropTargeted ? 2 : 1, dash: [6, 4])
                )
                .padding(MarkItDownWindowLayout.spacingLarge)
        )
    }
}

public struct QueueSidebarView: View {
    @ObservedObject public var queue: ConversionQueueManager

    public init(queue: ConversionQueueManager) {
        self.queue = queue
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Arquivos")
                .font(.headline)
                .foregroundStyle(.secondary)
                .padding(.horizontal, MarkItDownWindowLayout.spacingMedium)
                .padding(.vertical, MarkItDownWindowLayout.spacingSmall)

            Divider()

            List(selection: $queue.selectedItemID) {
                ForEach(queue.items) { item in
                    QueueSidebarRowView(
                        item: item,
                        disambiguatingFolder: queue.disambiguatingFolder(for: item),
                        voiceOverDescription: queue.voiceOverLabel(for: item),
                        onCancel: {
                            queue.cancel(itemID: item.id)
                        }
                    )
                    .tag(item.id)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Fila de arquivos")
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

public struct QueueSidebarRowView: View {
    public let item: ConversionQueueItem
    public let disambiguatingFolder: String?
    public let voiceOverDescription: String
    public let onCancel: () -> Void

    public init(
        item: ConversionQueueItem,
        disambiguatingFolder: String?,
        voiceOverDescription: String,
        onCancel: @escaping () -> Void
    ) {
        self.item = item
        self.disambiguatingFolder = disambiguatingFolder
        self.voiceOverDescription = voiceOverDescription
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: MarkItDownWindowLayout.spacingSmall) {
            HStack(alignment: .firstTextBaseline, spacing: MarkItDownWindowLayout.spacingSmall) {
                Text(item.fileName)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let folder = disambiguatingFolder, !folder.isEmpty {
                    Text(folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }

            HStack(spacing: MarkItDownWindowLayout.spacingSmall) {
                statusIndicator
                Text(item.state.listStatusTitle)
                    .font(.subheadline)
                    .foregroundStyle(statusTextColor)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if item.state.isConverting {
                    Button("Cancelar", action: onCancel)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Cancelar conversão de \(item.fileName)")
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(voiceOverDescription)
        .accessibilityHint(item.fileURL.path)
        .accessibilityAction(named: Text("Cancelar conversão")) {
            if item.state.canCancel {
                onCancel()
            }
        }
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch item.state {
        case .queued:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        case .converting, .cancelling:
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .completedWithWarnings:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .accessibilityHidden(true)
        case .cancelled:
            Image(systemName: "slash.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    private var statusTextColor: Color {
        switch item.state {
        case .failed:
            return .red
        case .completedWithWarnings:
            return .primary
        default:
            return .secondary
        }
    }
}

public struct ResultDetailPaneView: View {
    @ObservedObject public var queue: ConversionQueueManager
    public let onRequestSaveSelected: () -> Void

    public init(
        queue: ConversionQueueManager,
        onRequestSaveSelected: @escaping () -> Void
    ) {
        self.queue = queue
        self.onRequestSaveSelected = onRequestSaveSelected
    }

    public var body: some View {
        if let item = queue.selectedItem {
            VStack(alignment: .leading, spacing: 0) {
                headerSection(for: item)
                    .padding(MarkItDownWindowLayout.spacingMedium)

                Divider()

                contentSection(for: item)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Color(nsColor: .textBackgroundColor))
        } else {
            VStack(spacing: MarkItDownWindowLayout.spacingSmall) {
                Text("Selecione um arquivo na lista para revisar o resultado.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    @ViewBuilder
    private func headerSection(for item: ConversionQueueItem) -> some View {
        VStack(alignment: .leading, spacing: MarkItDownWindowLayout.spacingSmall) {
            HStack(alignment: .firstTextBaseline, spacing: MarkItDownWindowLayout.spacingSmall) {
                Text(item.fileName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.fileURL.path)

                if let folder = queue.disambiguatingFolder(for: item), !folder.isEmpty {
                    Text("(\(folder))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Text(item.state.panelHeaderStatusTitle)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            if let notice = item.panelNotice {
                Label(notice, systemImage: item.emptyPageNumbers.isEmpty ? "text.viewfinder" : "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            }

            if let saveError = queue.saveErrorMessage {
                HStack(spacing: MarkItDownWindowLayout.spacingSmall) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .accessibilityHidden(true)
                    Text(saveError)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    Button("Escolher outro destino…", action: onRequestSaveSelected)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }

            ViewThatFits(in: .horizontal) {
                actionControls(for: item)
                VStack(alignment: .leading, spacing: MarkItDownWindowLayout.spacingSmall) {
                    actionControls(for: item)
                }
            }
        }
    }

    @ViewBuilder
    private func actionControls(for item: ConversionQueueItem) -> some View {
        HStack(spacing: MarkItDownWindowLayout.spacingSmall) {
            Button {
                _ = queue.copySelectedMarkdownToPasteboard()
            } label: {
                Label("Copiar Markdown", systemImage: "doc.on.doc")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!item.canCopyAndExport)
            .accessibilityLabel("Copiar Markdown")

            if queue.copyFeedbackItemID == item.id {
                Text("Copiado")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Markdown copiado para a área de transferência")
            }

            Button(action: onRequestSaveSelected) {
                Label("Salvar Markdown…", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.bordered)
            .disabled(!item.canCopyAndExport)
            .accessibilityLabel("Salvar Markdown")

            if queue.saveFeedbackItemID == item.id {
                Text("Salvo")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Arquivo Markdown salvo")
            }

            if item.state.isConverting {
                Button("Cancelar") {
                    queue.cancel(itemID: item.id)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Cancelar conversão")
            }
        }
    }

    @ViewBuilder
    private func contentSection(for item: ConversionQueueItem) -> some View {
        switch item.state {
        case .completed, .completedWithWarnings:
            ScrollView(.vertical) {
                Text(item.markdown ?? "")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(MarkItDownWindowLayout.spacingMedium)
            }
            .accessibilityLabel("Resultado em Markdown de \(item.fileName)")

        case .failed(let message):
            VStack(alignment: .leading, spacing: MarkItDownWindowLayout.spacingSmall) {
                Label("Não foi possível converter este arquivo", systemImage: "exclamationmark.octagon.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(MarkItDownWindowLayout.spacingLarge)

        case .cancelled:
            VStack(alignment: .leading, spacing: MarkItDownWindowLayout.spacingSmall) {
                Label("Conversão cancelada", systemImage: "slash.circle")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text("O processamento deste arquivo foi interrompido pelo usuário.")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .padding(MarkItDownWindowLayout.spacingLarge)

        case .queued, .converting, .cancelling:
            VStack(alignment: .leading, spacing: MarkItDownWindowLayout.spacingMedium) {
                HStack(spacing: MarkItDownWindowLayout.spacingSmall) {
                    ProgressView()
                        .controlSize(.regular)
                    Text(item.state.panelHeaderStatusTitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(MarkItDownWindowLayout.spacingLarge)
        }
    }
}
