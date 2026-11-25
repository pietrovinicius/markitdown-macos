import CoreGraphics
import Foundation
import ImageIO
import Vision

public protocol OCRRecognizing: Sendable {
    func recognizeText(in cgImage: CGImage) throws -> String
    func recognizeImageFile(at url: URL) throws -> String
}

public struct AppleVisionOCRService: OCRRecognizing {
    public let recognitionLanguages: [String]

    public init(recognitionLanguages: [String] = ["pt-BR", "en-US"]) {
        self.recognitionLanguages = recognitionLanguages
    }

    public func recognizeImageFile(at url: URL) throws -> String {
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            throw ConversionDomainError.fileUnreadable
        }
        guard
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw ConversionDomainError.corruptedFile(
                "Imagem corrompida ou ilegível. Verifique o arquivo de origem."
            )
        }

        let recognized = try recognizeText(in: cgImage)
        let trimmed = recognized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.containsAlphanumeric(in: trimmed) else {
            throw ConversionDomainError.emptyOutput
        }
        return trimmed
    }

    public func recognizeText(in cgImage: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = recognitionLanguages

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ConversionDomainError.corruptedFile(
                "Não foi possível executar o reconhecimento óptico de texto nesta imagem."
            )
        }

        let observations = request.results ?? []
        return Self.assembleReadingOrderText(from: observations)
    }

    public static func containsAlphanumeric(in text: String) -> Bool {
        text.rangeOfCharacter(from: .alphanumerics) != nil
    }

    static func assembleReadingOrderText(from observations: [VNRecognizedTextObservation]) -> String {
        struct LineBox {
            let text: String
            let minX: CGFloat
            let midY: CGFloat
        }

        let candidates: [LineBox] = observations.compactMap { obs in
            guard let top = obs.topCandidates(1).first else { return nil }
            let clean = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return nil }
            return LineBox(
                text: clean,
                minX: obs.boundingBox.minX,
                midY: obs.boundingBox.midY
            )
        }

        guard !candidates.isEmpty else { return "" }

        // Vision coordinates have origin at bottom-left (higher Y is higher on page).
        let sortedByY = candidates.sorted { lhs, rhs in
            if abs(lhs.midY - rhs.midY) > 0.018 {
                return lhs.midY > rhs.midY
            }
            return lhs.minX < rhs.minX
        }

        var lines: [[LineBox]] = []
        for item in sortedByY {
            if var currentRow = lines.last, let anchor = currentRow.first, abs(anchor.midY - item.midY) <= 0.018 {
                currentRow.append(item)
                lines[lines.count - 1] = currentRow
            } else {
                lines.append([item])
            }
        }

        let orderedLines = lines.map { row in
            row.sorted { $0.minX < $1.minX }
                .map(\.text)
                .joined(separator: " ")
        }

        return orderedLines.joined(separator: "\n")
    }
}
