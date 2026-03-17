import Foundation
import AppKit

/// Intercepts Claude Code permission prompts via the hooks system.
/// Uses file-based IPC: a PreToolUse hook script writes prompt files to /tmp,
/// this service watches for them, shows them in the UI, and writes response files.
/// If AgentHub isn't running, the hook script fails and falls through to the normal prompt.
@MainActor
final class RemoteControlService: ObservableObject {
    @Published var isConnected = false
    @Published var error: String?
    @Published var activePrompt: ControlPrompt?
    @Published var pendingPrompts: [ControlPrompt] = []

    private var watchTask: Task<Void, Never>?
    private var activePromptUUID: String?

    private static let promptPrefix = "agenthub-prompt-"
    private static let responsePrefix = "agenthub-response-"
    private static let promptDir = FileManager.default.temporaryDirectory.path

    // MARK: - Models

    struct PermissionSuggestion: Identifiable {
        let id = UUID()
        let type: String
        let rules: [[String: Any]]?
        let behavior: String?
        let mode: String?
        let destination: String?
        let label: String
    }

    struct AskOption: Identifiable {
        let id = UUID()
        let label: String
        let description: String?
    }

    struct ControlPrompt: Identifiable {
        let id: String              // UUID from filename
        let sessionId: String?
        let cwd: String?            // working directory of the session
        let projectName: String?    // last path component of cwd
        let toolName: String
        let toolUseId: String?
        let toolInput: [String: Any]
        let displayText: String
        let permissionSuggestions: [PermissionSuggestion]
        let askOptions: [AskOption]
        let isAskQuestion: Bool
    }

    // MARK: - Lifecycle

    private static let presenceFile = FileManager.default.temporaryDirectory.path + "/agenthub-active"

    func start() {
        guard watchTask == nil else { return }
        // Clean up any stale prompt files from a previous instance
        Self.cleanupStaleFiles()
        let hookOk = Self.ensureHookInstalled()
        isConnected = hookOk
        if !hookOk {
            error = "Hook not installed — check ~/.claude/settings.json"
        }
        // Write presence marker so hook knows we're listening
        FileManager.default.createFile(atPath: Self.presenceFile, contents: nil)
        Self.log("Starting file watcher (hook installed: \(hookOk))")
        startWatching()
    }

    /// Remove prompt/response files left from a previous (killed) instance
    private static func cleanupStaleFiles() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: promptDir) else { return }
        for file in files where (file.hasPrefix(promptPrefix) || file.hasPrefix(responsePrefix)) && file.hasSuffix(".json") {
            let path = promptDir + "/" + file
            try? fm.removeItem(atPath: path)
        }
        log("Cleaned up stale prompt files on launch")
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        isConnected = false
        try? FileManager.default.removeItem(atPath: Self.presenceFile)
    }

    // MARK: - Respond to prompts

    func respondToPrompt(allow: Bool, applySuggestion: PermissionSuggestion? = nil) {
        guard let prompt = activePrompt else { return }
        var decision: [String: Any] = ["decision": allow ? "allow" : "deny"]
        if !allow {
            decision["reason"] = "Denied from AgentHub"
        }
        writeResponse(uuid: prompt.id, decision: decision)

        // If "Always Allow" suggestion selected, write permission rule to project settings
        if let suggestion = applySuggestion {
            applyPermissionSuggestion(suggestion, toolName: prompt.toolName)
        }

        advancePromptQueue()
    }

    func respondToQuestion(answer: String) {
        guard let prompt = activePrompt, prompt.isAskQuestion else { return }
        let decision: [String: Any] = ["decision": "allow"]
        writeResponse(uuid: prompt.id, decision: decision)
        advancePromptQueue()
    }

    // MARK: - File Watching

    private func startWatching() {
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.scanForPrompts()
                try? await Task.sleep(for: .milliseconds(800))
            }
        }
    }

    private func scanForPrompts() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: Self.promptDir) else { return }

        for file in files where file.hasPrefix(Self.promptPrefix) && file.hasSuffix(".json") {
            let uuid = String(file
                .dropFirst(Self.promptPrefix.count)
                .dropLast(".json".count))

            // Skip if we already have this prompt
            if activePrompt?.id == uuid || pendingPrompts.contains(where: { $0.id == uuid }) {
                continue
            }

            // Skip if already responded
            let responsePath = Self.promptDir + "/" + Self.responsePrefix + uuid + ".json"
            if fm.fileExists(atPath: responsePath) { continue }

            let path = Self.promptDir + "/" + file
            guard let data = fm.contents(atPath: path),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let prompt = parsePromptFile(uuid: uuid, json: json)
            Self.log("Found prompt: \(prompt.toolName) — \(prompt.displayText)")

            if activePrompt == nil {
                activePrompt = prompt
                activePromptUUID = uuid
            } else {
                pendingPrompts.append(prompt)
            }
        }

        // Clean up stale prompt files (older than 3 minutes with no response)
        for file in files where file.hasPrefix(Self.promptPrefix) && file.hasSuffix(".json") {
            let path = Self.promptDir + "/" + file
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let created = attrs[.creationDate] as? Date,
               Date().timeIntervalSince(created) > 180 {
                let uuid = String(file.dropFirst(Self.promptPrefix.count).dropLast(".json".count))
                // Write a timeout response so the hook script exits
                let responsePath = Self.promptDir + "/" + Self.responsePrefix + uuid + ".json"
                if !fm.fileExists(atPath: responsePath) {
                    try? "{}".data(using: .utf8)?.write(to: URL(fileURLWithPath: responsePath))
                }
                try? fm.removeItem(atPath: path)
            }
        }
    }

    // MARK: - Parsing

    private func parsePromptFile(uuid: String, json: [String: Any]) -> ControlPrompt {
        let sessionId = json["session_id"] as? String
        let cwd = json["_cwd"] as? String
        let projectName = cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
        let toolName = json["tool_name"] as? String ?? "Unknown"
        let toolUseId = json["tool_use_id"] as? String
        let toolInput = json["tool_input"] as? [String: Any] ?? [:]

        let suggestions = Self.parsePermissionSuggestions(
            json["permission_suggestions"] as? [[String: Any]]
        )

        let isAsk = toolName == "AskUserQuestion"
        let askOptions = isAsk ? Self.parseAskOptions(toolInput) : []

        let displayText = Self.buildDisplayText(
            toolName: toolName,
            toolInput: toolInput,
            description: json["description"] as? String,
            isAsk: isAsk
        )

        return ControlPrompt(
            id: uuid,
            sessionId: sessionId,
            cwd: cwd,
            projectName: projectName,
            toolName: toolName,
            toolUseId: toolUseId,
            toolInput: toolInput,
            displayText: displayText,
            permissionSuggestions: suggestions,
            askOptions: askOptions,
            isAskQuestion: isAsk
        )
    }

    // MARK: - Response Writing

    private func writeResponse(uuid: String, decision: [String: Any]) {
        let responsePath = Self.promptDir + "/" + Self.responsePrefix + uuid + ".json"
        if let data = try? JSONSerialization.data(withJSONObject: decision) {
            try? data.write(to: URL(fileURLWithPath: responsePath))
            Self.log("Wrote response for \(uuid): \(decision)")
        }
        // Clean up prompt file
        let promptPath = Self.promptDir + "/" + Self.promptPrefix + uuid + ".json"
        try? FileManager.default.removeItem(atPath: promptPath)
    }

    private func advancePromptQueue() {
        activePrompt = nil
        activePromptUUID = nil
        if !pendingPrompts.isEmpty {
            let next = pendingPrompts.removeFirst()
            activePrompt = next
            activePromptUUID = next.id
        }
    }

    private func applyPermissionSuggestion(_ suggestion: PermissionSuggestion, toolName: String) {
        // Write an "allow" rule to the project's .claude/settings.local.json
        // This makes the "Always Allow" persistent across sessions
        guard suggestion.type == "addRules" || suggestion.type == "replaceRules",
              let rules = suggestion.rules else { return }

        let cwd = Self.findTrustedCwd()
        let settingsPath = cwd + "/.claude/settings.local.json"
        let fm = FileManager.default

        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        var permissions = settings["permissions"] as? [String: Any] ?? [:]
        var allowList = permissions["allow"] as? [Any] ?? []

        for rule in rules {
            if let content = rule["ruleContent"] as? String {
                // Add as tool-specific rule: "ToolName:pattern"
                let ruleStr = "\(toolName):\(content)"
                if !allowList.contains(where: { ($0 as? String) == ruleStr }) {
                    allowList.append(ruleStr)
                }
            }
        }

        permissions["allow"] = allowList
        settings["permissions"] = permissions

        // Ensure directory exists
        let claudeDir = cwd + "/.claude"
        if !fm.fileExists(atPath: claudeDir) {
            try? fm.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
        }

        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
            Self.log("Applied permission rule to \(settingsPath)")
        }
    }

    // MARK: - Hook Installation

    /// Ensures the PreToolUse hook script and settings entry exist
    @discardableResult
    nonisolated static func ensureHookInstalled() -> Bool {
        let fm = FileManager.default
        let hooksDir = NSHomeDirectory() + "/.claude/hooks"
        let scriptPath = hooksDir + "/agenthub-prompt.js"

        // Create hooks directory
        if !fm.fileExists(atPath: hooksDir) {
            try? fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        }

        // Write/update hook script
        let script = Self.hookScript
        try? script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        // Update settings.json to register the hook
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        let hookEntry: [String: Any] = [
            "hooks": [[
                "type": "command",
                "command": "node \"\(scriptPath)\"",
                "timeout": 120000
            ] as [String: Any]]
        ]

        // Add PreToolUse hook if not present
        var preToolHooks = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let isAlreadyInstalled = preToolHooks.contains { entry in
            guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
            return entryHooks.contains { h in
                (h["command"] as? String)?.contains("agenthub-prompt") == true
            }
        }

        if !isAlreadyInstalled {
            preToolHooks.append(hookEntry)
            hooks["PreToolUse"] = preToolHooks
            settings["hooks"] = hooks

            if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: settingsPath))
                log("Installed PreToolUse hook in settings.json")
            }
        }

        return fm.fileExists(atPath: scriptPath)
    }

    /// The Node.js hook script that bridges Claude Code → AgentHub via temp files
    private nonisolated static let hookScript = """
    #!/usr/bin/env node
    const fs = require('fs');
    const path = require('path');
    const crypto = require('crypto');
    const os = require('os');

    const tmpDir = os.tmpdir();
    const logFile = path.join(tmpDir, 'agenthub-hook.log');
    const log = (msg) => { try { fs.appendFileSync(logFile, new Date().toISOString() + ' ' + msg + '\\n'); } catch {} };

    try {
      // If AgentHub isn't running, fall through immediately
      if (!fs.existsSync(path.join(tmpDir, 'agenthub-active'))) {
        process.exit(0);
      }

      const input = fs.readFileSync('/dev/stdin', 'utf8');
      if (!input || !input.trim()) { process.exit(0); }

      const data = JSON.parse(input);
      const tool = data.tool_name || '';

      // Only intercept destructive tools that need explicit user permission
      const needsPermission = ['Bash', 'Write', 'Edit'];
      if (!needsPermission.includes(tool)) {
        process.exit(0);
      }

      // Check if this tool+input is already allowed in settings
      const home = process.env.HOME;
      let allowRules = [];
      try { allowRules = JSON.parse(fs.readFileSync(path.join(home, '.claude', 'settings.json'), 'utf8'))?.permissions?.allow || []; } catch {}
      try {
        const local = JSON.parse(fs.readFileSync(path.join(process.cwd(), '.claude', 'settings.local.json'), 'utf8'));
        allowRules = [...allowRules, ...(local?.permissions?.allow || [])];
      } catch {}

      const toolInput = data.tool_input || {};
      const cmd = toolInput.command || '';
      const filePath = toolInput.file_path || '';
      const isAllowed = allowRules.some(r => {
        if (typeof r !== 'string') return false;
        if (r === tool) return true;
        if (!r.startsWith(tool + ':')) return false;
        const pattern = r.slice(tool.length + 1);
        if (cmd && (cmd.startsWith(pattern) || cmd.includes(pattern))) return true;
        if (filePath && filePath.includes(pattern)) return true;
        return false;
      });
      if (isAllowed) {
        process.exit(0);
      }

      const uuid = crypto.randomUUID();
      const promptFile = path.join(tmpDir, `agenthub-prompt-${uuid}.json`);
      const responseFile = path.join(tmpDir, `agenthub-response-${uuid}.json`);

      data._cwd = process.cwd();
      data._uuid = uuid;

      fs.writeFileSync(promptFile, JSON.stringify(data, null, 2));
      log('Wrote prompt: ' + tool + ' uuid=' + uuid);

      // Poll for response (max 2 minutes)
      const start = Date.now();
      const poll = () => {
        try {
          if (fs.existsSync(responseFile)) {
            const raw = fs.readFileSync(responseFile, 'utf8');
            try { fs.unlinkSync(responseFile); } catch {}
            const response = JSON.parse(raw);
            log('Got response: ' + JSON.stringify(response));
            if (response.decision) {
              process.stdout.write(JSON.stringify(response));
            }
            process.exit(0);
          }
        } catch(e) { log('Poll error: ' + e.message); }

        if (Date.now() - start > 120000) {
          try { fs.unlinkSync(promptFile); } catch {}
          log('Timeout for uuid=' + uuid);
          process.exit(1);
        }
        setTimeout(poll, 200);
      };
      poll();
    } catch(e) {
      const log2 = (msg) => { try { fs.appendFileSync(path.join(os.tmpdir(), 'agenthub-hook.log'), new Date().toISOString() + ' ' + msg + '\\n'); } catch {} };
      log2('FATAL: ' + e.message);
      process.exit(1);
    }
    """

    // MARK: - Helpers

    private nonisolated static func parsePermissionSuggestions(
        _ raw: [[String: Any]]?
    ) -> [PermissionSuggestion] {
        guard let raw else { return [] }
        return raw.compactMap { s in
            let type = s["type"] as? String ?? ""
            let rules = s["rules"] as? [[String: Any]]
            let behavior = s["behavior"] as? String
            let mode = s["mode"] as? String
            let destination = s["destination"] as? String

            let label: String
            switch type {
            case "addRules", "replaceRules":
                label = "Always Allow"
            case "setMode":
                switch mode {
                case "dontAsk": label = "Don't Ask Again"
                case "acceptEdits": label = "Accept Edits Mode"
                case "bypassPermissions": label = "Bypass All"
                default: label = "Set \(mode ?? "unknown") Mode"
                }
            default:
                label = type
            }

            return PermissionSuggestion(
                type: type, rules: rules, behavior: behavior,
                mode: mode, destination: destination, label: label
            )
        }
    }

    private nonisolated static func parseAskOptions(_ toolInput: [String: Any]) -> [AskOption] {
        guard let questions = toolInput["questions"] as? [[String: Any]] else { return [] }
        var options: [AskOption] = []
        for q in questions {
            if let opts = q["options"] as? [[String: Any]] {
                for opt in opts {
                    let label = opt["label"] as? String ?? ""
                    let desc = opt["description"] as? String
                    options.append(AskOption(label: label, description: desc))
                }
            }
        }
        return options
    }

    private nonisolated static func buildDisplayText(
        toolName: String,
        toolInput: [String: Any],
        description: String?,
        isAsk: Bool
    ) -> String {
        if isAsk {
            if let questions = toolInput["questions"] as? [[String: Any]],
               let q = questions.first,
               let question = q["question"] as? String {
                return question
            }
            return "Claude has a question"
        }

        if let filePath = toolInput["file_path"] as? String {
            return "Allow \(toolName) on \(URL(fileURLWithPath: filePath).lastPathComponent)?"
        }
        if let command = toolInput["command"] as? String {
            let short = String(command.prefix(60))
            return "Allow \(toolName): \(short)\(command.count > 60 ? "..." : "")?"
        }
        if let desc = description, !desc.isEmpty {
            return desc
        }
        return "Allow \(toolName)?"
    }

    nonisolated static func findTrustedCwd() -> String {
        let sessionsDir = NSHomeDirectory() + "/.claude/sessions"
        if let files = try? FileManager.default.contentsOfDirectory(atPath: sessionsDir) {
            for file in files where file.hasSuffix(".json") {
                let path = sessionsDir + "/" + file
                if let data = FileManager.default.contents(atPath: path),
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let cwd = json["cwd"] as? String,
                   FileManager.default.fileExists(atPath: cwd) {
                    return cwd
                }
            }
        }
        return NSHomeDirectory()
    }

    private nonisolated static let logFile: URL = {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("agenthub-rc-bridge.log")
        try? "".write(to: path, atomically: true, encoding: .utf8)
        return path
    }()

    nonisolated static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        NSLog("[AgentHub RC] %@", message)
        if let data = line.data(using: .utf8),
           let fh = try? FileHandle(forWritingTo: logFile) {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        }
    }

    deinit {
        watchTask?.cancel()
    }
}
