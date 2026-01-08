import Foundation

// MARK: - Outgoing Messages

struct RemoteMessage: Codable {
    let type: String
    let action: String
    let payload: AnyCodable?
    var requestId: String?

    init(type: String, action: String, payload: [String: Any]? = nil, requestId: String? = nil) {
        self.type = type
        self.action = action
        self.payload = payload.map { AnyCodable($0) }
        self.requestId = requestId ?? UUID().uuidString
    }
}

struct AuthPayload: Codable {
    let token: String
    let clientId: String
    let deviceName: String
}

// MARK: - Incoming Messages

struct IncomingMessage: Codable {
    let type: String
    let action: String
    let payload: AnyCodable?
    let requestId: String?
}

// MARK: - AnyCodable wrapper for dynamic JSON

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self.value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            self.value = bool
        } else if let int = try? container.decode(Int.self) {
            self.value = int
        } else if let double = try? container.decode(Double.self) {
            self.value = double
        } else if let string = try? container.decode(String.self) {
            self.value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            self.value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            self.value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unable to decode value")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Unable to encode value"))
        }
    }

    // Convenience accessors
    var dictionary: [String: Any]? { value as? [String: Any] }
    var array: [Any]? { value as? [Any] }
    var string: String? { value as? String }
    var int: Int? { value as? Int }
    var bool: Bool? { value as? Bool }
}
