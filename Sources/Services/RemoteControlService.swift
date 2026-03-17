import Foundation

/// Ensures Remote Control is enabled in Claude Code settings
/// so sessions appear at claude.ai/code for the floating panel WKWebView.
@MainActor
final class RemoteControlService: ObservableObject {
    @Published var isConnected = false

    func start() {
        isConnected = Self.ensureRCEnabled()
    }

    /// Ensures enableRemoteControl is true in ~/.claude/settings.json
    @discardableResult
    nonisolated static func ensureRCEnabled() -> Bool {
        let fm = FileManager.default
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"

        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        // Check if already enabled
        if settings["enableRemoteControl"] as? Bool == true {
            return true
        }

        // Enable it
        settings["enableRemoteControl"] = true
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
        return true
    }

    /// Remove the old hook script if it exists (no longer needed — RC web UI handles prompts)
    nonisolated static func cleanupOldHook() {
        let fm = FileManager.default
        let scriptPath = NSHomeDirectory() + "/.claude/hooks/agenthub-prompt.js"

        // Remove hook script
        if fm.fileExists(atPath: scriptPath) {
            try? fm.removeItem(atPath: scriptPath)
        }

        // Remove hook entry from settings.json
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        guard let data = fm.contents(atPath: settingsPath),
              var settings = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              var hooks = settings["hooks"] as? [String: Any],
              var preToolHooks = hooks["PreToolUse"] as? [[String: Any]]
        else { return }

        preToolHooks.removeAll { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { h in
                (h["command"] as? String)?.contains("agenthub-prompt") == true
            }
        }

        if preToolHooks.isEmpty {
            hooks.removeValue(forKey: "PreToolUse")
        } else {
            hooks["PreToolUse"] = preToolHooks
        }

        if hooks.isEmpty {
            settings.removeValue(forKey: "hooks")
        } else {
            settings["hooks"] = hooks
        }

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }

        // Clean up presence marker
        try? fm.removeItem(atPath: fm.temporaryDirectory.path + "/agenthub-active")
    }
}
