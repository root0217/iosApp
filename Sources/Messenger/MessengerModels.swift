import Foundation

struct Attachment: Codable, Hashable, Identifiable {
    let id: UUID
    let name: String
    let mimeType: String
    let sizeBytes: Int64
    let durationSeconds: Double?

    enum CodingKeys: String, CodingKey {
        case id, name
        case mimeType = "mime_type"
        case sizeBytes = "size_bytes"
        case durationSeconds = "duration_seconds"
    }
}

enum DeliveryStatus: String, Codable {
    case sent, delivered, read
}

struct Message: Codable, Identifiable, Hashable {
    let id: UUID
    let conversationId: UUID
    let senderId: UUID
    var text: String?
    var attachment: Attachment?
    let sentAt: Date
    var status: DeliveryStatus
    var editedAt: Date?
    var deletedForEveryone: Bool

    enum CodingKeys: String, CodingKey {
        case id, text, attachment, status
        case conversationId = "conversation_id"
        case senderId = "sender_id"
        case sentAt = "sent_at"
        case editedAt = "edited_at"
        case deletedForEveryone = "deleted_for_everyone"
    }
}

struct Conversation: Codable, Identifiable, Hashable {
    let id: UUID
    var participant: PublicUserOut
    var lastMessage: Message?
    var unreadCount: Int
    var pinned: Bool
    var updatedAt: Date

    enum CodingKeys: String, CodingKey {
        case id, participant, pinned
        case lastMessage = "last_message"
        case unreadCount = "unread_count"
        case updatedAt = "updated_at"
    }

    static func == (lhs: Conversation, rhs: Conversation) -> Bool {
        lhs.id == rhs.id && lhs.lastMessage == rhs.lastMessage && lhs.unreadCount == rhs.unreadCount
            && lhs.pinned == rhs.pinned && lhs.participant == rhs.participant
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct MessagesPage: Codable {
    let messages: [Message]
    let hasMore: Bool
    enum CodingKeys: String, CodingKey { case messages; case hasMore = "has_more" }
}

private struct StartConversationBody: Encodable { let username: String }
private struct SendMessageBody: Encodable { let text: String?; let attachment_file_id: String?; let attachment_duration_seconds: Double? }
private struct EditMessageBody: Encodable { let text: String }
private struct MarkReadBody: Encodable { let up_to_message_id: String }
private struct PinBody: Encodable { let pinned: Bool }

enum MessengerService {
    static func listConversations() async throws -> [Conversation] {
        try await APIClient.shared.send("GET", "/messenger/conversations")
    }

    static func startConversation(username: String) async throws -> Conversation {
        try await APIClient.shared.send("POST", "/messenger/conversations", body: StartConversationBody(username: username))
    }

    static func messages(conversationId: UUID, before: Date?, limit: Int = 50) async throws -> MessagesPage {
        var query: [URLQueryItem] = [URLQueryItem(name: "limit", value: String(limit))]
        if let before = before {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            query.append(URLQueryItem(name: "before", value: formatter.string(from: before)))
        }
        return try await APIClient.shared.send("GET", "/messenger/conversations/\(conversationId)/messages", query: query)
    }

    @discardableResult
    static func sendMessage(conversationId: UUID, text: String?, attachmentFileId: UUID?, durationSeconds: Double?) async throws -> Message {
        try await APIClient.shared.send("POST", "/messenger/conversations/\(conversationId)/messages",
                                        body: SendMessageBody(text: text, attachment_file_id: attachmentFileId?.uuidString,
                                                              attachment_duration_seconds: durationSeconds))
    }

    static func editMessage(_ id: UUID, text: String) async throws -> Message {
        try await APIClient.shared.send("PATCH", "/messenger/messages/\(id)", body: EditMessageBody(text: text))
    }

    static func deleteMessage(_ id: UUID, forEveryone: Bool) async throws {
        try await APIClient.shared.send("DELETE", "/messenger/messages/\(id)",
                                        query: [URLQueryItem(name: "for_everyone", value: forEveryone ? "true" : "false")])
    }

    static func markRead(conversationId: UUID, upToMessageId: UUID) async throws {
        try await APIClient.shared.send("POST", "/messenger/conversations/\(conversationId)/read",
                                        body: MarkReadBody(up_to_message_id: upToMessageId.uuidString))
    }

    static func setPinned(conversationId: UUID, pinned: Bool) async throws {
        try await APIClient.shared.send("PATCH", "/messenger/conversations/\(conversationId)", body: PinBody(pinned: pinned))
    }

    static func hideConversation(_ id: UUID) async throws {
        try await APIClient.shared.send("DELETE", "/messenger/conversations/\(id)")
    }
}
