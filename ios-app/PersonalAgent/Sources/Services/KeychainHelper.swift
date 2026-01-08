import Foundation
import Security

enum KeychainHelper {
    enum KeychainError: Error {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(OSStatus)
    }

    static func save(_ data: Data, service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data
        ]

        // Try to add the item
        var status = SecItemAdd(query as CFDictionary, nil)

        // If it already exists, update it
        if status == errSecDuplicateItem {
            let updateQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account
            ]
            let attributes: [String: Any] = [
                kSecValueData as String: data
            ]
            status = SecItemUpdate(updateQuery as CFDictionary, attributes as CFDictionary)
        }

        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    static func read(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess else {
            return nil
        }

        return result as? Data
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Convenience methods for strings

    static func saveString(_ string: String, service: String, account: String) throws {
        guard let data = string.data(using: .utf8) else { return }
        try save(data, service: service, account: account)
    }

    static func readString(service: String, account: String) -> String? {
        guard let data = read(service: service, account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - App-specific keys

extension KeychainHelper {
    private static let service = "com.personalagent.app"

    static var authToken: String? {
        get { readString(service: service, account: "authToken") }
        set {
            if let value = newValue {
                try? saveString(value, service: service, account: "authToken")
            } else {
                delete(service: service, account: "authToken")
            }
        }
    }

    static var serverHost: String? {
        get { readString(service: service, account: "serverHost") }
        set {
            if let value = newValue {
                try? saveString(value, service: service, account: "serverHost")
            } else {
                delete(service: service, account: "serverHost")
            }
        }
    }

    static var serverPort: Int? {
        get {
            guard let string = readString(service: service, account: "serverPort") else { return nil }
            return Int(string)
        }
        set {
            if let value = newValue {
                try? saveString(String(value), service: service, account: "serverPort")
            } else {
                delete(service: service, account: "serverPort")
            }
        }
    }

    static var wisprFlowAPIKey: String? {
        get { readString(service: service, account: "wisprFlowAPIKey") }
        set {
            if let value = newValue {
                try? saveString(value, service: service, account: "wisprFlowAPIKey")
            } else {
                delete(service: service, account: "wisprFlowAPIKey")
            }
        }
    }

    static var certFingerprint: String? {
        get { readString(service: service, account: "certFingerprint") }
        set {
            if let value = newValue {
                try? saveString(value, service: service, account: "certFingerprint")
            } else {
                delete(service: service, account: "certFingerprint")
            }
        }
    }
}
