import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

private enum LibraryPrompt: Identifiable {
    case newFolder
    case renameFile(LibFile)
    case renameFolder(LibFolder)
    var id: String {
        switch self {
        case .newFolder: return "new-folder"
        case .renameFile(let f): return "rf-\(f.id)"
        case .renameFolder(let f): return "rd-\(f.id)"
        }
    }
}

private enum LibraryMoveTarget: Identifiable {
    case file(LibFile)
    case folder(LibFolder)
    var id: String {
        switch self {
        case .file(let f): return "mf-\(f.id)"
        case .folder(let f): return "md-\(f.id)"
        }
    }
}

private enum LibraryDeleteTarget: Identifiable {
    case file(LibFile)
    case folder(LibFolder)
    var id: String {
        switch self {
        case .file(let f): return "df-\(f.id)"
        case .folder(let f): return "dd-\(f.id)"
        }
    }
}

/// Главный экран «Библиотека»: папки и файлы, фильтры, закреплённая нижняя панель поиска и добавления.
/// Авторизация теперь проверяется один раз на уровне всего приложения (AuthGate), а не здесь отдельно.
struct LibraryView: View {
    @EnvironmentObject var auth: AuthSession
    @EnvironmentObject var music: MusicManager
    let openDrawer: () -> Void

    @StateObject private var library = LibraryStore()
    @State private var prompt: LibraryPrompt?
    @State private var promptText = ""
    @State private var moveTarget: LibraryMoveTarget?
    @State private var deleteTarget: LibraryDeleteTarget?
    @State private var infoFile: LibFile?
    @State private var previewFile: LibFile?
    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            topBar
            filterBar
            uploadBanner
            listContent
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
        .overlay(alignment: .top) { toast }
        .task { await library.start() }
        .refreshable { await library.refresh() }
        .photosPicker(isPresented: photosPickerBinding, selection: $photoSelection, maxSelectionCount: 10, matching: .images)
        .onChange(of: photoSelection) { items in handlePhotoSelection(items) }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                library.uploads.enqueue(urls: urls, folderID: library.currentFolderID, needsSecurityScope: true)
            }
        }
        .sheet(item: $moveTarget) { target in
            switch target {
            case .file(let file):
                FolderPickerSheet(title: "Сюда", excludingSubtreeOf: nil) { destination in
                    Task { await library.move(file: file, to: destination) }
                }
            case .folder(let folder):
                FolderPickerSheet(title: "Сюда", excludingSubtreeOf: folder.id) { destination in
                    Task { await library.move(folder: folder, to: destination) }
                }
            }
        }
        .sheet(item: $infoFile) { file in FileInfoSheet(file: file) }
        .fullScreenCover(item: $previewFile) { file in
            FilePreviewScreen(file: file, music: music)
        }
        .alert(promptTitle, isPresented: promptBinding) {
            TextField("Название", text: $promptText)
            Button("Отмена", role: .cancel) {}
            Button("Готово") { Task { await commitPrompt() } }
        }
        .confirmationDialog(deleteTitle, isPresented: deleteBinding, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { Task { await performDelete() } }
            Button("Отмена", role: .cancel) {}
        }
        .onChange(of: library.toast) { value in
            guard let value else { return }
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                if library.toast == value { library.toast = nil }
            }
        }
    }

    // MARK: Верхняя панель

    private var topBar: some View {
        HStack(spacing: 12) {
            if library.currentFolderID != nil {
                Button { Task { await library.goToRoot() } } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
            } else {
                Button(action: openDrawer) { MenuGlyph() }
            }
            Text(library.breadcrumbs.last?.name ?? "Библиотека")
                .font(Typo.title)
                .lineLimit(1)
            Spacer()
            if let used = library.usedBytesDisplay {
                Text(used)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 6)
        .frame(height: 44)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LibraryFilter.allCases) { item in
                    Button { library.filter = item } label: {
                        Text(item.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(library.filter == item ? Color.white : Color.primary)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(library.filter == item ? Theme.accent : Theme.field, in: Capsule())
                    }
                }
            }
            .padding(.horizontal, 16)
        }
        .buttonStyle(PressableStyle())
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var uploadBanner: some View {
        if !library.uploads.items.isEmpty {
            UploadBanner(uploads: library.uploads)
        }
    }

    // MARK: Список

    @ViewBuilder
    private var listContent: some View {
        if let results = library.searchResults {
            searchResultsList(results)
        } else {
            switch library.state {
            case .loading where library.folders.isEmpty && library.files.isEmpty:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .error(let message) where library.folders.isEmpty && library.files.isEmpty:
                emptyState(icon: "wifi.slash", title: "Сервер недоступен", text: message)
            default:
                folderList
            }
        }
    }

    private var folderList: some View {
        let files = library.visibleFiles
        return Group {
            if library.folders.isEmpty && files.isEmpty {
                emptyState(
                    icon: library.filter == .all ? "tray" : library.filter.systemImage,
                    title: library.filter == .all ? "Здесь пока пусто" : "Нет файлов в категории «\(library.filter.rawValue)»",
                    text: library.filter == .all ? "Добавьте файлы кнопкой «+» внизу" : "Попробуйте другую категорию")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        if case .error(let message) = library.state {
                            inlineErrorBanner(message)
                        }
                        ForEach(library.folders) { folder in
                            FolderRow(folder: folder,
                                     onOpen: { Task { await library.open(folder: folder) } },
                                     onRename: { promptText = folder.name; prompt = .renameFolder(folder) },
                                     onMove: { moveTarget = .folder(folder) },
                                     onDelete: { deleteTarget = .folder(folder) })
                        }
                        ForEach(files) { file in
                            FileRow(file: file,
                                   onOpen: { openFile(file) },
                                   onDownload: { Task { await downloadToFiles(file) } },
                                   onShare: { Task { await share(file) } },
                                   onRename: { promptText = file.name; prompt = .renameFile(file) },
                                   onMove: { moveTarget = .file(file) },
                                   onDelete: { deleteTarget = .file(file) },
                                   onInfo: { infoFile = file })
                        }
                        if !files.isEmpty && library.folders.isEmpty && library.filter != .all {
                            Color.clear.frame(height: 0)
                        } else if files.isEmpty && !library.folders.isEmpty && library.filter != .all {
                            Text("Нет файлов в категории «\(library.filter.rawValue)»")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.secondary)
                                .padding(.top, 24)
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private func searchResultsList(_ hits: [SearchHitOut]) -> some View {
        Group {
            if hits.isEmpty {
                emptyState(icon: "magnifyingglass", title: "Ничего не найдено", text: "Попробуйте другой запрос")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(hits) { hit in
                            SearchHitRow(hit: hit) { Task { await openSearchHit(hit) } }
                        }
                    }
                }
            }
        }
    }

    private func inlineErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 13))
            Text(message).font(.system(size: 12)).lineLimit(2)
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func emptyState(icon: String, title: String, text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon).font(.system(size: 38, weight: .light)).foregroundStyle(Theme.secondary)
            Text(title).font(.system(size: 17, weight: .semibold))
            Text(text).font(.system(size: 14)).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
            Spacer()
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity)
    }

    // MARK: Нижняя закреплённая панель

    private var bottomBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(Theme.secondary)
                TextField("Поиск по библиотеке", text: $library.searchQuery)
                    .font(Typo.input)
                    .focused($searchFocused)
                    .onChange(of: library.searchQuery) { library.search($0) }
                if !library.searchQuery.isEmpty {
                    Button { library.clearSearch() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary)
                    }
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Theme.field, in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Menu {
                Button { photoSelection = []; showPhotosPicker = true } label: { Label("Добавить фото", systemImage: "photo") }
                Button { showCamera = true } label: { Label("Сделать фото", systemImage: "camera") }
                Button { showFileImporter = true } label: { Label("Добавить файл", systemImage: "doc.badge.plus") }
                Button { promptText = ""; prompt = .newFolder } label: { Label("Новая папка", systemImage: "folder.badge.plus") }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Theme.accent, in: Circle())
            }
        }
        .buttonStyle(PressableStyle())
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showCamera) {
            CameraCapture { url in
                if let url { library.uploads.enqueue(name: url.lastPathComponent, temporaryFileURL: url, folderID: library.currentFolderID) }
            }
        }
    }

    // чуть неудобно, но PhotosPicker требует Bool-биндинг, а меню выше работает через state ниже
    @State private var showPhotosPicker = false
    @State private var showCamera = false
    private var photosPickerBinding: Binding<Bool> {
        Binding(get: { showPhotosPicker }, set: { showPhotosPicker = $0 })
    }

    @ViewBuilder
    private var toast: some View {
        if let message = library.toast {
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .padding(.top, 54)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // MARK: Действия

    private func openFile(_ file: LibFile) {
        if LibraryFilter.category(for: file) == .audio {
            Task { await playInMusic(file) }
        } else {
            previewFile = file
        }
    }

    private func playInMusic(_ file: LibFile) async {
        do {
            let url = try await LibraryDownloader.download(file)
            music.importAndPlay(fileAt: url, suggestedName: file.name)
        } catch {
            library.toast = "Не удалось открыть в Музыке"
        }
    }

    private func downloadToFiles(_ file: LibFile) async {
        do { _ = try await LibraryDownloader.download(file); library.toast = "Скачано" }
        catch { library.toast = "Не удалось скачать" }
    }

    private func share(_ file: LibFile) async {
        guard let url = try? await LibraryDownloader.download(file) else { library.toast = "Не удалось подготовить файл"; return }
        await MainActor.run {
            let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            UIApplication.shared.topViewController()?.present(sheet, animated: true)
        }
    }

    private func handlePhotoSelection(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        Task {
            for item in items {
                guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
                let ext = (item.supportedContentTypes.first?.preferredFilenameExtension) ?? "jpg"
                let name = "Фото-\(Int(Date().timeIntervalSince1970)).\(ext)"
                let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
                try? data.write(to: tmp)
                library.uploads.enqueue(name: name, temporaryFileURL: tmp, folderID: library.currentFolderID)
            }
            photoSelection = []
        }
    }

    /// Результат поиска — переход к самому объекту: для папки это переход внутрь, для файла — открытие.
    private func openSearchHit(_ hit: SearchHitOut) async {
        guard let id = UUID(uuidString: hit.id) else { return }
        library.clearSearch()
        if hit.type == "folder" {
            await library.open(folderID: id)
        } else if hit.type == "file" {
            guard let file = try? await LibraryService.fileMeta(id: id) else {
                library.toast = "Файл не найден"
                return
            }
            openFile(file)
        }
    }

    // MARK: Промпты

    private var promptBinding: Binding<Bool> { Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }) }
    private var promptTitle: String {
        switch prompt {
        case .newFolder: return "Новая папка"
        case .renameFile: return "Переименовать файл"
        case .renameFolder: return "Переименовать папку"
        case .none: return ""
        }
    }

    private func commitPrompt() async {
        let name = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let prompt, !name.isEmpty else { return }
        switch prompt {
        case .newFolder: await library.createFolder(name: name)
        case .renameFile(let f): await library.rename(file: f, to: name)
        case .renameFolder(let f): await library.rename(folder: f, to: name)
        }
    }

    private var deleteBinding: Binding<Bool> { Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }) }
    private var deleteTitle: String {
        switch deleteTarget {
        case .file(let f): return "Удалить «\(f.name)»?"
        case .folder(let f): return "Удалить папку «\(f.name)» со всем содержимым?"
        case .none: return ""
        }
    }

    private func performDelete() async {
        guard let deleteTarget else { return }
        switch deleteTarget {
        case .file(let f): await library.delete(file: f)
        case .folder(let f): await library.delete(folder: f)
        }
    }
}

private extension LibraryStore {
    var usedBytesDisplay: String? { usedBytes.map { Format.size($0) } }
}

extension UIApplication {
    func topViewController(base: UIViewController? = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first?.rootViewController) -> UIViewController? {
        if let nav = base as? UINavigationController { return topViewController(base: nav.visibleViewController) }
        if let tab = base as? UITabBarController { return topViewController(base: tab.selectedViewController) }
        if let presented = base?.presentedViewController { return topViewController(base: presented) }
        return base
    }
}
