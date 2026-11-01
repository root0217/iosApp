import Foundation
import CryptoKit

enum UploadStatus: Equatable {
    case queued
    case uploading(progress: Double)
    case finishing
    case done
    case failed(String)
}

final class UploadItem: Identifiable, ObservableObject {
    let id = UUID()
    let name: String
    let folderID: UUID?
    let sourceURL: URL
    let needsSecurityScope: Bool
    @Published var status: UploadStatus = .queued

    init(name: String, folderID: UUID?, sourceURL: URL, needsSecurityScope: Bool) {
        self.name = name
        self.folderID = folderID
        self.sourceURL = sourceURL
        self.needsSecurityScope = needsSecurityScope
    }
}

/// Очередь загрузок: читает файл кусками и шлёт через существующий серверный механизм докачки
/// (POST /uploads → PUT …?offset=N → POST complete). Сам ничего не «имитирует» — повторный запрос
/// после сбоя продолжает с того байта, который подтвердил сервер.
@MainActor
final class UploadManager: ObservableObject {
    @Published private(set) var items: [UploadItem] = []
    var onFileUploaded: ((LibFile, UUID?) -> Void)?

    private let chunkSize: Int64 = 768 * 1024

    func enqueue(urls: [URL], folderID: UUID?, needsSecurityScope: Bool) {
        for url in urls {
            let item = UploadItem(name: url.lastPathComponent, folderID: folderID, sourceURL: url, needsSecurityScope: needsSecurityScope)
            items.append(item)
            Task { await run(item) }
        }
    }

    func enqueue(name: String, temporaryFileURL: URL, folderID: UUID?) {
        let item = UploadItem(name: name, folderID: folderID, sourceURL: temporaryFileURL, needsSecurityScope: false)
        items.append(item)
        Task { await run(item) }
    }

    func clearFinished() {
        items.removeAll { if case .done = $0.status { return true }; return false }
    }

    private func run(_ item: UploadItem) async {
        let accessed = item.needsSecurityScope && item.sourceURL.startAccessingSecurityScopedResource()
        defer { if accessed { item.sourceURL.stopAccessingSecurityScopedResource() } }

        guard let handle = try? FileHandle(forReadingFrom: item.sourceURL),
              let size = try? item.sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            item.status = .failed("Не удалось прочитать файл")
            return
        }
        defer { try? handle.close() }
        let total = Int64(size)
        let mime = mimeType(for: item.sourceURL)

        do {
            item.status = .uploading(progress: 0)
            let draft = try await LibraryService.createUpload(name: item.name, size: total, folderID: item.folderID, mimeType: mime)
            var offset = draft.received
            var hasher = SHA256()
            if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }  // возобновление прошлой загрузки

            while offset < total {
                guard !Task.isCancelled else { item.status = .failed("Отменено"); return }
                let chunk = (try handle.read(upToCount: Int(min(chunkSize, total - offset)))) ?? Data()
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                let updated = try await LibraryService.putChunk(uploadID: draft.id, offset: offset, data: chunk)
                offset = updated.received
                item.status = .uploading(progress: total > 0 ? Double(offset) / Double(total) : 1)
            }

            item.status = .finishing
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            let result = try await LibraryService.completeUpload(uploadID: draft.id, sha256: digest)
            item.status = .done
            onFileUploaded?(result.file, item.folderID)
        } catch {
            item.status = .failed((error as? LocalizedError)?.errorDescription ?? "Ошибка загрузки")
        }
    }

    private func mimeType(for url: URL) -> String? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type.preferredMIMEType
        }
        return nil
    }
}
