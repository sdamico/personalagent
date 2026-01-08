import Foundation

struct PTYSession: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var cols: Int
    var rows: Int
    var cwd: String
    var shell: String
    var createdAt: TimeInterval

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: PTYSession, rhs: PTYSession) -> Bool {
        lhs.id == rhs.id
    }
}

struct ServiceStatus: Identifiable, Codable {
    let id: String
    let name: String
    let status: String
    var pid: Int?
    var uptime: TimeInterval?
    var lastError: String?
}

struct ConnectedClient: Identifiable, Codable {
    let id: String
    let deviceName: String
    let authenticatedAt: TimeInterval
}

struct ConnectionConfig: Codable {
    var host: String
    var port: Int
    var authToken: String
    var certFingerprint: String?  // SHA-256 fingerprint for TLS pinning

    static let `default` = ConnectionConfig(
        host: "",
        port: 9876,
        authToken: "",
        certFingerprint: nil
    )
}
