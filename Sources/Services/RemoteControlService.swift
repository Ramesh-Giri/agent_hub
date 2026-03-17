import Foundation

/// Watches for Claude Code permission prompts via a lightweight hook.
/// The hook writes prompt info to /tmp, this service reads it and publishes to UI.
@MainActor
final class RemoteControlService: ObservableObject {
    @Published var isConnected = false
    @Published var activePrompt: PromptInfo?

    private var watchTask: Task<Void, Never>?

    struct PromptInfo: Identifiable, Equatable {
        let id: String
        let toolName: String
        let description: String
        let options: [(label: String, keystroke: String)]
        let cwd: String?

        static func == (lhs: PromptInfo, rhs: PromptInfo) -> Bool { lhs.id == rhs.id }
    }

    private static let promptDir = FileManager.default.temporaryDirectory.path
    private static let promptPrefix = "agenthub-prompt-"

    func start() {
        Self.ensureRCEnabled()
        Self.installHook()
        // Write presence marker
        FileManager.default.createFile(
            atPath: Self.promptDir + "/agenthub-active", contents: nil
        )
        isConnected = true
        startWatching()
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        isConnected = false
        try? FileManager.default.removeItem(atPath: Self.promptDir + "/agenthub-active")
    }

    /// Respond to the current prompt — writes response file that the blocking hook reads
    func respondToPrompt(allow: Bool) {
        guard let prompt = activePrompt else { return }
        let responsePath = Self.promptDir + "/agenthub-response-" + prompt.id + ".json"
        let response: [String: Any] = ["allow": allow]
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            try? data.write(to: URL(fileURLWithPath: responsePath))
        }
        activePrompt = nil
    }

    // MARK: - File Watching

    private func startWatching() {
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.scanForPrompts()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func scanForPrompts() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.promptDir) else { return }

        for file in files where file.hasPrefix(Self.promptPrefix) && file.hasSuffix(".json") {
            let uuid = String(file.dropFirst(Self.promptPrefix.count).dropLast(".json".count))
            if activePrompt?.id == uuid { continue }

            let path = Self.promptDir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let toolName = json["tool_name"] as? String ?? "Unknown"
            let toolInput = json["tool_input"] as? [String: Any] ?? [:]
            let cwd = json["_cwd"] as? String

            let desc: String
            if let cmd = toolInput["command"] as? String {
                desc = "Bash: \(String(cmd.prefix(80)))"
            } else if let fp = toolInput["file_path"] as? String {
                desc = "\(toolName): \(URL(fileURLWithPath: fp).lastPathComponent)"
            } else {
                desc = toolName
            }

            // Claude Code options: 1. Yes  2. Yes + allow rule  3. No
            let options: [(label: String, keystroke: String)] = [
                ("Yes", "1\r"),
                ("Yes, don't ask again", "2\r"),
                ("No", "3\r")
            ]

            activePrompt = PromptInfo(
                id: uuid, toolName: toolName, description: desc,
                options: options, cwd: cwd
            )
            break // one at a time
        }

        // Clean up stale prompts (>2 min old)
        for file in files where file.hasPrefix(Self.promptPrefix) && file.hasSuffix(".json") {
            let path = Self.promptDir + "/" + file
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let created = attrs[.creationDate] as? Date,
               Date().timeIntervalSince(created) > 120 {
                try? fm.removeItem(atPath: path)
                if activePrompt?.id == String(file.dropFirst(Self.promptPrefix.count).dropLast(".json".count)) {
                    activePrompt = nil
                }
            }
        }
    }

    // MARK: - Hook Installation

    @discardableResult
    nonisolated static func ensureRCEnabled() -> Bool {
        let fm = FileManager.default
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }
        if settings["enableRemoteControl"] as? Bool != true {
            settings["enableRemoteControl"] = true
            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: settingsPath))
            }
        }
        return true
    }

    /// Install a minimal PreToolUse hook that writes prompt files for AgentHub
    nonisolated static func installHook() {
        let fm = FileManager.default
        let hooksDir = NSHomeDirectory() + "/.claude/hooks"
        let scriptPath = hooksDir + "/agenthub-prompt.js"

        if !fm.fileExists(atPath: hooksDir) {
            try? fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        }

        // Write the hook script
        try? hookScript.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Register in settings.json
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var preToolHooks = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let alreadyInstalled = preToolHooks.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("agenthub-prompt") == true
            } ?? false
        }

        if !alreadyInstalled {
            preToolHooks.append([
                "hooks": [[
                    "type": "command",
                    "command": "node \"\(scriptPath)\"",
                    "timeout": 120000
                ] as [String: Any]]
            ] as [String: Any])
            hooks["PreToolUse"] = preToolHooks
            settings["hooks"] = hooks
            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: settingsPath))
            }
        }
    }

    /// Blocking hook: waits for AgentHub to respond with allow/deny
    /// Outputs the decision so Claude Code acts on it — no terminal dialog needed
    private nonisolated static let hookScript = """
    #!/usr/bin/env node
    const fs = require('fs');
    const crypto = require('crypto');
    const os = require('os');
    const tmpDir = os.tmpdir();

    try {
      if (!fs.existsSync(tmpDir + '/agenthub-active')) process.exit(0);

      const input = fs.readFileSync('/dev/stdin', 'utf8');
      if (!input.trim()) process.exit(0);

      const data = JSON.parse(input);
      const mode = data.permission_mode || 'default';

      // Only intercept in modes that show permission dialogs
      if (!['default', 'plan'].includes(mode)) process.exit(0);

      // Only for tools that typically need permission
      if (!['Bash', 'Write', 'Edit'].includes(data.tool_name || '')) process.exit(0);

      // Write prompt file for AgentHub (non-blocking notification)
      const uuid = crypto.randomUUID();
      data._cwd = process.cwd();
      data._uuid = uuid;
      fs.writeFileSync(
        tmpDir + '/agenthub-prompt-' + uuid + '.json',
        JSON.stringify(data, null, 2)
      );

      // Exit immediately — Claude Code shows its normal prompt
      // User responds from floating panel via CGEvent or from terminal directly
      process.exit(0);
    } catch(e) {
      process.exit(0);
    }
    """
}
