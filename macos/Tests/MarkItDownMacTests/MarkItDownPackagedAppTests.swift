import Foundation
import XCTest
@testable import MarkItDownMacCore

final class MarkItDownPackagedAppTests: XCTestCase {
    private func repoRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testPackagedAppBundleResolvesEmbeddedWorkerAndRunsOfflineSmokeTest() throws {
        let appURL = repoRootURL().appendingPathComponent("macos/dist/MarkItDown.app")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: appURL.path),
            "MarkItDown.app must be built at macos/dist/MarkItDown.app before running packaged app verification"
        )

        guard let appBundle = Bundle(url: appURL) else {
            XCTFail("Failed to load Bundle for MarkItDown.app")
            return
        }

        guard let resolved = SubprocessPythonWorkerRunner.resolveBundledWorker(in: appBundle) else {
            XCTFail("Packaged MarkItDown.app did not contain embedded markitdown-worker executable")
            return
        }
        XCTAssertTrue(resolved.executableURL.path.contains("MarkItDown.app/Contents/Resources/markitdown-worker"))
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved.executableURL.path))

        let tempOutDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("markitdown-app-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempOutDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempOutDir) }

        let appExecutable = appURL.appendingPathComponent("Contents/MacOS/MarkItDownMac")
        let proc = Process()
        proc.executableURL = appExecutable
        proc.arguments = ["--smoke-test", tempOutDir.path]

        // Simulate environment with NO Homebrew/user Python in PATH and network blocked
        proc.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "HTTP_PROXY": "http://127.0.0.1:1",
            "HTTPS_PROXY": "http://127.0.0.1:1",
            "ALL_PROXY": "http://127.0.0.1:1",
            "NO_PROXY": ""
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        proc.waitUntilExit()

        let stdoutText = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        XCTAssertEqual(proc.terminationStatus, 0, "Packaged app smoke test failed: \(stderrText)")
        XCTAssertTrue(stdoutText.contains("SMOKE_TEST_OK"), "Unexpected stdout: \(stdoutText)")

        let exportedOffice = try String(
            contentsOf: tempOutDir.appendingPathComponent("smoke-office.md"),
            encoding: .utf8
        )
        let exportedScan = try String(
            contentsOf: tempOutDir.appendingPathComponent("smoke-scan.md"),
            encoding: .utf8
        )
        XCTAssertTrue(exportedOffice.contains("# Smoke Test macOS"))
        XCTAssertTrue(exportedScan.localizedCaseInsensitiveContains("reconhecimento óptico local validado"))
    }
}
