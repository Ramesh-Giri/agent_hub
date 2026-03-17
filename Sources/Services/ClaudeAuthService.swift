import Foundation
import Security

/// Reads Claude Code's OAuth credentials from the macOS keychain.
/// Claude Code stores credentials under service "Claude Code-credentials"
/// with the macOS username as the account.
struct ClaudeAuthService {

    struct Credentials {
        let accessToken: String
        let refreshToken: String
    }

    static func getCredentials() -> Credentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let accessToken = oauth["accessToken"] as? String,
              let refreshToken = oauth["refreshToken"] as? String
        else { return nil }

        return Credentials(accessToken: accessToken, refreshToken: refreshToken)
    }
}
