import Foundation

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all = "Все"
    case images = "Изображения"
    case documents = "Документы"
    case spreadsheets = "Таблицы"
    case presentations = "Презентации"
    case pdf = "PDF"
    case audio = "Аудио"
    case video = "Видео"
    case other = "Другие файлы"

    var id: String { rawValue }

    /// Категория по MIME-типу и, если он общий ("application/octet-stream"), по расширению.
    func matches(_ file: LibFile) -> Bool {
        guard self != .all else { return true }
        return Self.category(for: file) == self
    }

    static func category(for file: LibFile) -> LibraryFilter {
        let mime = file.mimeType.lowercased()
        let ext = file.extensionName.lowercased()
        if mime.hasPrefix("image/") { return .images }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        if mime == "application/pdf" { return .pdf }
        if mime.contains("spreadsheet") || ["xlsx", "xls", "csv", "numbers"].contains(ext) { return .spreadsheets }
        if mime.contains("presentation") || ["pptx", "ppt", "key"].contains(ext) { return .presentations }
        if mime.hasPrefix("text/") || mime.contains("word") || mime.contains("document")
            || ["doc", "docx", "txt", "md", "rtf", "pages"].contains(ext) { return .documents }
        return .other
    }

    var systemImage: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .images: return "photo"
        case .documents: return "doc.text"
        case .spreadsheets: return "tablecells"
        case .presentations: return "rectangle.on.rectangle"
        case .pdf: return "doc.richtext"
        case .audio: return "music.note"
        case .video: return "film"
        case .other: return "doc"
        }
    }
}
