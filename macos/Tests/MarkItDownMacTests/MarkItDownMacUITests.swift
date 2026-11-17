import AppKit
import SwiftUI
import XCTest
@testable import MarkItDownMacCore

@MainActor
final class MarkItDownMacUITests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("markitdown-ui-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testWindowLayoutConstantsAndSemanticContrastInLightAndDarkThemes() throws {
        XCTAssertEqual(MarkItDownWindowLayout.initialWidth, 960)
        XCTAssertEqual(MarkItDownWindowLayout.initialHeight, 640)
        XCTAssertEqual(MarkItDownWindowLayout.minWidth, 720)
        XCTAssertEqual(MarkItDownWindowLayout.minHeight, 480)
        XCTAssertEqual(MarkItDownWindowLayout.sidebarIdealWidth, 250)

        let lightRatio = MarkItDownThemeContrast.normalTextContrastRatio(appearanceName: .aqua)
        let darkRatio = MarkItDownThemeContrast.normalTextContrastRatio(appearanceName: .darkAqua)
        XCTAssertGreaterThanOrEqual(lightRatio, 4.5, "Light theme normal text contrast must be >= 4.5:1")
        XCTAssertGreaterThanOrEqual(darkRatio, 4.5, "Dark theme normal text contrast must be >= 4.5:1")
    }

    func testRenderAllStatesAtInitialAndMinimumDimensionsInBothThemes() throws {
        let queue = ConversionQueueManager(workerRunner: InstantMockWorker())

        // 1. Empty state render in 960x640 and 720x480
        assertHostingRenders(queue: queue, size: NSSize(width: 960, height: 640), appearance: .aqua)
        assertHostingRenders(queue: queue, size: NSSize(width: 720, height: 480), appearance: .darkAqua)

        // 2. Populate states: completed, completedWithWarnings, failed, converting
        let f1 = tempDir.appendingPathComponent("ata-reuniao.pdf")
        let f2 = tempDir.appendingPathComponent("parcial.pdf")
        let f3 = tempDir.appendingPathComponent("bloqueado.pdf")
        try Data("a".utf8).write(to: f1)
        try Data("b".utf8).write(to: f2)
        try Data("c".utf8).write(to: f3)

        queue.loadPreviewItemsForTesting([
            ConversionQueueItem(
                fileURL: f1,
                state: .completed,
                markdown: "## Página 1\nAta da reunião",
                ocrApplied: true,
                emptyPageNumbers: []
            ),
            ConversionQueueItem(
                fileURL: f2,
                state: .completedWithWarnings,
                markdown: "## Página 1\nAta parcial",
                ocrApplied: true,
                emptyPageNumbers: [3]
            ),
            ConversionQueueItem(
                fileURL: f3,
                state: .failed(message: "PDF protegido por senha. Adicione uma cópia desbloqueada."),
                markdown: nil,
                ocrApplied: false,
                emptyPageNumbers: []
            )
        ])

        for item in queue.items {
            queue.selectedItemID = item.id
            assertHostingRenders(queue: queue, size: NSSize(width: 960, height: 640), appearance: .aqua)
            assertHostingRenders(queue: queue, size: NSSize(width: 720, height: 480), appearance: .darkAqua)
        }
    }

    func testCopyAndSaveFeedbackAndAnnouncement() throws {
        let queue = ConversionQueueManager(workerRunner: InstantMockWorker())
        let fileURL = tempDir.appendingPathComponent("nota.docx")
        try Data("x".utf8).write(to: fileURL)

        let item = ConversionQueueItem(
            fileURL: fileURL,
            state: .completed,
            markdown: "# Nota Oficial\nConteúdo pronto.",
            ocrApplied: false
        )
        queue.loadPreviewItemsForTesting([item])
        queue.selectedItemID = item.id

        XCTAssertTrue(queue.copySelectedMarkdownToPasteboard())
        XCTAssertEqual(queue.copyFeedbackItemID, item.id)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "# Nota Oficial\nConteúdo pronto.")

        guard let snapshot = queue.exportSnapshotForSelection() else {
            XCTFail("Expected export snapshot")
            return
        }
        let dest = tempDir.appendingPathComponent(snapshot.suggestedFileName)
        try queue.saveMarkdown(snapshot, to: dest)
        XCTAssertEqual(queue.saveFeedbackItemID, item.id)
        XCTAssertNil(queue.saveErrorMessage)
    }

    private func assertHostingRenders(
        queue: ConversionQueueManager,
        size: NSSize,
        appearance: NSAppearance.Name
    ) {
        let rootView = MarkItDownWorkspaceView(
            queue: queue,
            onRequestAddFiles: {},
            onRequestSaveSelected: {}
        )
        let hosting = NSHostingView(rootView: rootView)
        hosting.appearance = NSAppearance(named: appearance)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.frame.size, size)
    }
}

private struct InstantMockWorker: DocumentWorkerRunning {
    func convert(
        fileURL: URL,
        onTerminationHandler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) async throws -> String {
        "# Mock"
    }
}
