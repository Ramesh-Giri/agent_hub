import Foundation

/// Represents a memory/context entry from claude-mem
struct MemoryEntry: Codable, Identifiable {
    let id: String?
    let content: String?
    let type: String?
    let timestamp: String?
    let metadata: MemoryMetadata?

    struct MemoryMetadata: Codable {
        let project: String?
        let workingDirectory: String?
        let tags: [String]?
    }

    var displayContent: String {
        content ?? "(no content)"
    }
}

/// Search results from claude-mem
struct MemSearchResponse: Codable {
    let results: [MemoryEntry]?
    let observations: [MemoryEntry]?
    let memories: [MemoryEntry]?
    let data: [MemoryEntry]?

    /// Flatten whatever shape the response has
    var allEntries: [MemoryEntry] {
        (results ?? []) + (observations ?? []) + (memories ?? []) + (data ?? [])
    }
}

/// Service to fetch context from claude-mem running at localhost:37777
final class ClaudeMemService {
    private let baseURL: String
    private let session: URLSession

    init(baseURL: String = "https://localhost:37777") {
        self.baseURL = baseURL

        // Allow self-signed certs for localhost
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 10
        self.session = URLSession(configuration: config, delegate: LocalhostTrustDelegate(), delegateQueue: nil)
    }

    /// Check if claude-mem is reachable
    func isAvailable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/") else { return false }
        do {
            let (_, response) = try await session.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode != nil
        } catch {
            return false
        }
    }

    /// Search claude-mem for context related to a project/query
    func search(query: String) async -> [MemoryEntry] {
        guard let url = URL(string: "\(baseURL)/search") else { return [] }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["query": query, "limit": 10]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, _) = try await session.data(for: request)
            let response = try JSONDecoder().decode(MemSearchResponse.self, from: data)
            return response.allEntries
        } catch {
            return []
        }
    }

    /// Get recent observations/timeline from claude-mem
    func getTimeline(limit: Int = 20) async -> [MemoryEntry] {
        guard let url = URL(string: "\(baseURL)/timeline?limit=\(limit)") else { return [] }

        do {
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(MemSearchResponse.self, from: data)
            return response.allEntries
        } catch {
            return []
        }
    }

    /// Get observations matching a working directory path
    func getContextForProject(path: String) async -> [MemoryEntry] {
        await search(query: path)
    }
}

/// Trusts localhost self-signed certificates
private class LocalhostTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.host == "localhost" || challenge.protectionSpace.host == "127.0.0.1" {
            let credential = URLCredential(trust: challenge.protectionSpace.serverTrust!)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
