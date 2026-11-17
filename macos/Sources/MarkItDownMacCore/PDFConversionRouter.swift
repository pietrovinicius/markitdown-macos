import AppKit
import CoreGraphics
import Foundation
import PDFKit

public struct ConversionOutput: Equatable, Sendable {
    public let markdown: String
    public let ocrApplied: Bool
    public let emptyPageNumbers: [Int]

    public init(markdown: String, ocrApplied: Bool, emptyPageNumbers: [Int] = []) {
        self.markdown = markdown
        self.ocrApplied = ocrApplied
        self.emptyPageNumbers = emptyPageNumbers
    }
}

public struct PDFConversionRouter: Sendable {
    private let workerRunner: DocumentWorkerRunning
    private let ocrService: OCRRecognizing

    public init(workerRunner: DocumentWorkerRunning, ocrService: OCRRecognizing) {
        self.workerRunner = workerRunner
        self.ocrService = ocrService
    }

    public func convertPDF(
        at url: URL,
        isCancelled: @escaping @Sendable () -> Bool,
        onPageProgress: @escaping @Sendable (Int, Int) -> Void,
        onTerminationHandler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) async throws -> ConversionOutput {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionDomainError.fileUnreadable
        }

        guard let headerData = try? FileHandle(forReadingFrom: url).read(upToCount: 1024),
              let headerStr = String(data: headerData, encoding: .isoLatin1),
              headerStr.contains("%PDF-")
        else {
            throw ConversionDomainError.corruptedFile(
                "Arquivo PDF corrompido ou inválido. Verifique o documento de origem."
            )
        }

        guard let document = PDFDocument(url: url) else {
            throw ConversionDomainError.corruptedFile(
                "Arquivo PDF corrompido ou inválido. Verifique o documento de origem."
            )
        }

        if document.isEncrypted && document.isLocked {
            throw ConversionDomainError.pdfLocked
        }

        let pageCount = document.pageCount
        guard pageCount > 0 else {
            throw ConversionDomainError.corruptedFile(
                "Arquivo PDF sem páginas válidas."
            )
        }

        // Inspect each page's native text layer
        var pageTexts: [String?] = []
        pageTexts.reserveCapacity(pageCount)
        var allPagesHaveText = true

        for pageIndex in 0..<pageCount {
            if isCancelled() || Task.isCancelled {
                throw ConversionDomainError.cancelled
            }
            guard let page = document.page(at: pageIndex) else {
                pageTexts.append(nil)
                allPagesHaveText = false
                continue
            }
            let rawText = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if AppleVisionOCRService.containsAlphanumeric(in: rawText) {
                pageTexts.append(rawText)
            } else {
                pageTexts.append(nil)
                allPagesHaveText = false
            }
        }

        // Route 1: All pages have usable native text layer -> full document via MarkItDown worker
        if allPagesHaveText {
            let markdown = try await workerRunner.convert(
                fileURL: url,
                onTerminationHandler: onTerminationHandler
            )
            return ConversionOutput(markdown: markdown, ocrApplied: false, emptyPageNumbers: [])
        }

        // Route 2: Scanned or mixed PDF -> assemble in page order with `## Página N` headers
        var sections: [String] = []
        var emptyPageNumbers: [Int] = []

        for pageIndex in 0..<pageCount {
            if isCancelled() || Task.isCancelled {
                throw ConversionDomainError.cancelled
            }

            let pageNumber = pageIndex + 1
            onPageProgress(pageNumber, pageCount)

            if let nativeText = pageTexts[pageIndex], !nativeText.isEmpty {
                sections.append("## Página \(pageNumber)\n\(nativeText)")
                continue
            }

            guard let page = document.page(at: pageIndex) else {
                emptyPageNumbers.append(pageNumber)
                continue
            }

            do {
                let cgImage = try Self.rasterize(page: page, scale: 3.0)
                if isCancelled() || Task.isCancelled {
                    throw ConversionDomainError.cancelled
                }
                let ocrText = try ocrService.recognizeText(in: cgImage)
                    .trimmingCharacters(in: .whitespacesAndNewlines)

                if AppleVisionOCRService.containsAlphanumeric(in: ocrText) {
                    sections.append("## Página \(pageNumber)\n\(ocrText)")
                } else {
                    emptyPageNumbers.append(pageNumber)
                }
            } catch let error as ConversionDomainError where error == .cancelled {
                throw error
            } catch {
                // Recoverable single-page OCR error is recorded as an empty page warning
                emptyPageNumbers.append(pageNumber)
            }

            await Task.yield()
        }

        if isCancelled() || Task.isCancelled {
            throw ConversionDomainError.cancelled
        }

        guard !sections.isEmpty else {
            throw ConversionDomainError.emptyOutput
        }

        return ConversionOutput(
            markdown: sections.joined(separator: "\n\n"),
            ocrApplied: true,
            emptyPageNumbers: emptyPageNumbers
        )
    }

    private static func rasterize(page: PDFPage, scale: CGFloat) throws -> CGImage {
        let bounds = page.bounds(for: .mediaBox)
        let width = max(Int((bounds.width * scale).rounded(.up)), 1)
        let height = max(Int((bounds.height * scale).rounded(.up)), 1)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ConversionDomainError.corruptedFile("Falha ao preparar página do PDF para OCR.")
        }

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw ConversionDomainError.corruptedFile("Falha ao renderizar página do PDF para OCR.")
        }
        return image
    }
}
