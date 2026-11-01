import SwiftUI
import QuickLook
import AVKit

/// Обёртка над QLPreviewController: показывает изображения, PDF, текст и, как правило, офисные форматы
/// (docx/xlsx/pptx) — то, что реально умеет сама система, без обещаний сверх этого.
struct QuickLookView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let item: NSURL
        init(url: URL) { item = url as NSURL }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { item }
    }
}

struct VideoPlayerScreen: View {
    let url: URL
    var body: some View {
        VideoPlayer(player: AVPlayer(url: url))
            .ignoresSafeArea()
    }
}

/// Скачивает файл во временную папку (если ещё не скачан) и показывает подходящий просмотрщик.
/// Тип файла, который приложение честно не умеет показать, сразу получает share-меню вместо фейкового превью.
struct FilePreviewHost: View {
    let file: LibFile

    @State private var localURL: URL?
    @State private var error: String?

    var body: some View {
        Group {
            if let localURL = localURL {
                if LibraryFilter.category(for: file) == .video {
                    VideoPlayerScreen(url: localURL)
                } else if QLPreviewController.canPreview(localURL as QLPreviewItem) {
                    QuickLookView(url: localURL)
                } else {
                    unsupportedView(localURL: localURL)
                }
            } else if let error = error {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30))
                        .foregroundStyle(Theme.secondary)
                    Text(error).font(.system(size: 14)).foregroundStyle(Theme.secondary)
                }
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .task { await load() }
    }

    private func unsupportedView(localURL: URL) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "doc")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(Theme.secondary)
            Text("Предпросмотр недоступен для этого формата")
                .font(.system(size: 15))
                .foregroundStyle(Theme.secondary)
            ShareLink(item: localURL) {
                Text("Поделиться").font(.system(size: 15, weight: .semibold))
            }
        }
    }

    private func load() async {
        do {
            localURL = try await LibraryDownloader.download(file)
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? "Не удалось скачать файл"
        }
    }
}

/// Скачивание файла целиком во временный кэш приложения (для превью, «Поделиться» и открытия в Музыке).
/// Для очень больших файлов (видео) это не идеально, но соответствует тому, что умеет текущий клиентский слой.
enum LibraryDownloader {
    static func download(_ file: LibFile) async throws -> URL {
        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("library-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let destination = cacheDir.appendingPathComponent("\(file.id.uuidString)-v\(file.version)-\(file.name)")
        if FileManager.default.fileExists(atPath: destination.path) { return destination }

        let link = try await LibraryService.downloadLink(fileID: file.id)
        let (tempURL, response) = try await URLSession.shared.download(from: link)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw APIError.server(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: nil)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}
