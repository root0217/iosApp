import Foundation

/// Прямые обёртки над /v1/library/*. Все запросы идут через APIClient — токены и повтор на 401 уже там.
enum LibraryService {
    static func listing(folderID: UUID?) async throws -> ListingOut {
        try await APIClient.shared.send("GET", "/library/folders/\(folderID?.uuidString ?? "root")")
    }

    static func fileMeta(id: UUID) async throws -> LibFile {
        try await APIClient.shared.send("GET", "/library/files/\(id)")
    }

    static func createFolder(name: String, parentID: UUID?) async throws -> LibFolder {
        try await APIClient.shared.send("POST", "/library/folders", body: FolderCreateBody(name: name, parent_id: parentID))
    }

    static func renameFolder(_ id: UUID, to name: String, ifMatch version: Int) async throws -> LibFolder {
        try await APIClient.shared.send("PATCH", "/library/folders/\(id)",
                                        body: FolderPatchBody(name: name, parent_id: nil), ifMatch: version)
    }

    static func moveFolder(_ id: UUID, to parentID: UUID?, ifMatch version: Int) async throws -> LibFolder {
        try await APIClient.shared.send("PATCH", "/library/folders/\(id)",
                                        body: FolderPatchBody(name: nil, parent_id: .some(parentID)), ifMatch: version)
    }

    static func deleteFolder(_ id: UUID, ifMatch version: Int) async throws {
        try await APIClient.shared.send("DELETE", "/library/folders/\(id)", ifMatch: version)
    }

    static func renameFile(_ id: UUID, to name: String, ifMatch version: Int) async throws -> LibFile {
        try await APIClient.shared.send("PATCH", "/library/files/\(id)",
                                        body: FilePatchBody(name: name, folder_id: nil), ifMatch: version)
    }

    static func moveFile(_ id: UUID, to folderID: UUID?, ifMatch version: Int) async throws -> LibFile {
        try await APIClient.shared.send("PATCH", "/library/files/\(id)",
                                        body: FilePatchBody(name: nil, folder_id: .some(folderID)), ifMatch: version)
    }

    static func deleteFile(_ id: UUID, ifMatch version: Int) async throws {
        try await APIClient.shared.send("DELETE", "/library/files/\(id)", ifMatch: version)
    }

    /// Короткоживущая ссылка (создаётся отдельно от download(fileID:), пригодится для QuickLook/AVPlayer,
    /// которым нужен URL, а не байты в памяти).
    static func downloadLink(fileID: UUID) async throws -> URL {
        let out: LinkOut = try await APIClient.shared.send("POST", "/library/files/\(fileID)/link")
        guard let url = await APIClient.shared.absoluteURL(forServerPath: out.url) else {
            throw APIError.decoding(URLError(.badURL))
        }
        return url
    }

    static func usage() async throws -> UsageOut {
        try await APIClient.shared.send("GET", "/library/usage")
    }

    static func search(query: String) async throws -> [SearchHitOut] {
        let out: SearchOut = try await APIClient.shared.send("GET", "/search",
                                                              query: [URLQueryItem(name: "q", value: query),
                                                                     URLQueryItem(name: "sources", value: "library")])
        return out.hits
    }

    // MARK: Загрузка (создание черновика и завершение — куски шлёт UploadManager)

    static func createUpload(name: String, size: Int64, folderID: UUID?, mimeType: String?) async throws -> UploadOut {
        try await APIClient.shared.send("POST", "/library/uploads",
                                        body: UploadCreateBody(name: name, size: size, folder_id: folderID, mime_type: mimeType))
    }

    static func putChunk(uploadID: UUID, offset: Int64, data: Data) async throws -> UploadOut {
        let raw = try await APIClient.shared.upload("PUT", "/library/uploads/\(uploadID)",
                                                     query: [URLQueryItem(name: "offset", value: String(offset))], chunk: data)
        return try await APIClient.shared.decode(UploadOut.self, from: raw)
    }

    static func uploadStatus(uploadID: UUID) async throws -> UploadOut {
        try await APIClient.shared.send("GET", "/library/uploads/\(uploadID)")
    }

    static func completeUpload(uploadID: UUID, sha256: String?) async throws -> CompleteOut {
        try await APIClient.shared.send("POST", "/library/uploads/\(uploadID)/complete",
                                        body: CompleteBody(sha256: sha256, on_conflict: "rename"))
    }

    static func abortUpload(uploadID: UUID) async {
        try? await APIClient.shared.send("DELETE", "/library/uploads/\(uploadID)")
    }
}

