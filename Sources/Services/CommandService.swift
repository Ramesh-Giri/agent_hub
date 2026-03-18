import Foundation
import AppKit

/// Sends commands to terminal windows via multiple strategies:
/// 1. tmux send-keys (if terminal is running in tmux) — most reliable, no focus stealing
/// 2. osascript keystroke (if tmux not available) — sends via System Events
/// 3. Clipboard paste fallback — saves clipboard, pastes, restores
@MainActor
final class CommandService {

    enum SendResult {
        case sent(method: String)
        case failed(reason: String)
    }

    /// Send text to a terminal window. Tries tmux first, then osascript, then clipboard paste.
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

    static func sendText(_ text: String, to window: MonitoredWindow) async -> SendResult {
        log("sendText: '\(text)' to \(window.windowTitle) (owner: \(window.ownerName), id: \(window.id))")

        // Strategy 1: tmux send-keys (direct PTY, no window focus needed)
        if let session = await findTmuxSession(for: window) {
            let result = await tmuxSendKeys(text, session: session)
            if result {
                log("Sent via tmux to session: \(session)")
                return .sent(method: "tmux")
            }
        }

        // Strategy 2: Clipboard paste — raise window, focus terminal, Cmd+V, Enter
        // More reliable than osascript keystroke which goes to the editor, not terminal
        let pasteResult = await clipboardPaste(text, to: window)
        if pasteResult {
            log("Sent via clipboard paste to: \(window.ownerName)")
            return .sent(method: "clipboard")
        }

        return .failed(reason: "All send methods failed")
    }

    // MARK: - Strategy 1: tmux send-keys

    /// Find a tmux session that matches this window's project
    private static func findTmuxSession(for window: MonitoredWindow) async -> String? {
        // List all tmux sessions
        guard let output = runShell("/opt/homebrew/bin/tmux", args: ["list-sessions", "-F", "#{session_name}:#{pane_current_path}"]) else {
            // tmux not installed or no sessions
            return nil
        }

        // Extract project name from window title
        let title = window.windowTitle
        let project: String
        if let dash = title.range(of: " — ", options: .backwards) {
            project = String(title[dash.upperBound...])
        } else {
            project = title
        }

        // Match session by project name in path
        for line in output.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let sessionName = String(parts[0])
            let path = String(parts[1]).lowercased()

            if path.contains(project.lowercased()) {
                return sessionName
            }
        }

        return nil
    }

    /// Send text via tmux send-keys — types directly into the terminal PTY
    private static func tmuxSendKeys(_ text: String, session: String) async -> Bool {
        // tmux send-keys sends each character to the terminal's PTY
        // No window raising, no clipboard, no focus stealing
        let result = runShell("/opt/homebrew/bin/tmux", args: ["send-keys", "-t", session, text, "Enter"])
        return result != nil
    }

    // MARK: - Strategy 2: osascript

    /// Send text via AppleScript — targets the specific app process
    private static func osascriptSendText(_ text: String, to window: MonitoredWindow) async -> Bool {
        let project = extractProject(from: window)

        // Raise the correct window first
        WindowInteractionService.raiseByProjectName(
            project,
            windowID: window.id,
            ownerName: window.ownerName
        )

        // Wait for window to come to front
        try? await Task.sleep(for: .milliseconds(500))

        // Escape special characters for AppleScript
        let escaped = text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")

        // Target the specific app process by name
        let script = """
        tell application "System Events"
            tell process "\(window.ownerName)"
                set frontmost to true
                delay 0.1
                keystroke "\(escaped)"
                delay 0.05
                keystroke return
            end tell
        end tell
        """

        log("osascript targeting process: \(window.ownerName), project: \(project)")
        let result = runShell("/usr/bin/osascript", args: ["-e", script])
        return result != nil
    }

    // MARK: - Strategy 3: Clipboard Paste

    /// Send text via clipboard paste — raises window, focuses terminal, pastes, enters
    private static func clipboardPaste(_ text: String, to window: MonitoredWindow) async -> Bool {
        let project = extractProject(from: window)
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Raise the correct window
        WindowInteractionService.raiseByProjectName(
            project,
            windowID: window.id,
            ownerName: window.ownerName
        )

        try? await Task.sleep(for: .milliseconds(500))

        // Verify and retry if needed
        if !WindowInteractionService.verifyFrontWindow(contains: project) {
            WindowInteractionService.raiseByProjectName(
                project,
                windowID: window.id,
                ownerName: window.ownerName
            )
            try? await Task.sleep(for: .milliseconds(400))
        }

        // Use proven Maccy clipboard manager approach for reliable paste
        let src = CGEventSource(stateID: .combinedSessionState)

        // Suppress local keyboard events during paste to prevent interference
        src?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        // Command flag with physical key indicator (0x000008) — required for Electron apps
        let cmdFlag = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)

        // Focus the VS Code terminal pane with Ctrl+` first
        let ctrlFlag = CGEventFlags(rawValue: CGEventFlags.maskControl.rawValue | 0x000008)
        let tickDown = CGEvent(keyboardEventSource: src, virtualKey: 50, keyDown: true)
        let tickUp = CGEvent(keyboardEventSource: src, virtualKey: 50, keyDown: false)
        tickDown?.flags = ctrlFlag
        tickUp?.flags = ctrlFlag
        tickDown?.post(tap: .cgSessionEventTap)
        tickUp?.post(tap: .cgSessionEventTap)

        try? await Task.sleep(for: .milliseconds(200))

        // Cmd+V paste — flags on BOTH key-down and key-up (critical for Electron)
        let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        vDown?.flags = cmdFlag
        vUp?.flags = cmdFlag
        vDown?.post(tap: .cgSessionEventTap)
        vUp?.post(tap: .cgSessionEventTap)

        try? await Task.sleep(for: .milliseconds(100))

        // Enter
        let enterDown = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)
        let enterUp = CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)
        enterDown?.post(tap: .cgSessionEventTap)
        enterUp?.post(tap: .cgSessionEventTap)

        // Restore clipboard after a delay
        try? await Task.sleep(for: .milliseconds(300))
        pasteboard.clearContents()
        if let s = saved { pasteboard.setString(s, forType: .string) }

        log("Clipboard paste complete for project: \(project)")
        return true
    }

    // MARK: - Helpers

    private static func extractProject(from window: MonitoredWindow) -> String {
        let title = window.windowTitle
        if let dash = title.range(of: " — ", options: .backwards) {
            return String(title[dash.upperBound...])
        }
        return title
    }

    /// Run a shell command and return stdout, or nil on failure
    @discardableResult
    private nonisolated static func runShell(_ path: String, args: [String]) -> String? {
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
