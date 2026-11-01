import Foundation

// Соответствуют server/app/library/schemas.py один в один.

struct LibFolder: Codable, Identifiable, Hashable {
    let id: UUID
    let parentId: UUID?
    var name: String
    var version: Int
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, name, version
        case parentId = "parent_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
}

struct LibFile: Codable, Identifiable, Hashable {
    let id: UUID
    let folderId: UUID?
    var name: String
    let originalName: String
    let extensionName: String
    let mimeType: String
    let sizeBytes: Int64
    let sha256: String
    var version: Int
    let createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var meta: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case id, name, mime_type, version, meta
        case folderId = "folder_id"
        case originalName = "original_name"
        case extensionName = "extension"
        case sizeBytes = "size_bytes"
        case sha256
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }

    private enum RootKeys: String, CodingKey { case mimeType = "mime_type" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)
        id = try c.decode(UUID.self, forKey: AnyCodingKey("id"))
        folderId = try c.decodeIfPresent(UUID.self, forKey: AnyCodingKey("folder_id"))
        name = try c.decode(String.self, forKey: AnyCodingKey("name"))
        originalName = try c.decode(String.self, forKey: AnyCodingKey("original_name"))
        extensionName = try c.decode(String.self, forKey: AnyCodingKey("extension"))
        mimeType = try c.decode(String.self, forKey: AnyCodingKey("mime_type"))
        sizeBytes = try c.decode(Int64.self, forKey: AnyCodingKey("size_bytes"))
        sha256 = try c.decode(String.self, forKey: AnyCodingKey("sha256"))
        version = try c.decode(Int.self, forKey: AnyCodingKey("version"))
        createdAt = try c.decode(Date.self, forKey: AnyCodingKey("created_at"))
        updatedAt = try c.decode(Date.self, forKey: AnyCodingKey("updated_at"))
        deletedAt = try c.decodeIfPresent(Date.self, forKey: AnyCodingKey("deleted_at"))
        meta = (try? c.decode([String: JSONValue].self, forKey: AnyCodingKey("meta"))) ?? [:]
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: AnyCodingKey.self)
        try c.encode(id, forKey: AnyCodingKey("id"))
        try c.encode(folderId, forKey: AnyCodingKey("folder_id"))
        try c.encode(name, forKey: AnyCodingKey("name"))
    }
}

/// Произвольный ключ для ручного Codable у LibFile (поле `extension` конфликтует со словом Swift).
private struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Минимальный JSON-контейнер для поля `meta`, тип которого на сервере — произвольный словарь.
enum JSONValue: Codable, Hashable {
    case string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
}

struct Breadcrumb: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
}

struct ListingOut: Codable {
    let folder: LibFolder?
    let breadcrumbs: [Breadcrumb]
    let folders: [LibFolder]
    let files: [LibFile]
}

struct UploadOut: Codable {
    let id: UUID
    let name: String
    let size: Int64
    let received: Int64
    let folderId: UUID?
    let expiresAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, size, received
        case folderId = "folder_id"
        case expiresAt = "expires_at"
    }
}

struct CompleteOut: Codable {
    let file: LibFile
    let duplicateOf: UUID?
    let replaced: Bool

    enum CodingKeys: String, CodingKey {
        case file, replaced
        case duplicateOf = "duplicate_of"
    }
}

struct LinkOut: Codable {
    let url: String
    let expiresIn: Int

    enum CodingKeys: String, CodingKey {
        case url
        case expiresIn = "expires_in"
    }
}

struct BulkResult: Codable {
    let files: Int
    let folders: Int
    let notFound: [UUID]

    enum CodingKeys: String, CodingKey {
        case files, folders
        case notFound = "not_found"
    }
}

struct UsageOut: Codable {
    let usedBytes: Int64
    enum CodingKeys: String, CodingKey { case usedBytes = "used_bytes" }
}

struct SearchHitOut: Codable, Identifiable {
    let type: String
    let id: String
    let title: String
    let subtitle: String?
    let score: Double
    let extra: [String: JSONValue]
}

struct SearchOut: Codable {
    let hits: [SearchHitOut]
}

// MARK: - Тела запросов

struct FolderCreateBody: Encodable {
    let name: String
    let parent_id: UUID?
}

struct FolderPatchBody: Encodable {
    var name: String?
    var parent_id: UUID??   // внешний optional = «не трогать», внутренний nil = «переместить в корень»

    enum CodingKeys: String, CodingKey { case name, parent_id }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let name = name { try c.encode(name, forKey: .name) }
        if let outer = parent_id {
            if let id = outer { try c.encode(id, forKey: .parent_id) } else { try c.encodeNil(forKey: .parent_id) }
        }
    }
}

struct FilePatchBody: Encodable {
    var name: String?
    var folder_id: UUID??

    enum CodingKeys: String, CodingKey { case name, folder_id }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let name = name { try c.encode(name, forKey: .name) }
        if let outer = folder_id {
            if let id = outer { try c.encode(id, forKey: .folder_id) } else { try c.encodeNil(forKey: .folder_id) }
        }
    }
}

struct UploadCreateBody: Encodable {
    let name: String
    let size: Int64
    let folder_id: UUID?
    let mime_type: String?
}

struct CompleteBody: Encodable {
    let sha256: String?
    let on_conflict: String
}

struct IdsBody: Encodable {
    let file_ids: [UUID]
    let folder_ids: [UUID]
}
