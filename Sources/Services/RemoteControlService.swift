import Foundation
import AppKit

/// Watches for Claude Code permission prompts via a lightweight hook.
/// The hook writes prompt info to ~/Library/Application Support/Canopy/ipc, this service reads it and publishes to UI.
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

    private static let promptDir: String = {
        let dir = NSHomeDirectory() + "/Library/Application Support/Canopy/ipc"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return dir
    }()
    private static let promptPrefix = "canopy-prompt-"

    func start() {
        Self.ensureRCEnabled()
        Self.installHook()
        // Don't write presence marker yet — only when user adds windows
        isConnected = true
        startWatching()
    }

    func stop() {
        watchTask?.cancel()
        watchTask = nil
        isConnected = false
        deactivateHook()
    }

    /// Write presence marker so the hook starts intercepting background prompts
    func activateHook() {
        FileManager.default.createFile(
            atPath: Self.promptDir + "/canopy-active", contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
    }

    /// Remove presence marker so the hook passes through everything
    func deactivateHook() {
        try? FileManager.default.removeItem(atPath: Self.promptDir + "/canopy-active")
    }

    /// Respond to the current prompt — writes response file that the blocking hook reads
    func respondToPrompt(allow: Bool) {
        guard let prompt = activePrompt else { return }
        let responsePath = Self.promptDir + "/canopy-response-" + prompt.id + ".json"
        let response: [String: Any] = ["allow": allow]
        if let data = try? JSONSerialization.data(withJSONObject: response) {
            FileManager.default.createFile(atPath: responsePath, contents: data,
                                           attributes: [.posixPermissions: 0o600])
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

        // If Canopy main window is active, auto-allow any prompts that slip through
        // (the hook should have passed them through, but stale files may exist)

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

    /// Install PreToolUse hook for permission prompt interception
    nonisolated static func installHook() {
        let fm = FileManager.default
        let hooksDir = NSHomeDirectory() + "/.claude/hooks"
        let scriptPath = hooksDir + "/canopy-prompt.js"

        if !fm.fileExists(atPath: hooksDir) {
            try? fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        }

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
                ($0["command"] as? String)?.contains("canopy-prompt") == true
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

    /// Blocking hook: waits for Canopy to respond with allow/deny
    /// Outputs the decision so Claude Code acts on it — no terminal dialog needed
    private nonisolated static let hookScript = """
    #!/usr/bin/env node
    const fs = require('fs');
    const crypto = require('crypto');
    const path = require('path');
    const ipcDir = process.env.HOME + '/Library/Application Support/Canopy/ipc';

    try {
      if (!fs.existsSync(ipcDir + '/canopy-active')) process.exit(0);

      const input = fs.readFileSync('/dev/stdin', 'utf8');
      if (!input.trim()) process.exit(0);

      const data = JSON.parse(input);
      const mode = data.permission_mode || 'default';

      // Only intercept in modes that show permission dialogs
      if (!['default', 'plan'].includes(mode)) process.exit(0);

      const tool = data.tool_name || '';
      if (!['Bash', 'Write', 'Edit'].includes(tool)) process.exit(0);

      // Don't block if user can see this project
      try {
        const frontProject = fs.readFileSync(ipcDir + '/canopy-frontmost.txt', 'utf8').trim();
        // Canopy main window is active — user sees all projects, pass through
        if (frontProject === '__CANOPY_ACTIVE__') process.exit(0);
        // Check if this project matches what the user is looking at
        const fp = frontProject.toLowerCase();
        const cwd = process.cwd().toLowerCase();
        const cwdParts = cwd.split('/').filter(Boolean);
        // Match if frontmost name appears in any CWD segment
        if (fp) {
          for (const seg of cwdParts) {
            if (seg === fp || seg.includes(fp) || fp.includes(seg)) process.exit(0);
          }
          // Also match full path containment
          if (cwd.includes(fp)) process.exit(0);
        }
      } catch {
        // Can't read frontmost file — pass through to be safe
        process.exit(0);
      }

      // Check if already allowed by settings
      const home = process.env.HOME;
      const toolInput = data.tool_input || {};
      const cmd = toolInput.command || '';
      const filePath = toolInput.file_path || '';
      let allowRules = [];

      // Load global settings
      try { allowRules = JSON.parse(fs.readFileSync(home + '/.claude/settings.json', 'utf8'))?.permissions?.allow || []; } catch {}

      // Load project-local settings
      try {
        const local = JSON.parse(fs.readFileSync(process.cwd() + '/.claude/settings.local.json', 'utf8'));
        allowRules = [...allowRules, ...(local?.permissions?.allow || [])];
      } catch {}

      // Also check user-level project settings (~/.claude/projects/<encoded-path>/settings.local.json)
      try {
        const encodedPath = process.cwd().replace(/\\//g, '-');
        const userProjectSettings = home + '/.claude/projects/' + encodedPath + '/settings.local.json';
        const ups = JSON.parse(fs.readFileSync(userProjectSettings, 'utf8'));
        allowRules = [...allowRules, ...(ups?.permissions?.allow || [])];
      } catch {}

      function matchesCommand(command, pattern) {
        if (!command) return false;
        if (command === pattern) return true;
        return command.startsWith(pattern) && ' \\t;|&'.includes(command[pattern.length]);
      }
      function matchesPath(fp, pattern) {
        if (!fp) return false;
        if (fp === pattern) return true;
        return fp.startsWith(pattern) && (pattern.endsWith('/') || fp[pattern.length] === '/');
      }

      // Check allow rules — supports both "Tool" and "Tool(pattern)" formats
      for (const r of allowRules) {
        if (typeof r !== 'string') continue;

        // Exact tool match: "Edit" allows all edits
        if (r === tool) process.exit(0);

        // Claude Code format: "Tool(pattern)" e.g. "Bash(git *)", "Edit(/path/*)"
        const m = r.match(/^(\\w+)\\((.+)\\)$/);
        if (m && m[1] === tool) {
          const pattern = m[2];

          // Glob-style match: convert * to .* for regex
          if (pattern.includes('*')) {
            try {
              const escaped = pattern.replace(/[.+^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*');
              const re = new RegExp('^' + escaped + '$');
              if (cmd && re.test(cmd)) process.exit(0);
              if (filePath && re.test(filePath)) process.exit(0);
            } catch {}
          }

          // Boundary-aware matching for commands and paths
          if (matchesCommand(cmd, pattern)) process.exit(0);
          if (matchesPath(filePath, pattern)) process.exit(0);
        }

        // Legacy format: "Tool:pattern"
        if (r.startsWith(tool + ':')) {
          const p = r.slice(tool.length + 1);
          if (matchesCommand(cmd, p)) process.exit(0);
          if (matchesPath(filePath, p)) process.exit(0);
        }
      }

      // This tool needs permission — block and wait for Canopy
      const uuid = crypto.randomUUID();
      const promptFile = ipcDir + '/canopy-prompt-' + uuid + '.json';
      const responseFile = ipcDir + '/canopy-response-' + uuid + '.json';
      data._cwd = process.cwd();
      data._uuid = uuid;
      fs.writeFileSync(promptFile, JSON.stringify(data, null, 2), { mode: 0o600 });

      const start = Date.now();
      const poll = () => {
        try {
          if (fs.existsSync(responseFile)) {
            const raw = fs.readFileSync(responseFile, 'utf8');
            try { fs.unlinkSync(responseFile); } catch {}
            try { fs.unlinkSync(promptFile); } catch {}
            const resp = JSON.parse(raw);
            process.stdout.write(JSON.stringify({
              hookSpecificOutput: {
                hookEventName: 'PreToolUse',
                permissionDecision: resp.allow ? 'allow' : 'deny',
                permissionDecisionReason: resp.allow ? 'Allowed from Canopy' : 'Denied from Canopy'
              }
            }));
            process.exit(0);
          }
        } catch(e) {}
        if (Date.now() - start > 120000) {
          try { fs.unlinkSync(promptFile); } catch {}
          process.exit(0);
        }
        setTimeout(poll, 200);
      };
      poll();
    } catch(e) {
      process.exit(0);
    }
    """
}
