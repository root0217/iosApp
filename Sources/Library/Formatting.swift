import Foundation

enum Format {
    static let bytes: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f
    }()

    static let date: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        f.locale = Locale(identifier: "ru_RU")
        return f
    }()

    static func size(_ value: Int64) -> String { bytes.string(fromByteCount: value) }

    static func relativeDate(_ value: Date) -> String {
        date.localizedString(for: value, relativeTo: Date())
    }
}
