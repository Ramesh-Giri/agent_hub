import Foundation
import AppKit

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
            atPath: Self.promptDir + "/canopy-active", contents: nil
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

        // If Canopy main window is active, auto-allow any prompts that slip through
        // (the hook should have passed them through, but stale files may exist)
        let canopyIsActive = NSApp.isActive

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

    /// Install hooks: PreToolUse (prompt interception) + SessionStart (input watcher)
    nonisolated static func installHook() {
        let fm = FileManager.default
        let hooksDir = NSHomeDirectory() + "/.claude/hooks"
        let promptScriptPath = hooksDir + "/canopy-prompt.js"
        let inputWatcherPath = hooksDir + "/canopy-input-watcher.sh"

        if !fm.fileExists(atPath: hooksDir) {
            try? fm.createDirectory(atPath: hooksDir, withIntermediateDirectories: true)
        }

        // Write the PreToolUse hook script
        try? hookScript.write(toFile: promptScriptPath, atomically: true, encoding: .utf8)

        // Write the input watcher script (started by SessionStart hook)
        try? inputWatcherScript.write(toFile: inputWatcherPath, atomically: true, encoding: .utf8)
        // Make it executable
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: inputWatcherPath)

        // Register hooks in settings.json
        let settingsPath = NSHomeDirectory() + "/.claude/settings.json"
        var settings: [String: Any] = [:]
        if let data = fm.contents(atPath: settingsPath),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = existing
        }

        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        // PreToolUse hook
        var preToolHooks = hooks["PreToolUse"] as? [[String: Any]] ?? []
        let promptInstalled = preToolHooks.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("canopy-prompt") == true
            } ?? false
        }
        if !promptInstalled {
            preToolHooks.append([
                "hooks": [[
                    "type": "command",
                    "command": "node \"\(promptScriptPath)\"",
                    "timeout": 120000
                ] as [String: Any]]
            ] as [String: Any])
            hooks["PreToolUse"] = preToolHooks
        }

        // SessionStart hook — starts the input watcher in background
        var sessionHooks = hooks["SessionStart"] as? [[String: Any]] ?? []
        let watcherInstalled = sessionHooks.contains { entry in
            (entry["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("canopy-input-watcher") == true
            } ?? false
        }
        if !watcherInstalled {
            sessionHooks.append([
                "hooks": [[
                    "type": "command",
                    "command": "\"\(inputWatcherPath)\"",
                    "timeout": 5000
                ] as [String: Any]]
            ] as [String: Any])
            hooks["SessionStart"] = sessionHooks
        }

        settings["hooks"] = hooks
        if let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
    }

    /// Input watcher script — runs at SessionStart, watches for command files
    /// and injects them by writing to the terminal's master PTY fd (inherited from parent)
    private nonisolated static let inputWatcherScript = """
    #!/bin/bash
    # Canopy input watcher — started by Claude Code SessionStart hook
    # Watches for command files and injects text into this terminal

    TMPDIR=$(python3 -c "import tempfile; print(tempfile.gettempdir())" 2>/dev/null || echo "/tmp")

    # Write our PID file so Canopy knows which processes are being watched
    CLAUDE_PID=$PPID
    echo "$CLAUDE_PID" > "$TMPDIR/canopy-watcher-$CLAUDE_PID.pid"
    CMD_FILE="$TMPDIR/canopy-cmd-$CLAUDE_PID.txt"

    # Background watcher — polls for command files
    (
        while kill -0 $CLAUDE_PID 2>/dev/null; do
            if [ -f "$CMD_FILE" ]; then
                TEXT=$(cat "$CMD_FILE" 2>/dev/null)
                rm -f "$CMD_FILE" 2>/dev/null
                if [ -n "$TEXT" ]; then
                    # Use AppleScript to type into THIS terminal
                    # The watcher knows its own TTY, so we find the right VS Code window
                    TTY=$(ps -p $CLAUDE_PID -o tty= 2>/dev/null | tr -d ' ')

                    # Write to parent's stdin fd if available
                    if [ -w "/proc/$CLAUDE_PID/fd/0" ] 2>/dev/null; then
                        printf '%s\\n' "$TEXT" > /proc/$CLAUDE_PID/fd/0
                    else
                        # macOS: use osascript to type, but first write a marker
                        # so CommandService knows the watcher is active
                        echo "received" > "$CMD_FILE.ack"
                    fi
                fi
            fi
            sleep 0.3
        done
        # Cleanup on exit
        rm -f "$TMPDIR/canopy-watcher-$CLAUDE_PID.pid" 2>/dev/null
    ) &

    exit 0
    """

    /// Blocking hook: waits for Canopy to respond with allow/deny
    /// Outputs the decision so Claude Code acts on it — no terminal dialog needed
    private nonisolated static let hookScript = """
    #!/usr/bin/env node
    const fs = require('fs');
    const crypto = require('crypto');
    const path = require('path');
    const os = require('os');
    const tmpDir = os.tmpdir();

    try {
      if (!fs.existsSync(tmpDir + '/canopy-active')) process.exit(0);

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
        const frontProject = fs.readFileSync(tmpDir + '/canopy-frontmost.txt', 'utf8').trim();
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

      // Check allow rules — supports both "Tool" and "Tool(pattern)" formats
      for (const r of allowRules) {
        if (typeof r !== 'string') continue;

        // Exact tool match: "Edit" allows all edits
        if (r === tool) process.exit(0);

        // Claude Code format: "Tool(pattern)" e.g. "Bash(git *)", "Edit(/path/*)"
        const m = r.match(/^(\\w+)\\((.+)\\)$/);
        if (m && m[1] === tool) {
          const pattern = m[2];

          // Direct substring match
          if (cmd && cmd.includes(pattern)) process.exit(0);
          if (filePath && filePath.includes(pattern)) process.exit(0);

          // Glob-style match: convert * to .* for regex
          if (pattern.includes('*')) {
            try {
              const escaped = pattern.replace(/[.+^${}()|[\\]\\\\]/g, '\\\\$&').replace(/\\*/g, '.*');
              const re = new RegExp('^' + escaped + '$');
              if (cmd && re.test(cmd)) process.exit(0);
              if (filePath && re.test(filePath)) process.exit(0);
            } catch {}
          }

          // Path prefix match: "Edit(/Users/x/project)" matches files under that dir
          if (filePath && filePath.startsWith(pattern)) process.exit(0);
          if (cmd && cmd.startsWith(pattern)) process.exit(0);
        }

        // Legacy format: "Tool:pattern"
        if (r.startsWith(tool + ':')) {
          const p = r.slice(tool.length + 1);
          if (cmd && cmd.includes(p)) process.exit(0);
          if (filePath && filePath.includes(p)) process.exit(0);
        }
      }

      // This tool needs permission — block and wait for Canopy
      const uuid = crypto.randomUUID();
      const promptFile = tmpDir + '/canopy-prompt-' + uuid + '.json';
      const responseFile = tmpDir + '/canopy-response-' + uuid + '.json';
      data._cwd = process.cwd();
      data._uuid = uuid;
      fs.writeFileSync(promptFile, JSON.stringify(data, null, 2));

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
