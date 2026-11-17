import Darwin
import Foundation

public protocol DocumentWorkerRunning: Sendable {
    func convert(
        fileURL: URL,
        onTerminationHandler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) async throws -> String
}

private struct WorkerErrorPayload: Decodable {
    let error_code: String
    let user_message: String
    let diagnostic: String?
}

public final class SubprocessPythonWorkerRunner: DocumentWorkerRunning, @unchecked Sendable {
    public let executableURL: URL
    public let leadingArguments: [String]

    public init(executableURL: URL? = nil, leadingArguments: [String] = []) {
        if let executableURL {
            self.executableURL = executableURL
            self.leadingArguments = leadingArguments
        } else if let bundled = Self.resolveBundledWorker() {
            self.executableURL = bundled.executableURL
            self.leadingArguments = bundled.leadingArguments
        } else {
            let fallback = Self.resolveDevelopmentWorker()
            self.executableURL = fallback.executableURL
            self.leadingArguments = fallback.leadingArguments
        }
    }

    public static func resolveBundledWorker(in bundle: Bundle = .main) -> (executableURL: URL, leadingArguments: [String])? {
        if let resourceURL = bundle.resourceURL {
            let folderBinary = resourceURL
                .appendingPathComponent("markitdown-worker", isDirectory: true)
                .appendingPathComponent("markitdown-worker")
            if FileManager.default.isExecutableFile(atPath: folderBinary.path) {
                return (folderBinary, [])
            }

            let standaloneBinary = resourceURL.appendingPathComponent("markitdown-worker")
            if FileManager.default.isExecutableFile(atPath: standaloneBinary.path) {
                return (standaloneBinary, [])
            }
        }
        return nil
    }

    public static func resolveDevelopmentWorker() -> (executableURL: URL, leadingArguments: [String]) {
        let env = ProcessInfo.processInfo.environment
        if let customExec = env["MARKITDOWN_WORKER_EXECUTABLE"], !customExec.isEmpty {
            let execURL = URL(fileURLWithPath: customExec)
            if let script = env["MARKITDOWN_WORKER_SCRIPT"], !script.isEmpty {
                return (execURL, [script])
            }
            return (execURL, [])
        }

        // Locate repository root relative to source/package directory when running in dev/tests
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let venvPython = sourceRoot.appendingPathComponent(".venv/bin/python")
        let workerScript = sourceRoot.appendingPathComponent("macos/worker/markitdown_macos_worker.py")
        if FileManager.default.isExecutableFile(atPath: venvPython.path) {
            return (venvPython, [workerScript.path])
        }

        return (URL(fileURLWithPath: "/usr/bin/python3"), [workerScript.path])
    }

    public func convert(
        fileURL: URL,
        onTerminationHandler: @escaping @Sendable (@escaping @Sendable () -> Void) -> Void
    ) async throws -> String {
        let didAccessSecurityScope = fileURL.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScope {
                fileURL.stopAccessingSecurityScopedResource()
            }
        }

        guard FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw ConversionDomainError.fileUnreadable
        }

        // Create private temporary working copy so the subprocess always has read permission
        // and clean it up unconditionally on completion, error, or cancellation.
        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("markitdown-work-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
        }

        let stagedFileURL = stagingDir.appendingPathComponent(fileURL.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: fileURL, to: stagedFileURL)
        } catch {
            throw ConversionDomainError.fileUnreadable
        }

        let execURL = self.executableURL
        let prefixArgs = self.leadingArguments

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = execURL
                process.arguments = prefixArgs + [stagedFileURL.path]

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                onTerminationHandler {
                    if process.isRunning {
                        process.terminate()
                        kill(process.processIdentifier, SIGTERM)
                    }
                }

                process.terminationHandler = { proc in
                    let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                    let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

                    if proc.terminationReason == .uncaughtSignal {
                        continuation.resume(throwing: ConversionDomainError.cancelled)
                        return
                    }

                    let status = proc.terminationStatus
                    if status == 0 {
                        let markdown = String(data: outData, encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if markdown.isEmpty {
                            continuation.resume(throwing: ConversionDomainError.emptyOutput)
                        } else {
                            continuation.resume(returning: markdown)
                        }
                        return
                    }

                    let mappedError = Self.mapFailure(exitCode: status, stderrData: errData)
                    continuation.resume(throwing: mappedError)
                }

                do {
                    try process.run()
                } catch {
                    continuation.resume(
                        throwing: ConversionDomainError.corruptedFile(
                            "Não foi possível iniciar o conversor local."
                        )
                    )
                }
            }
        } onCancel: {
            // Signaled through onTerminationHandler as well
        }
    }

    private static func mapFailure(exitCode: Int32, stderrData: Data) -> ConversionDomainError {
        if let stderrText = String(data: stderrData, encoding: .utf8) {
            let lines = stderrText
                .split(whereSeparator: \.isNewline)
                .map(String.init)
            if let lastLine = lines.last,
               let lineData = lastLine.data(using: .utf8),
               let payload = try? JSONDecoder().decode(WorkerErrorPayload.self, from: lineData) {
                switch payload.error_code {
                case "unsupported_format":
                    return .unsupportedFormat
                case "pdf_locked":
                    return .pdfLocked
                case "empty_output":
                    return .emptyOutput
                case "file_unreadable":
                    return .fileUnreadable
                case "corrupted_file":
                    return .corruptedFile(payload.user_message)
                default:
                    return .corruptedFile(payload.user_message)
                }
            }
        }

        switch exitCode {
        case 2:
            return .unsupportedFormat
        case 3:
            return .pdfLocked
        case 5:
            return .emptyOutput
        case 6:
            return .fileUnreadable
        default:
            return .corruptedFile(
                "Arquivo corrompido ou ilegível. Verifique se o documento abre no aplicativo de origem."
            )
        }
    }
}
