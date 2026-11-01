import SwiftUI
import UIKit

struct FolderRow: View {
    let folder: LibFolder
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 44, height: 44)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(folder.name)
                    .font(.system(size: 15, weight: .medium))
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button { onRename() } label: { Label("Переименовать", systemImage: "pencil") }
            Button { onMove() } label: { Label("Переместить", systemImage: "folder") }
            Button(role: .destructive) { onDelete() } label: { Label("Удалить", systemImage: "trash") }
        }
    }
}

struct FileRow: View {
    let file: LibFile
    let onOpen: () -> Void
    let onDownload: () -> Void
    let onShare: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    let onInfo: () -> Void

    private var category: LibraryFilter { LibraryFilter.category(for: file) }

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                thumbnail
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .contextMenu {
            Button { onDownload() } label: { Label("Скачать", systemImage: "arrow.down.circle") }
            Button { onShare() } label: { Label("Поделиться", systemImage: "square.and.arrow.up") }
            Button { onRename() } label: { Label("Переименовать", systemImage: "pencil") }
            Button { onMove() } label: { Label("Переместить", systemImage: "folder") }
            Button { onInfo() } label: { Label("Сведения", systemImage: "info.circle") }
            Button(role: .destructive) { onDelete() } label: { Label("Удалить", systemImage: "trash") }
        }
    }

    @ViewBuilder
    private var thumbnail: some View {
        if category == .images {
            RemoteThumbnail(file: file)
        } else {
            Image(systemName: category.systemImage)
                .font(.system(size: 18))
                .foregroundStyle(Theme.secondary)
                .frame(width: 44, height: 44)
                .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var subtitle: String {
        var parts = [Format.size(file.sizeBytes)]
        parts.append(Format.relativeDate(file.updatedAt))
        return parts.joined(separator: " · ")
    }
}

/// Миниатюра изображения: качается полный файл через тот же LibraryDownloader и кэшируется в памяти на время сессии.
private struct RemoteThumbnail: View {
    let file: LibFile
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Theme.field
                Image(systemName: "photo")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .task(id: file.id) {
            if let cached = ThumbnailCache.shared.image(for: file.id) { image = cached; return }
            guard let url = try? await LibraryDownloader.download(file), let data = try? Data(contentsOf: url) else { return }
            if let loaded = UIImage(data: data) {
                let scaled = loaded.preparingThumbnail(of: CGSize(width: 88, height: 88)) ?? loaded
                ThumbnailCache.shared.set(scaled, for: file.id)
                image = scaled
            }
        }
    }
}

final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSUUID, UIImage>()
    private init() {}
    func image(for id: UUID) -> UIImage? { cache.object(forKey: id as NSUUID) }
    func set(_ image: UIImage, for id: UUID) { cache.setObject(image, forKey: id as NSUUID) }
}
