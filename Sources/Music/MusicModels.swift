import Foundation
import AVFoundation
import UIKit

// MARK: - Модели

enum RepeatMode: String {
    case off, all, one
}

struct Track: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var artist: String
    var album: String
    var duration: Double
    var fileName: String          // имя файла в Application Support/Music/Files
    var artworkFile: String?      // имя файла обложки в Application Support/Music/Artwork
    var originalName: String      // имя файла при импорте (для защиты от дублей)
    var fileSize: Int64
    var addedAt: Date

    var displayArtist: String { artist.isEmpty ? "Неизвестный исполнитель" : artist }
}

struct Playlist: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var trackIDs: [UUID]
    var createdAt: Date
}

struct LibrarySnapshot: Codable {
    var tracks: [Track]
    var playlists: [Playlist]
    var recentIDs: [UUID]
}

// MARK: - Хранилище на устройстве

enum MusicStorage {
    static let root: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Music", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static let filesDirectory: URL = makeDirectory("Files")
    static let artworkDirectory: URL = makeDirectory("Artwork")

    private static func makeDirectory(_ name: String) -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var libraryURL: URL { root.appendingPathComponent("library.json") }

    static func fileURL(for track: Track) -> URL {
        filesDirectory.appendingPathComponent(track.fileName)
    }

    static func artworkURL(named name: String) -> URL {
        artworkDirectory.appendingPathComponent(name)
    }

    static func loadSnapshot() -> LibrarySnapshot? {
        guard let data = try? Data(contentsOf: libraryURL) else { return nil }
        do {
            return try JSONDecoder().decode(LibrarySnapshot.self, from: data)
        } catch {
            // повреждённый файл не затираем: откладываем в сторону, чтобы его можно было восстановить
            let backup = root.appendingPathComponent("library.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: libraryURL, to: backup)
            NSLog("Music: library.json повреждён, сохранён как \(backup.lastPathComponent)")
            return nil
        }
    }

    static func save(_ snapshot: LibrarySnapshot) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: libraryURL, options: .atomic)
        } catch {
            NSLog("Music: не удалось сохранить библиотеку: \(error)")
        }
    }
}

// MARK: - Метаданные аудиофайла

enum MusicMetadata {
    struct Info {
        var title: String?
        var artist: String?
        var album: String?
        var duration: Double = 0
        var artworkData: Data?
        var playable = false
    }

    static func read(from url: URL) async -> Info {
        let asset = AVURLAsset(url: url)
        var info = Info()
        do {
            info.playable = try await asset.load(.isPlayable)
            let time = try await asset.load(.duration)
            info.duration = time.seconds.isFinite ? max(time.seconds, 0) : 0
        } catch {
            return info
        }
        let items: [AVMetadataItem] = (try? await asset.load(.commonMetadata)) ?? []
        info.title = await string(.commonIdentifierTitle, in: items)
        info.artist = await string(.commonIdentifierArtist, in: items)
        info.album = await string(.commonIdentifierAlbumName, in: items)
        if let art = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).first {
            if let data = try? await art.load(.dataValue) {
                info.artworkData = data
            } else if let value = try? await art.load(.value), let data = value as? Data {
                info.artworkData = data
            }
        }
        return info
    }

    private static func string(_ identifier: AVMetadataIdentifier, in items: [AVMetadataItem]) async -> String? {
        guard let item = AVMetadataItem.metadataItems(from: items, filteredByIdentifier: identifier).first else { return nil }
        let value = try? await item.load(.stringValue)
        return value?.nonEmpty
    }

    /// Уменьшает обложку до разумного размера и переводит в JPEG (оригиналы бывают по несколько мегабайт).
    static func jpegData(from data: Data, maxSide: CGFloat = 800) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return nil }
        let scale = min(1, maxSide / longest)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.85)
    }
}

// MARK: - Вспомогательное

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

func formatTime(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let total = Int(seconds.rounded(.down))
    let h = total / 3600
    let m = (total % 3600) / 60
    let s = total % 60
    if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
    return String(format: "%d:%02d", m, s)
}

/// «1 трек», «2 трека», «5 треков»
func trackCountText(_ n: Int) -> String {
    let mod100 = n % 100
    let mod10 = n % 10
    if mod100 >= 11 && mod100 <= 14 { return "\(n) треков" }
    switch mod10 {
    case 1: return "\(n) трек"
    case 2, 3, 4: return "\(n) трека"
    default: return "\(n) треков"
    }
}
