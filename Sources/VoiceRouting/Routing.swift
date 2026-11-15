import Foundation

public struct RoutingError: Error, CustomStringConvertible, Equatable, Sendable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

public struct VoiceTarget: Codable, Equatable, Sendable {
    public static let defaultAppID = "codex"

    public let id: String
    public let title: String
    public let appID: String

    public init(id: String, title: String) {
        self.id = id
        self.title = title
        self.appID = Self.defaultAppID
    }

    public init(id: String, title: String, appID: String = "codex") {
        self.id = id
        self.title = title
        let normalized = appID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.appID = normalized.isEmpty ? Self.defaultAppID : normalized
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, appID
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(String.self, forKey: .id)
        let title = try container.decode(String.self, forKey: .title)
        let rawAppID = try container.decodeIfPresent(String.self, forKey: .appID) ?? Self.defaultAppID
        let normalized = rawAppID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.id = id
        self.title = title
        self.appID = normalized.isEmpty ? Self.defaultAppID : normalized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(appID, forKey: .appID)
    }
}

public enum ChatLink {
    private static let reentrancyKey = "beanbridge.chatlink.parsing"
    private static let allowedDoubaoIDScalars = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_."
    )

    /// Accept only the local chat route. Remote/chatgpt/query routes have different semantics.
    public static func threadID(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URLComponents(string: text), url.scheme == "codex", url.host == "threads",
              url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil,
              url.path.count == 37, url.path.first == "/",
              let uuid = UUID(uuidString: String(url.path.dropFirst())) else {
            throw RoutingError("请使用 ⌘⌥L 复制的本地 Codex 聊天链接。")
        }
        return uuid.uuidString.lowercased()
    }

    public static func validateDoubaoID(_ raw: String) throws -> String {
        guard !raw.isEmpty, raw.count <= 128,
              raw != ".", raw != "..",
              !raw.contains(".."),
              !raw.contains("/"), !raw.contains("\\"),
              raw.lowercased() != "new",
              raw.unicodeScalars.allSatisfy({ allowedDoubaoIDScalars.contains($0) }) else {
            throw RoutingError("豆包会话 ID 格式无效。")
        }
        return raw
    }

    /// Parse multi-app chat links with strict URL hygiene (no credentials, port, query, fragment, empty path, or traversal).
    public static func parse(_ raw: String, defaultAppID: String? = nil) throws -> (appID: String, id: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let url = URLComponents(string: text) else {
            throw invalidLinkError(defaultAppID: defaultAppID)
        }
        guard url.user == nil, url.password == nil, url.port == nil,
              url.query == nil, url.fragment == nil else {
            throw invalidLinkError(defaultAppID: defaultAppID)
        }

        if url.scheme == "codex" {
            return (appID: "codex", id: try threadID(text))
        }

        if url.scheme == "doubao" || url.scheme == "doubaowork" {
            guard url.host == "chat" || url.host == "thread" else {
                throw invalidLinkError(defaultAppID: defaultAppID ?? "doubao")
            }
            let encodedPath = url.percentEncodedPath
            let decodedPath = url.path
            guard encodedPath.hasPrefix("/"), decodedPath.hasPrefix("/") else {
                throw invalidLinkError(defaultAppID: defaultAppID ?? "doubao")
            }
            let encodedSegment = String(encodedPath.dropFirst())
            let decodedSegment = String(decodedPath.dropFirst())
            guard encodedSegment == decodedSegment else {
                throw invalidLinkError(defaultAppID: defaultAppID ?? "doubao")
            }
            let id = try validateDoubaoID(decodedSegment)
            return (appID: "doubao", id: id)
        }

        if url.scheme == "https", url.host == "www.doubao.com" {
            let prefix = "/chat/"
            let encodedPath = url.percentEncodedPath
            let decodedPath = url.path
            guard encodedPath.hasPrefix(prefix), decodedPath.hasPrefix(prefix) else {
                throw invalidLinkError(defaultAppID: defaultAppID ?? "doubao")
            }
            let encodedSegment = String(encodedPath.dropFirst(prefix.count))
            let decodedSegment = String(decodedPath.dropFirst(prefix.count))
            guard encodedSegment == decodedSegment else {
                throw invalidLinkError(defaultAppID: defaultAppID ?? "doubao")
            }
            let id = try validateDoubaoID(decodedSegment)
            return (appID: "doubao", id: id)
        }

        if Thread.current.threadDictionary[reentrancyKey] == nil {
            Thread.current.threadDictionary[reentrancyKey] = true
            defer { Thread.current.threadDictionary.removeObject(forKey: reentrancyKey) }

            if let preferred = defaultAppID.map(AppTargetRegistry.normalize),
               preferred != "codex", preferred != "doubao",
               let adapter = AppTargetRegistry.shared.adapter(for: preferred),
               let id = try? adapter.parseLink(text) {
                return (appID: adapter.appID, id: id)
            }
            for adapter in AppTargetRegistry.shared.allAdapters where adapter.appID != "codex" && adapter.appID != "doubao" {
                if let id = try? adapter.parseLink(text) {
                    return (appID: adapter.appID, id: id)
                }
            }
        }

        throw invalidLinkError(defaultAppID: defaultAppID)
    }

    public static func validatePaseoID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...128).contains(trimmed.count),
              !trimmed.contains(".."),
              !trimmed.hasPrefix("."),
              trimmed.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else {
            throw RoutingError("无效的 Paseo 对话 ID。")
        }
        return trimmed
    }

    public static func validatePaseoServerID(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...96).contains(trimmed.count),
              !trimmed.contains(".."),
              !trimmed.hasPrefix("."),
              trimmed.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
              }) else {
            throw RoutingError("无效的 Paseo Server ID。")
        }
        return trimmed
    }

    private static func invalidLinkError(defaultAppID: String?) -> RoutingError {
        switch defaultAppID.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) {
        case "codex":
            return RoutingError("请使用 ⌘⌥L 复制的本地 Codex 聊天链接。")
        case "doubao":
            return RoutingError("请使用有效的豆包聊天链接（doubao://chat/… 或 https://www.doubao.com/chat/…）。")
        case "paseo":
            return RoutingError("请使用有效的 Paseo 对话链接（paseo://h/<serverId>/agent/<id>、paseo://agent/<id> 或 https://app.paseo.sh/h/<serverId>/agent/<id>）。")
        default:
            return RoutingError("请使用有效的 Codex（codex://threads/…）、豆包（doubao://chat/…）或 Paseo（paseo://h/…/agent/…）对话链接。")
        }
    }
}

public struct PendingMessage: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, creating, submitting, queued, uncertain }
    public let id: UUID
    public let createdAt: Date
    public let text: String
    public var appID: String
    public var target: VoiceTarget?
    public var state: State
    public var note: String

    public init(text: String, target: VoiceTarget?, note: String) {
        self.init(text: text, target: target, note: note, appID: target?.appID ?? VoiceTarget.defaultAppID)
    }

    public init(text: String, target: VoiceTarget?, note: String, appID: String) {
        id = UUID()
        createdAt = Date()
        self.text = text
        let normalized = appID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.appID = normalized.isEmpty ? (target?.appID ?? VoiceTarget.defaultAppID) : normalized
        self.target = target
        state = .pending
        self.note = note
    }

    public init(text: String, appID: String, target: VoiceTarget? = nil, note: String) {
        self.init(text: text, target: target, note: note, appID: appID)
    }

    private enum CodingKeys: String, CodingKey {
        case id, createdAt, text, appID, target, state, note
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        text = try container.decode(String.self, forKey: .text)
        target = try container.decodeIfPresent(VoiceTarget.self, forKey: .target)
        let rawAppID = try container.decodeIfPresent(String.self, forKey: .appID)
            ?? target?.appID
            ?? VoiceTarget.defaultAppID
        let normalized = rawAppID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        appID = normalized.isEmpty ? VoiceTarget.defaultAppID : normalized
        state = try container.decode(State.self, forKey: .state)
        note = try container.decode(String.self, forKey: .note)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(text, forKey: .text)
        try container.encode(appID, forKey: .appID)
        try container.encodeIfPresent(target, forKey: .target)
        try container.encode(state, forKey: .state)
        try container.encode(note, forKey: .note)
    }
}

/// Persist before submitting. An interrupted submission is never silently retried.
public final class PendingStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSLock()
    public init(directory: URL) { self.directory = directory }
    private func saveUnlocked(_ message: PendingMessage) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent(message.id.uuidString + ".json")
        // Atomic replacement inherits a private directory; file protection remains explicit.
        try JSONEncoder().encode(message).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
    public func save(_ message: PendingMessage) throws {
        lock.lock(); defer { lock.unlock() }; try saveUnlocked(message)
    }
    public func messages() throws -> [PendingMessage] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
            .map { try JSONDecoder().decode(PendingMessage.self, from: Data(contentsOf: $0)) }
            .sorted { $0.createdAt < $1.createdAt }
    }
    public func beginCreation(_ id: UUID) throws -> PendingMessage {
        lock.lock(); defer { lock.unlock() }
        let path = directory.appendingPathComponent(id.uuidString + ".json")
        var message = try JSONDecoder().decode(PendingMessage.self, from: Data(contentsOf: path))
        guard message.state == .pending, message.target == nil else {
            throw RoutingError("此消息已经指定目标或尝试创建，不会重复建聊。")
        }
        message.state = .creating
        message.note = "正在创建独立会话；若中断，请核对 Creation 目录的创建回执。"
        try saveUnlocked(message)
        return message
    }
    public func beginSubmission(_ id: UUID, target: VoiceTarget) throws -> PendingMessage {
        lock.lock(); defer { lock.unlock() }
        let path = directory.appendingPathComponent(id.uuidString + ".json")
        var message = try JSONDecoder().decode(PendingMessage.self, from: Data(contentsOf: path))
        guard message.state == .pending else {
            throw RoutingError("这条消息已尝试投递，请先到目标对话核对；不会自动重发。")
        }
        message.target = target
        message.appID = target.appID
        message.state = .submitting
        message.note = "正在投递；中断时需人工核对"
        try saveUnlocked(message)
        return message
    }
}
