import SwiftUI
import UIKit

/// Аватар с сервера: путь вроде "/v1/auth/users/{id}/avatar" резолвится в абсолютный URL и
/// качается напрямую (без авторизации — сервер отдаёт аватары открыто, см. backend), с кэшем
/// в памяти на время сессии. Если аватара нет или путь не задан — нейтральная заглушка с инициалом.
struct RemoteAvatar: View {
    let urlPath: String?
    let fallbackText: String
    var size: CGFloat

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(Theme.field)
                Text(initial)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: urlPath) { await load() }
    }

    private var initial: String {
        String(fallbackText.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    private func load() async {
        guard let path = urlPath, let url = await APIClient.shared.absoluteURL(forServerPath: path) else {
            image = nil
            return
        }
        if let cached = RemoteAvatarCache.shared.image(for: url) {
            image = cached
            return
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let loaded = UIImage(data: data) else { return }
        RemoteAvatarCache.shared.set(loaded, for: url)
        image = loaded
    }
}

final class RemoteAvatarCache {
    static let shared = RemoteAvatarCache()
    private let cache = NSCache<NSURL, UIImage>()
    private init() {}
    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }
    func set(_ image: UIImage, for url: URL) { cache.setObject(image, forKey: url as NSURL) }
}
