import Foundation
import AppKit

/// Sends commands to terminal windows.
/// Primary: tmux send-keys (direct PTY, no focus/clipboard needed)
/// Fallback: clipboard paste for non-tmux windows
@MainActor
final class CommandService {

    enum SendResult {
        case sent(method: String)
        case failed(reason: String)
    }

    private static let tmuxPath = "/opt/homebrew/bin/tmux"

    // MARK: - Public API

    /// Send text to a terminal. Uses tmux if available, clipboard paste fallback.
    static func sendText(_ text: String, to window: MonitoredWindow) async -> SendResult {
        log("sendText: '\(text)' to \(window.windowTitle) (owner: \(window.ownerName))")

        // Strategy 1: tmux send-keys (direct PTY — only method that works reliably)
        if let session = findTmuxSession(for: window) {
            if tmuxSendKeys(text, session: session) {
                log("Sent via tmux to session: \(session)")
                return .sent(method: "tmux")
            }
        }

        // Strategy 2: VS Code REST Control extension
        // Raise the correct window first, then send via REST
        let project = extractProject(from: window)
        WindowInteractionService.raiseByProjectName(
            project, windowID: window.id, ownerName: window.ownerName
        )
        try? await Task.sleep(for: .milliseconds(400))

        // Try cached port first, then scan
        let ports = discoveredPorts.isEmpty ? [39733, 57037, 37100] : discoveredPorts
        for port in ports {
            if await vsCodeRestSend(text, port: port) {
                if !discoveredPorts.contains(port) { discoveredPorts.append(port) }
                log("Sent via VS Code REST Control on port \(port)")
                return .sent(method: "vscode-rest:\(port)")
            }
        }

        return .failed(reason: "Install 'REST Control' VS Code extension and reload VS Code")
    }

    // MARK: - Strategy 2: VS Code REST Control Extension

    /// Cache of discovered REST Control ports
    private static var discoveredPorts: [Int] = []
    private static var portsDiscovered = false

    /// Discover REST Control ports by testing known candidates
    private static func discoverRestPorts() -> [Int] {
        if portsDiscovered { return discoveredPorts }

        // Get all VS Code listening ports
        guard let output = runShell("/usr/sbin/lsof", args: [
            "-iTCP", "-sTCP:LISTEN", "-P", "-n"
        ]) else {
            portsDiscovered = true
            return []
        }

        var candidates: Set<Int> = []
        for line in output.components(separatedBy: "\n") {
            guard line.contains("Code") || line.contains("Electron") else { continue }
            guard let colonIdx = line.lastIndex(of: ":") else { continue }
            let afterColon = line[line.index(after: colonIdx)...]
            let portStr = afterColon.prefix(while: { $0.isNumber })
            if let port = Int(portStr), port > 30000 && port < 65000 {
                candidates.insert(port)
            }
        }

        // Test each candidate — only "null" response means REST Control
        var working: [Int] = []
        for port in candidates.sorted() {
            let result = runShell("/usr/bin/curl", args: [
                "-s", "--max-time", "0.5", "-X", "POST",
                "http://localhost:\(port)",
                "-H", "Content-Type: application/json",
                "-d", #"{"command":"workbench.action.terminal.sendSequence","args":[{"text":""}]}"#
            ])
            // ONLY "null" = REST Control success. Empty = wrong port.
            if let r = result, r.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
                working.append(port)
                log("Found REST Control port: \(port)")
            }
        }

        discoveredPorts = working
        portsDiscovered = true
        return working
    }

    /// Reset port cache (call when windows change)
    static func resetPortCache() {
        portsDiscovered = false
        discoveredPorts = []
    }

    /// Send text to VS Code terminal via REST Control extension HTTP API.
    private static func vsCodeRestSend(_ text: String, port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 0.5

        // REST Control expects args as an array
        let body: [String: Any] = [
            "command": "workbench.action.terminal.sendSequence",
            "args": [["text": text + "\n"]]
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let responseStr = String(data: data, encoding: .utf8) ?? ""
            // null response = success, error response contains "stack"
            return status == 200 && !responseStr.contains("stack")
        } catch {
            return false
        }
    }

    /// Send text to a named tmux session directly
    static func sendToTmuxSession(_ text: String, session: String) -> SendResult {
        if tmuxSendKeys(text, session: session) {
            log("Sent to tmux session: \(session)")
            return .sent(method: "tmux")
        }
        return .failed(reason: "tmux send-keys failed for session: \(session)")
    }

    // MARK: - tmux Session Management

    /// List all tmux sessions with their working directories
    static func listTmuxSessions() -> [(name: String, path: String)] {
        // Use ||| as delimiter since \t gets passed literally in Process args
        guard let output = runShell(tmuxPath, args: [
            "list-sessions", "-F", "#{session_name}|||#{pane_current_path}"
        ]) else { return [] }

        return output.components(separatedBy: "\n").compactMap { line in
            let parts = line.components(separatedBy: "|||")
            guard parts.count == 2 else { return nil }
            return (name: parts[0], path: parts[1])
        }
    }

    /// Create a new tmux session and run claude in it
    static func launchClaudeInTmux(projectPath: String, sessionName: String? = nil) -> String? {
        let name = sessionName ?? URL(fileURLWithPath: projectPath).lastPathComponent
        // Sanitize session name (tmux doesn't allow dots or colons)
        let safeName = name.replacingOccurrences(of: ".", with: "_")
            .replacingOccurrences(of: ":", with: "_")

        // Check if session already exists
        let existing = listTmuxSessions()
        if existing.contains(where: { $0.name == safeName }) {
            log("tmux session '\(safeName)' already exists")
            return safeName
        }

        // Create detached session in the project directory
        guard runShell(tmuxPath, args: [
            "new-session", "-d", "-s", safeName, "-c", projectPath
        ]) != nil else {
            log("Failed to create tmux session '\(safeName)'")
            return nil
        }

        // Launch claude in the session
        _ = runShell(tmuxPath, args: ["send-keys", "-t", safeName, "claude", "Enter"])

        // Open Terminal.app showing this session
        let script = """
        tell application "Terminal"
            activate
            do script "\(tmuxPath) attach -t \(safeName)"
        end tell
        """
        _ = runShell("/usr/bin/osascript", args: ["-e", script])

        log("Launched Claude in tmux session '\(safeName)' at \(projectPath)")
        return safeName
    }

    /// Check if tmux is installed
    static var isTmuxAvailable: Bool {
        FileManager.default.fileExists(atPath: tmuxPath)
    }

    // MARK: - tmux Send

    /// Public: check if window has a tmux session (for UI indicators)
    static func findTmuxSessionName(for window: MonitoredWindow) -> String? {
        findTmuxSession(for: window)
    }

    /// Find a tmux session matching a monitored window
    private static func findTmuxSession(for window: MonitoredWindow) -> String? {
        let sessions = listTmuxSessions()
        if sessions.isEmpty { return nil }

        let project = extractProject(from: window)

        // Match by session name
        for s in sessions {
            if s.name.localizedCaseInsensitiveCompare(project) == .orderedSame {
                return s.name
            }
        }

        // Match by path containing project name
        for s in sessions {
            if s.path.lowercased().contains(project.lowercased()) {
                return s.name
            }
        }

        // Match by project name containing session name
        for s in sessions {
            if project.lowercased().contains(s.name.lowercased()) {
                return s.name
            }
        }

        return nil
    }

    /// Send text via tmux send-keys — writes directly to terminal PTY
    private static func tmuxSendKeys(_ text: String, session: String) -> Bool {
        let result = runShell(tmuxPath, args: ["send-keys", "-t", session, text, "Enter"])
        return result != nil
    }

    // MARK: - Strategy 2: AppleScript

    /// Use AppleScript to: raise window → focus terminal → type text → press Enter
    private static func appleScriptSend(_ text: String, to window: MonitoredWindow) async -> Bool {
        let project = extractProject(from: window)

        // Raise the correct VS Code window
        WindowInteractionService.raiseByProjectName(
            project, windowID: window.id, ownerName: window.ownerName
        )
        try? await Task.sleep(for: .milliseconds(600))

        // Escape text for AppleScript
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Use AppleScript to:
        // 1. Focus VS Code terminal with Ctrl+` (backtick = key code 50)
        // 2. Small delay for terminal to gain focus
        // 3. Type the text
        // 4. Press Return
        let script = """
        tell application "System Events"
            tell process "\(window.ownerName)"
                set frontmost to true
                delay 0.2
                -- Focus terminal: Ctrl+backtick
                key code 50 using control down
                delay 0.3
                -- Type text
                keystroke "\(escaped)"
                delay 0.05
                -- Press Enter
                key code 36
            end tell
        end tell
        """

        log("AppleScript send to \(window.ownerName), project: \(project)")

        // Run on background thread to avoid blocking main
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let result = runShell("/usr/bin/osascript", args: ["-e", script])
                continuation.resume(returning: result != nil)
            }
        }
    }

    // MARK: - Clipboard Paste Fallback

    /// Clipboard paste using Maccy's proven CGEvent approach
    private static func clipboardPaste(_ text: String, to window: MonitoredWindow) async -> Bool {
        let project = extractProject(from: window)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Raise the correct window
        WindowInteractionService.raiseByProjectName(
            project, windowID: window.id, ownerName: window.ownerName
        )
        try? await Task.sleep(for: .milliseconds(500))

        if !WindowInteractionService.verifyFrontWindow(contains: project) {
            WindowInteractionService.raiseByProjectName(
                project, windowID: window.id, ownerName: window.ownerName
            )
            try? await Task.sleep(for: .milliseconds(400))
        }

        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let cmdFlag = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)

        // Focus terminal with Ctrl+`
        let ctrlFlag = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x000008)
        let tickDown = CGEvent(keyboardEventSource: src, virtualKey: 50, keyDown: true)
        let tickUp = CGEvent(keyboardEventSource: src, virtualKey: 50, keyDown: false)
        tickDown?.flags = ctrlFlag
        tickUp?.flags = ctrlFlag
        tickDown?.post(tap: .cgSessionEventTap)
        tickUp?.post(tap: .cgSessionEventTap)

        try? await Task.sleep(for: .milliseconds(200))

        // Cmd+V paste
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = cmdFlag
        vUp?.flags = cmdFlag
        vDown?.post(tap: .cgSessionEventTap)
        vUp?.post(tap: .cgSessionEventTap)

        try? await Task.sleep(for: .milliseconds(100))

        // Enter
        CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)?.post(tap: .cgSessionEventTap)
        CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)?.post(tap: .cgSessionEventTap)

        try? await Task.sleep(for: .milliseconds(300))
        pasteboard.clearContents()
        if let s = saved { pasteboard.setString(s, forType: .string) }

        return true
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
