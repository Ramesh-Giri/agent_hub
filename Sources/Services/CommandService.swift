import Foundation
import AppKit

/// Sends commands to Claude Code terminals via VS Code REST Control extension.
/// Uses `workbench.action.terminal.sendSequence` — writes directly to the terminal PTY.
/// Raises the target window first for multi-window targeting.
@MainActor
final class CommandService {

    enum SendResult {
        case sent(method: String)
        case failed(reason: String)
    }

    private static var cachedPort: Int?

    // MARK: - Public API

    /// Send text to a VS Code terminal window.
    /// Raises the correct window, then sends via REST Control extension.
    static func sendText(_ text: String, to window: MonitoredWindow) async -> SendResult {
        log("sendText: '\(text)' to \(window.windowTitle) (owner: \(window.ownerName))")

        let project = extractProject(from: window)

        // Raise the correct window so sendSequence targets it
        WindowInteractionService.raiseByProjectName(
            project, windowID: window.id, ownerName: window.ownerName
        )
        try? await Task.sleep(for: .milliseconds(500))

        // Find the REST Control port (cached after first discovery)
        guard let port = await findRestPort() else {
            return .failed(reason: "VS Code REST Control not found. Install extension: dpar39.vscode-rest-control")
        }

        // Send via REST Control
        if await restSend(text, port: port) {
            log("Sent via REST Control port \(port) to \(project)")
            return .sent(method: "rest:\(port)")
        }

        // Port might have changed — retry with fresh discovery
        cachedPort = nil
        if let newPort = await findRestPort(), await restSend(text, port: newPort) {
            log("Sent via REST Control port \(newPort) to \(project) (retry)")
            return .sent(method: "rest:\(newPort)")
        }

        return .failed(reason: "Failed to send to '\(project)'. Check VS Code REST Control extension.")
    }

    // MARK: - REST Control

    /// Discover the REST Control port by testing ports directly with URLSession.
    /// No lsof, no shell — just HTTP requests.
    private static func findRestPort() async -> Int? {
        if let cached = cachedPort { return cached }

        // Scan a range of likely ports — REST Control defaults + common high ports
        // Test them all concurrently for speed
        let candidates = [39733, 57037, 37100, 37101, 49539, 49782, 39734, 39735]

        for port in candidates {
            if await testPort(port) {
                cachedPort = port
                log("Found REST Control on port \(port)")
                return port
            }
        }

        return nil
    }

    /// Test if a port is a REST Control endpoint using a harmless read-only command
    private static func testPort(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 0.3
        // Use a harmless command that doesn't trigger any dialog
        req.httpBody = #"{"command":"workbench.action.terminal.focus"}"#.data(using: .utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return status == 200 && (body == "null" || body.isEmpty)
        } catch { return false }
    }

    /// Send text to VS Code terminal via REST Control
    private static func restSend(_ text: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 2

        let body: [String: Any] = [
            "command": "workbench.action.terminal.sendSequence",
            "args": [["text": text + "\n"]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            return status == 200 && !body.contains("stack")
        } catch { return false }
    }

    // MARK: - Helpers

    static func extractProject(from window: MonitoredWindow) -> String {
        let title = window.windowTitle
        if let dash = title.range(of: " — ", options: .backwards) {
            return String(title[dash.upperBound...])
        }
        return title
    }

    private static func log(_ msg: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(msg)\n"
        let path = "/tmp/canopy-debug.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(line.data(using: .utf8) ?? Data())
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: line.data(using: .utf8))
        }
    }

    @discardableResult
    nonisolated static func runShell(_ path: String, args: [String]) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            if proc.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {}
        return nil
    }
}
