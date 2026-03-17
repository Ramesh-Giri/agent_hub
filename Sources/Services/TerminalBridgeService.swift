import Foundation

/// Connects to a ttyd WebSocket to read terminal output and send keystrokes.
/// Parses Claude Code terminal output to detect prompts and status.
@MainActor
final class TerminalBridgeService: ObservableObject {
    @Published var isConnected = false
    @Published var lastOutput = ""
    @Published var recentLines: [String] = []
    @Published var activePrompt: TerminalPrompt?
    @Published var sessionName = ""

    private var webSocket: URLSessionWebSocketTask?
    private var outputBuffer = ""

    struct TerminalPrompt: Identifiable {
        let id = UUID()
        let text: String
        let options: [String]  // e.g. ["Yes", "No"], ["Allow", "Deny"]
    }

    // MARK: - Connection

    /// Connect to ttyd on localhost — fetches token, connects WebSocket with tty subprotocol
    func connect(port: Int = 7681) {
        // Step 1: Get auth token
        let tokenURL = URL(string: "http://localhost:\(port)/token")!
        URLSession.shared.dataTask(with: tokenURL) { [weak self] data, _, _ in
            var token = ""
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                token = json["token"] as? String ?? ""
            }
            Task { @MainActor [weak self] in
                self?.connectWebSocket(port: port, token: token)
            }
        }.resume()
    }

    private func connectWebSocket(port: Int, token: String) {
        guard let url = URL(string: "ws://localhost:\(port)/ws?token=\(token)") else { return }

        var request = URLRequest(url: url)
        request.setValue("tty", forHTTPHeaderField: "Sec-WebSocket-Protocol")

        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: request)
        webSocket?.resume()

        // Send init message with auth token and terminal size
        let initMsg = "{\"AuthToken\":\"\(token)\",\"columns\":80,\"rows\":24}"
        webSocket?.send(.string(initMsg)) { [weak self] error in
            Task { @MainActor [weak self] in
                if error == nil {
                    self?.isConnected = true
                    self?.lastOutput = "Connected to terminal"
                } else {
                    self?.lastOutput = "Connection failed: \(error?.localizedDescription ?? "")"
                }
            }
        }
        receiveLoop()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        activePrompt = nil
    }

    // MARK: - Send

    @Published var debugInfo = ""

    /// Send a text command (keystrokes) to the terminal
    func sendText(_ text: String) {
        guard let textData = text.data(using: .utf8) else {
            debugInfo = "encode failed"
            return
        }
        guard let ws = webSocket else {
            debugInfo = "ws nil!"
            return
        }
        var payload = Data([0])
        payload.append(textData)
        debugInfo = "sending \(payload.count)b"
        ws.send(.data(payload)) { [weak self] error in
            Task { @MainActor [weak self] in
                if let error {
                    self?.debugInfo = "send err: \(error.localizedDescription)"
                } else {
                    self?.debugInfo = "sent ok"
                }
            }
        }
    }

    /// Send Enter key
    func sendEnter() {
        sendText("\r")
    }

    /// Send a numbered option (e.g. "1" for Yes, "2" for No)
    func sendOption(_ index: Int) {
        sendText("\(index)\r")
    }

    /// Send text + Enter
    func sendCommand(_ text: String) {
        sendText(text + "\r")
    }

    // MARK: - Receive

    private func receiveLoop() {
        webSocket?.receive { [weak self] result in
            switch result {
            case .success(let message):
                switch message {
                case .data(let data):
                    self?.handleMessage(data)
                case .string(let text):
                    self?.handleText(text)
                @unknown default:
                    break
                }
                Task { @MainActor [weak self] in
                    self?.receiveLoop()
                }
            case .failure:
                Task { @MainActor [weak self] in
                    self?.isConnected = false
                }
            }
        }
    }

    private nonisolated func handleMessage(_ data: Data) {
        guard data.count > 1 else { return }
        let type = data[0]
        let payload = data.suffix(from: 1)

        // ttyd types: 48 ('0') = output, 49 ('1') = title, 50 ('2') = prefs
        if type == 48 || type == 0 {
            if let text = String(data: payload, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.processOutput(text)
                }
            }
        } else if type == 49 || type == 1 {
            if let title = String(data: payload, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.sessionName = title
                }
            }
        }
    }

    private nonisolated func handleText(_ text: String) {
        Task { @MainActor [weak self] in
            self?.processOutput(text)
        }
    }

    // MARK: - Parse Terminal Output

    private func processOutput(_ text: String) {
        let clean = text.stripANSI()
        outputBuffer += clean

        if outputBuffer.count > 5000 {
            outputBuffer = String(outputBuffer.suffix(3000))
        }

        // Update recent lines for display
        let newLines = clean.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.count > 1 }
        for line in newLines {
            recentLines.append(line)
        }
        // Keep last 20 lines
        if recentLines.count > 20 {
            recentLines = Array(recentLines.suffix(20))
        }

        if let last = newLines.last {
            lastOutput = last
        }

        detectPrompt()
    }

    private func detectPrompt() {
        let lines = outputBuffer.components(separatedBy: .newlines)
        let recentLines = lines.suffix(15).map { $0.trimmingCharacters(in: .whitespaces) }
        let recentText = recentLines.joined(separator: "\n")

        // Pattern: "Do you want to proceed?" with numbered options
        if recentText.contains("Do you want to") || recentText.contains("want to proceed") {
            var options: [String] = []
            var promptText = ""
            for line in recentLines {
                if line.contains("Do you want") || line.contains("want to proceed") {
                    promptText = line
                }
                // Match "1. Yes", "2. No", etc.
                if let match = line.range(of: #"^\d+\.\s+(.+)"#, options: .regularExpression) {
                    let option = String(line[match]).replacingOccurrences(of: #"^\d+\.\s+"#, with: "", options: .regularExpression)
                    options.append(option)
                }
            }
            if !options.isEmpty {
                activePrompt = TerminalPrompt(text: promptText, options: options)
                return
            }
        }

        // Pattern: "(y/n)" prompts
        if recentText.contains("(y/n)") || recentText.contains("(Y/n)") {
            let promptLine = recentLines.last { $0.contains("(y/n)") || $0.contains("(Y/n)") } ?? "Confirm?"
            activePrompt = TerminalPrompt(text: promptLine, options: ["Yes", "No"])
            return
        }

        // No active prompt
        activePrompt = nil
    }

    private static let ttydPort = 7681
    private var ttydProcess: Process?

    // MARK: - Auto-start & connect

    /// Automatically starts ttyd (if not running) and connects via WebSocket
    func autoConnect() {
        // First check if ttyd is already running
        checkAndConnect { [weak self] connected in
            if !connected {
                // Start ttyd ourselves
                self?.startTtyd { success in
                    if success {
                        // Wait for ttyd to be ready, then connect
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            self?.checkAndConnect { _ in }
                        }
                    }
                }
            }
        }
    }

    private func checkAndConnect(completion: @escaping (Bool) -> Void) {
        let localURL = URL(string: "http://localhost:\(Self.ttydPort)/")!
        var request = URLRequest(url: localURL, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                Task { @MainActor [weak self] in
                    self?.connect(port: Self.ttydPort)
                    self?.sessionName = "Claude Terminal"
                }
                completion(true)
            } else {
                completion(false)
            }
        }.resume()
    }

    /// Starts ttyd serving a zsh shell on the configured port
    nonisolated private func startTtyd(completion: @escaping (Bool) -> Void) {
        let ttydPath = "/opt/homebrew/bin/ttyd"
        guard FileManager.default.fileExists(atPath: ttydPath) else {
            completion(false)
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: ttydPath)
        proc.arguments = [
            "-p", "\(Self.ttydPort)",
            "-t", "fontSize=13",
            "-t", "theme={\"background\":\"#1a1a2e\",\"foreground\":\"#e0e0e0\"}",
            "/bin/zsh"
        ]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
            Task { @MainActor [weak self] in
                self?.ttydProcess = proc
            }
            completion(true)
        } catch {
            completion(false)
        }
    }

    /// Stop ttyd when service is deallocated
    func stopTtyd() {
        ttydProcess?.terminate()
        ttydProcess = nil
    }
}

// MARK: - ANSI Stripping

extension String {
    func stripANSI() -> String {
        replacingOccurrences(
            of: #"\x1B\[[\?\!]?[0-9;]*[A-Za-z]|\x1B\][^\x07\x1B]*(?:\x07|\x1B\\)|\x1B[()][0-9A-Za-z]|\x1B\[[\?]?[0-9;]*[hl]|\r"#,
            with: "",
            options: .regularExpression
        )
        .replacingOccurrences(of: "\u{07}", with: "")  // bell
        .replacingOccurrences(of: "\u{1B}", with: "")  // stray ESC
    }
}
