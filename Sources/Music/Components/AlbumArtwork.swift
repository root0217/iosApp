import SwiftUI
import UIKit

/// Кэш обложек: читаем с диска один раз, дальше берём из памяти.
final class ArtworkCache {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, UIImage>()
    private init() {}

    func image(named name: String?) async -> UIImage? {
        guard let name = name else { return nil }
        if let cached = cache.object(forKey: name as NSString) { return cached }
        let path = MusicStorage.artworkURL(named: name).path
        let loaded: UIImage? = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: UIImage(contentsOfFile: path))
            }
        }
        if let loaded = loaded { cache.setObject(loaded, forKey: name as NSString) }
        return loaded
    }

    func remove(named name: String) {
        cache.removeObject(forKey: name as NSString)
    }
}

/// Обложка трека; если её нет, показывается нейтральная заглушка с нотой.
struct AlbumArtwork: View {
    let fileName: String?
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                LinearGradient(colors: [Color(light: 0xE6E6EA, dark: 0x3A3A3E),
                                        Color(light: 0xD2D2D8, dark: 0x2A2A2E)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.4, weight: .light))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: fileName) {
            image = await ArtworkCache.shared.image(named: fileName)
        }
    }
}
