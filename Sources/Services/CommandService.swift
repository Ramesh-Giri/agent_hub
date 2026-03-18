import Foundation
import AppKit

/// Sends commands to Claude Code terminals via VS Code REST Control extension.
/// Maps each project to the correct REST Control port by tracing:
/// project name → Claude PID (by CWD) → parent PID → extension host PID → listening port
@MainActor
final class CommandService {

    enum SendResult {
        case sent(method: String)
        case failed(reason: String)
    }

    /// Cached project → port mappings
    private static var portMap: [String: Int] = [:]

    // MARK: - Public API

    static func sendText(_ text: String, to window: MonitoredWindow) async -> SendResult {
        let project = extractProject(from: window)
        log("sendText: '\(text)' to \(project)")

        // Get the port for this project (cached or discovered)
        let port: Int
        if let cached = portMap[project.lowercased()] {
            port = cached
        } else if let discovered = await discoverPort(for: project) {
            portMap[project.lowercased()] = discovered
            port = discovered
        } else {
            return .failed(reason: "Can't find REST Control port for '\(project)'. Is VS Code REST Control extension installed?")
        }

        // Send
        if await restSend(text, port: port) {
            log("Sent to \(project) on port \(port)")
            return .sent(method: "port:\(port)")
        }

        // Port might have changed — retry
        portMap.removeValue(forKey: project.lowercased())
        if let newPort = await discoverPort(for: project) {
            portMap[project.lowercased()] = newPort
            if await restSend(text, port: newPort) {
                log("Sent to \(project) on port \(newPort) (retry)")
                return .sent(method: "port:\(newPort)")
            }
        }

        return .failed(reason: "Failed to send to '\(project)'")
    }

    static func resetPorts() { portMap.removeAll() }

    // MARK: - Port Discovery via PID Chain

    /// Discover the REST Control port for a project:
    /// project → Claude PID (by CWD) → parent PID → extension host PID group → listening port
    private static func discoverPort(for project: String) async -> Int? {
        // Step 1-3 on background thread (shell commands)
        let candidates = await withCheckedContinuation { (cont: CheckedContinuation<[Int], Never>) in
            DispatchQueue.global().async {
                cont.resume(returning: findCandidatePorts(for: project))
            }
        }

        // Step 4: test candidates with URLSession (async, no blocking)
        for port in candidates {
            if await testPortAsync(port) {
                log("Verified REST Control on port \(port) for \(project)")
                return port
            }
        }
        return nil
    }

    /// Find candidate REST Control ports for a project by PID chain.
    /// Returns ports belonging to the extension host PID group closest to Claude's parent.
    private nonisolated static func findCandidatePorts(for project: String) -> [Int] {
        guard let claudePID = findClaudePID(for: project) else {
            log("No Claude process found for: \(project)")
            return []
        }
        guard let parentPID = getParentPID(claudePID) else {
            log("Can't get parent PID for Claude \(claudePID)")
            return []
        }
        log("Claude PID \(claudePID), parent: \(parentPID)")

        let allPorts = findExtensionHostPorts()

        // Group ports by PID
        var portsByPID: [pid_t: [Int]] = [:]
        for (pid, port) in allPorts {
            portsByPID[pid, default: []].append(port)
        }

        // Find PID closest to parent
        var bestPID: pid_t?
        var bestDistance = Int.max
        for pid in portsByPID.keys {
            let distance = abs(Int(pid) - Int(parentPID))
            if distance < bestDistance {
                bestDistance = distance
                bestPID = pid
            }
        }

        guard let targetPID = bestPID, let ports = portsByPID[targetPID] else { return [] }
        log("Target PID \(targetPID) (distance \(bestDistance)), candidate ports: \(ports)")
        return ports
    }

    /// Find Claude process PID by matching CWD to project name
    private nonisolated static func findClaudePID(for project: String) -> pid_t? {
        guard let output = runShell("/bin/ps", args: ["-eo", "pid,tty,comm"]) else { return nil }

        var claudePIDs: [pid_t] = []
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("claude") && trimmed.contains("tty") {
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                if let pid = pid_t(parts.first ?? "") {
                    claudePIDs.append(pid)
                }
            }
        }

        for pid in claudePIDs {
            if let lsofOutput = runShell("/usr/sbin/lsof", args: ["-p", "\(pid)"]) {
                for line in lsofOutput.components(separatedBy: "\n") {
                    if line.contains("cwd") && line.lowercased().contains(project.lowercased()) {
                        return pid
                    }
                }
            }
        }
        return nil
    }

    /// Get parent PID of a process
    private nonisolated static func getParentPID(_ pid: pid_t) -> pid_t? {
        guard let output = runShell("/bin/ps", args: ["-p", "\(pid)", "-o", "ppid="]) else { return nil }
        return pid_t(output.trimmingCharacters(in: .whitespaces))
    }

    /// Find all VS Code extension host PIDs and their REST Control listening ports
    private nonisolated static func findExtensionHostPorts() -> [(pid: pid_t, port: Int)] {
        guard let output = runShell("/usr/sbin/lsof", args: ["-iTCP", "-sTCP:LISTEN", "-P", "-n"]) else { return [] }

        var results: [(pid: pid_t, port: Int)] = []
        var seenPorts: Set<Int> = []

        for line in output.components(separatedBy: "\n") {
            guard line.contains("Code") else { continue }
            // Extract PID (second field)
            let fields = line.split(separator: " ", maxSplits: 10)
            guard fields.count >= 9,
                  let pid = pid_t(fields[1]) else { continue }
            // Extract port from address field (e.g., "127.0.0.1:39733")
            let addrField = String(fields[8])
            guard let colonIdx = addrField.lastIndex(of: ":") else { continue }
            let portStr = addrField[addrField.index(after: colonIdx)...]
            guard let port = Int(portStr), port > 30000, !seenPorts.contains(port) else { continue }
            seenPorts.insert(port)
            results.append((pid: pid, port: port))
        }
        return results
    }

    /// Test if a port responds to REST Control (async, URLSession, no blocking)
    private static func testPortAsync(_ port: Int) async -> Bool {
        guard let url = URL(string: "http://localhost:\(port)") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 0.5
        req.httpBody = #"{"command":"workbench.action.terminal.focus"}"#.data(using: .utf8)
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return status == 200 && (body == "null" || body.isEmpty)
        } catch { return false }
    }

    // MARK: - REST Control API

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
            let respBody = String(data: data, encoding: .utf8) ?? ""
            return status == 200 && !respBody.contains("stack")
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

    private nonisolated static func log(_ msg: String) {
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
