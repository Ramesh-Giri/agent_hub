import Foundation
import Network

/// Bonjour TCP server that lets the iOS companion app discover and control AgentHub.
/// Protocol: newline-delimited JSON messages over TCP.
@MainActor
final class NetworkServer: ObservableObject {
    @Published var isRunning = false
    @Published var connectedClients = 0

    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let serviceType = "_agenthub._tcp"

    /// Callback when a command is received from iOS
    var onCommand: ((RemoteCommand) -> Void)?

    func start() {
        guard !isRunning else { return }

        do {
            let params = NWParameters.tcp
            listener = try NWListener(using: params)
        } catch {
            return
        }

        listener?.service = NWListener.Service(type: serviceType)

        listener?.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    self?.isRunning = true
                case .failed, .cancelled:
                    self?.isRunning = false
                default:
                    break
                }
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.handleNewConnection(connection)
            }
        }

        listener?.start(queue: .main)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for conn in connections {
            conn.cancel()
        }
        connections.removeAll()
        isRunning = false
        connectedClients = 0
    }

    /// Broadcast window list to all connected iOS clients
    func broadcastWindowList(_ windows: [WindowInfo]) {
        let message = ServerMessage(type: .windowList, windows: windows)
        guard let data = try? JSONEncoder().encode(message),
              let jsonString = String(data: data, encoding: .utf8) else { return }
        let line = jsonString + "\n"
        guard let lineData = line.data(using: .utf8) else { return }

        for connection in connections {
            connection.send(content: lineData, completion: .contentProcessed { _ in })
        }
    }

    // MARK: - Private

    private func handleNewConnection(_ connection: NWConnection) {
        connections.append(connection)
        connectedClients = connections.count

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.removeConnection(connection) }
                if case .cancelled = state { self?.removeConnection(connection) }
            }
        }

        connection.start(queue: .main)
        receiveMessages(from: connection)
    }

    private func removeConnection(_ connection: NWConnection) {
        connections.removeAll { $0 === connection }
        connectedClients = connections.count
    }

    private func receiveMessages(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                if let data {
                    self?.processData(data)
                }
                if isComplete || error != nil {
                    self?.removeConnection(connection)
                } else {
                    self?.receiveMessages(from: connection)
                }
            }
        }
    }

    private var receiveBuffer = Data()

    private func processData(_ data: Data) {
        receiveBuffer.append(data)

        // Split on newlines — each line is a JSON message
        while let newlineIndex = receiveBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let lineData = receiveBuffer[receiveBuffer.startIndex..<newlineIndex]
            receiveBuffer = Data(receiveBuffer[receiveBuffer.index(after: newlineIndex)...])

            if let command = try? JSONDecoder().decode(RemoteCommand.self, from: lineData) {
                onCommand?(command)
            }
        }
    }
}

// MARK: - Protocol Types

struct WindowInfo: Codable, Identifiable {
    let id: UInt32
    let ownerName: String
    let windowTitle: String
    let bundleIdentifier: String?
    var screenshotBase64: String?
    var attentionReason: String?
}

struct ServerMessage: Codable {
    enum MessageType: String, Codable {
        case windowList
    }
    let type: MessageType
    var windows: [WindowInfo]?
}

struct RemoteCommand: Codable {
    enum CommandType: String, Codable {
        case sendText
        case sendReturn
        case bringToFront
    }
    let type: CommandType
    var windowId: UInt32?
    var text: String?
}
