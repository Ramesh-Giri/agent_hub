import Foundation
import CommonCrypto
import WebKit
import SQLite3

/// Reads and decrypts cookies from Arc/Chrome browser and injects them into WKWebView.
/// Caches decrypted cookies to avoid repeated Keychain prompts.
struct BrowserCookieService {

    private static var cachedCookies: [HTTPCookie]?
    private static let cacheFile = FileManager.default.temporaryDirectory.appendingPathComponent("agenthub-cookies.json")

    static func injectBrowserCookies(into webView: WKWebView, for domain: String, completion: @escaping () -> Void) {
        DispatchQueue.global().async {
            // Use cached cookies if available (avoid Keychain prompt)
            let cookies: [HTTPCookie]
            if let cached = cachedCookies, !cached.isEmpty {
                cookies = cached
            } else if let loaded = loadCachedCookies(for: domain) {
                cachedCookies = loaded
                cookies = loaded
            } else {
                let fresh = readBrowserCookies(for: domain)
                cachedCookies = fresh
                saveCookiesToCache(fresh)
                cookies = fresh
            }
            DispatchQueue.main.async {
                let store = webView.configuration.websiteDataStore.httpCookieStore
                let group = DispatchGroup()
                for cookie in cookies {
                    group.enter()
                    store.setCookie(cookie) { group.leave() }
                }
                group.notify(queue: .main) { completion() }
            }
        }
    }

    /// Force refresh cookies from browser (will trigger Keychain prompt)
    static func refreshFromBrowser(for domain: String) {
        DispatchQueue.global().async {
            let fresh = readBrowserCookies(for: domain)
            cachedCookies = fresh
            saveCookiesToCache(fresh)
        }
    }

    private static func saveCookiesToCache(_ cookies: [HTTPCookie]) {
        let data = cookies.compactMap { cookie -> [String: String]? in
            guard let value = cookie.value as String?,
                  let name = cookie.name as String?,
                  let domain = cookie.domain as String?
            else { return nil }
            return ["name": name, "value": value, "domain": domain,
                    "path": cookie.path, "secure": cookie.isSecure ? "1" : "0"]
        }
        if let json = try? JSONSerialization.data(withJSONObject: data) {
            try? json.write(to: cacheFile)
        }
    }

    private static func loadCachedCookies(for domain: String) -> [HTTPCookie]? {
        guard let data = try? Data(contentsOf: cacheFile),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: String]]
        else { return nil }
        // Check if cache is less than 1 hour old
        if let attrs = try? FileManager.default.attributesOfItem(atPath: cacheFile.path),
           let modified = attrs[.modificationDate] as? Date,
           Date().timeIntervalSince(modified) > 3600 {
            return nil // stale
        }
        let cookies = array.compactMap { dict -> HTTPCookie? in
            guard let name = dict["name"], let value = dict["value"],
                  let cookieDomain = dict["domain"], cookieDomain.contains(domain)
            else { return nil }
            return HTTPCookie(properties: [
                .name: name, .value: value, .domain: cookieDomain,
                .path: dict["path"] ?? "/",
                .secure: dict["secure"] == "1" ? "TRUE" : "FALSE",
                .expires: Date(timeIntervalSinceNow: 86400 * 7)
            ])
        }
        return cookies.isEmpty ? nil : cookies
    }

    private static func readBrowserCookies(for domain: String) -> [HTTPCookie] {
        // Try Arc first, then Chrome, then Safari
        if let cookies = readChromiumCookies(browser: "Arc", keyService: "Arc Safe Storage", for: domain), !cookies.isEmpty {
            return cookies
        }
        if let cookies = readChromiumCookies(browser: "Google/Chrome", keyService: "Chrome Safe Storage", for: domain), !cookies.isEmpty {
            return cookies
        }
        return []
    }

    private static func readChromiumCookies(browser: String, keyService: String, for domain: String) -> [HTTPCookie]? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let cookiePath = "\(home)/Library/Application Support/\(browser)/User Data/Default/Cookies"

        guard fm.fileExists(atPath: cookiePath) else { return nil }

        // Get encryption key from keychain (use raw bytes as-is for PBKDF2 password)
        guard let encKey = getKeychainPassword(service: keyService) else { return nil }

        // Derive AES key using PBKDF2 — Chromium uses the raw keychain bytes as password
        let derivedKey = pbkdf2(password: encKey, salt: "saltysalt", iterations: 1003, keyLength: 16)

        // Copy database (it may be locked by the browser)
        let tmpPath = fm.temporaryDirectory.path + "/browser-cookies-\(browser.replacingOccurrences(of: "/", with: "-")).db"
        try? fm.removeItem(atPath: tmpPath)
        try? fm.copyItem(atPath: cookiePath, toPath: tmpPath)

        guard let db = try? SQLiteDB(path: tmpPath) else { return nil }
        defer { try? fm.removeItem(atPath: tmpPath) }

        let rows = db.query(
            "SELECT name, host_key, encrypted_value, path, is_secure, is_httponly, expires_utc FROM cookies WHERE host_key LIKE ?",
            params: ["%\(domain)%"]
        )

        var cookies: [HTTPCookie] = []
        for row in rows {
            guard let name = row["name"] as? String,
                  let host = row["host_key"] as? String,
                  let encrypted = row["encrypted_value"] as? Data,
                  let path = row["path"] as? String,
                  encrypted.count > 3
            else { continue }

            // Chromium v10 format: "v10" + 32-byte header + ciphertext
            guard encrypted.prefix(3) == Data([0x76, 0x31, 0x30]) else { continue }
            let ciphertext = encrypted.suffix(from: 3)

            guard let decrypted = aesDecrypt(data: Data(ciphertext), key: derivedKey) else { continue }
            // Skip first 32 bytes (nonce/header) to get the actual value
            let valueData = decrypted.count > 32 ? decrypted.suffix(from: 32) : decrypted
            guard let value = String(data: valueData, encoding: .utf8), !value.isEmpty else { continue }

            let secure = (row["is_secure"] as? Int) == 1
            let httpOnly = (row["is_httponly"] as? Int) == 1

            var props: [HTTPCookiePropertyKey: Any] = [
                .domain: host,
                .path: path,
                .name: name,
                .value: value,
                .secure: secure ? "TRUE" : "FALSE",
            ]
            if httpOnly {
                props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            // Set expiry far in the future
            props[.expires] = Date(timeIntervalSinceNow: 86400 * 30)

            if let cookie = HTTPCookie(properties: props) {
                cookies.append(cookie)
            }
        }
        return cookies
    }

    // MARK: - Keychain

    private static func getKeychainPassword(service: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return data
    }

    // MARK: - Crypto

    private static func pbkdf2(password: Data, salt: String, iterations: Int, keyLength: Int) -> Data {
        var derivedKey = Data(count: keyLength)
        let saltData = salt.data(using: .utf8)!
        derivedKey.withUnsafeMutableBytes { derivedKeyBytes in
            password.withUnsafeBytes { passwordBytes in
                saltData.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        saltData.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        return derivedKey
    }

    private static func aesDecrypt(data: Data, key: Data) -> Data? {
        let iv = Data(repeating: 0x20, count: 16) // 16 spaces
        var outLength = 0
        let bufferSize = data.count + kCCBlockSizeAES128
        var outData = Data(count: bufferSize)

        let status: CCCryptorStatus = outData.withUnsafeMutableBytes { outBytes in
            return data.withUnsafeBytes { dataBytes in
                return key.withUnsafeBytes { keyBytes in
                    return iv.withUnsafeBytes { ivBytes in
                        return CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            dataBytes.baseAddress, data.count,
                            outBytes.baseAddress, bufferSize,
                            &outLength
                        )
                    }
                }
            }
        }

        guard status == kCCSuccess else { return nil }
        return outData.prefix(outLength)
    }
}

// MARK: - Minimal SQLite wrapper

private class SQLiteDB {
    private var db: OpaquePointer?

    init(path: String) throws {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            throw NSError(domain: "SQLite", code: -1)
        }
    }

    deinit { sqlite3_close(db) }

    func query(_ sql: String, params: [String] = []) -> [[String: Any]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, param) in params.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 1), (param as NSString).utf8String, -1, nil)
        }

        var rows: [[String: Any]] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            var row: [String: Any] = [:]
            let colCount = sqlite3_column_count(stmt)
            for i in 0..<colCount {
                let name = String(cString: sqlite3_column_name(stmt, i))
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER:
                    row[name] = Int(sqlite3_column_int64(stmt, i))
                case SQLITE_TEXT:
                    row[name] = String(cString: sqlite3_column_text(stmt, i))
                case SQLITE_BLOB:
                    let bytes = sqlite3_column_blob(stmt, i)
                    let len = sqlite3_column_bytes(stmt, i)
                    if let bytes, len > 0 {
                        row[name] = Data(bytes: bytes, count: Int(len))
                    }
                default:
                    break
                }
            }
            rows.append(row)
        }
        return rows
    }
}
