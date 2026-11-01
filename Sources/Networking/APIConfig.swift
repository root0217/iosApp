import Foundation

/// Адрес сервера хранится в UserDefaults и меняется в настройках — в код не зашит,
/// чтобы при переезде с ноутбука на VPS не пересобирать приложение.
enum APIConfig {
    private static let key = "api.baseURL"
    private static let fallback = "http://192.168.3.15:8000"

    static var baseURL: URL {
        get {
            let raw = UserDefaults.standard.string(forKey: key) ?? fallback
            return URL(string: raw) ?? URL(string: fallback)!
        }
        set {
            var raw = newValue.absoluteString
            while raw.hasSuffix("/") { raw.removeLast() }
            UserDefaults.standard.set(raw, forKey: key)
        }
    }

    static var baseURLText: String { baseURL.absoluteString }

    /// true, если строка похожа на корректный http(s)-адрес.
    static func isValid(_ text: String) -> Bool {
        guard let url = URL(string: text), let scheme = url.scheme, let host = url.host else { return false }
        return (scheme == "http" || scheme == "https") && !host.isEmpty
    }
}
