import Foundation

/// Connects to a ttyd WebSocket to read terminal output and send keystrokes.
/// Parses Claude Code terminal output to detect prompts and status.
@MainActor
final class TerminalBridgeService: ObservableObject {
    @Published var isConnected = false
    @Published var lastOutput = ""
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

    /// Connect to ttyd on localhost
    func connect(port: Int = 7681) {
        guard let url = URL(string: "ws://localhost:\(port)/ws") else { return }
        let session = URLSession(configuration: .default)
        webSocket = session.webSocketTask(with: url)
        webSocket?.resume()
        isConnected = true
        receiveLoop()
    }

    /// Connect to a remote ttyd via ngrok URL with basic auth
    func connect(url: String, username: String = "agent", password: String = "") {
        guard var urlComp = URLComponents(string: url) else { return }
        urlComp.scheme = urlComp.scheme == "https" ? "wss" : "ws"
        urlComp.path = "/ws"
        guard let wsURL = urlComp.url else { return }

        let config = URLSessionConfiguration.default
        if !username.isEmpty {
            let cred = "\(username):\(password)"
            if let data = cred.data(using: .utf8) {
                config.httpAdditionalHeaders = [
                    "Authorization": "Basic \(data.base64EncodedString())"
                ]
            }
        }
        let session = URLSession(configuration: config)
        webSocket = session.webSocketTask(with: wsURL)
        webSocket?.resume()
        isConnected = true
        receiveLoop()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        activePrompt = nil
    }

    // MARK: - Send

    /// Send a text command (keystrokes) to the terminal
    func sendText(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        // ttyd protocol: type 0 = input
        var payload = Data([0])  // input type
        payload.append(data)
        webSocket?.send(.data(payload)) { _ in }
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

        if type == 0 {
            // Output data
            if let text = String(data: payload, encoding: .utf8) {
                Task { @MainActor [weak self] in
                    self?.processOutput(text)
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
        // Strip ANSI escape codes for clean text
        let clean = text.stripANSI()
        outputBuffer += clean

        // Keep buffer reasonable
        if outputBuffer.count > 5000 {
            outputBuffer = String(outputBuffer.suffix(3000))
        }

        // Update last output (last meaningful line)
        let lines = clean.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if let last = lines.last {
            lastOutput = last.trimmingCharacters(in: .whitespaces)
        }

        // Detect prompts
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

    // MARK: - Auto-connect from saved config

    func autoConnect() {
        // Check if ttyd is running locally
        let localURL = URL(string: "http://localhost:7681/")!
        var request = URLRequest(url: localURL, timeoutInterval: 2)
        request.httpMethod = "HEAD"
        URLSession.shared.dataTask(with: request) { [weak self] _, response, _ in
            if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                Task { @MainActor [weak self] in
                    self?.connect(port: 7681)
                    self?.sessionName = "Local Terminal"
                }
                return
            }

            // Check for saved ngrok config
            let configPath = FileManager.default.temporaryDirectory.path + "/agenthub-terminal.json"
            if let data = FileManager.default.contents(atPath: configPath),
               let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let url = config["url"] as? String,
               let password = config["password"] as? String,
               let session = config["session"] as? String {
                Task { @MainActor [weak self] in
                    self?.connect(url: url, username: "agent", password: password)
                    self?.sessionName = session
                }
            }
        }.resume()
    }
}

// MARK: - ANSI Stripping

extension String {
    func stripANSI() -> String {
        // Remove ANSI escape sequences
        replacingOccurrences(
            of: #"\x1B\[[0-9;]*[A-Za-z]|\x1B\][^\x07]*\x07|\x1B[()][0-9A-Za-z]"#,
            with: "",
            options: .regularExpression
        )
    }
}
