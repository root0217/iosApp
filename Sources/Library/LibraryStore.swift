import Foundation

enum LibraryLoadState: Equatable {
    case loading
    case loaded
    case error(String)
}

/// Состояние и бизнес-логика экрана «Библиотека». Один store на корневой экран: при навигации в подпапку
/// store просто перезапрашивает содержимое новой папки, обёртки экранов те же.
@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var currentFolderID: UUID?
    @Published private(set) var breadcrumbs: [Breadcrumb] = []
    @Published private(set) var folders: [LibFolder] = []
    @Published private(set) var files: [LibFile] = []
    @Published private(set) var state: LibraryLoadState = .loading
    @Published private(set) var usedBytes: Int64?
    @Published var filter: LibraryFilter = .all
    @Published var searchQuery = ""
    @Published var searchResults: [SearchHitOut]?
    @Published var toast: String?

    let uploads = UploadManager()
    private var searchTask: Task<Void, Never>?
    private var loadToken = UUID()

    init() {
        uploads.onFileUploaded = { [weak self] file, folderID in
            guard let self, folderID == self.currentFolderID else { return }
            self.files.removeAll { $0.id == file.id }
            self.files.append(file)
            self.files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task { await self.refreshUsage() }
        }
    }

    var visibleFiles: [LibFile] {
        filter == .all ? files : files.filter { filter.matches($0) }
    }

    func start() async {
        guard folders.isEmpty, files.isEmpty, state == .loading else { return }
        await load(folderID: nil)
        await refreshUsage()
    }

    func open(folder: LibFolder) async {
        await load(folderID: folder.id)
    }

    /// Переход в папку по одному лишь id — нужно для перехода из результатов поиска, где полного
    /// объекта папки нет, только id и название.
    func open(folderID: UUID) async {
        await load(folderID: folderID)
    }

    func openBreadcrumb(_ crumb: Breadcrumb) async {
        await load(folderID: crumb.id)
    }

    func goToRoot() async {
        await load(folderID: nil)
    }

    func refresh() async {
        await load(folderID: currentFolderID, keepExistingOnError: true)
    }

    private func load(folderID: UUID?, keepExistingOnError: Bool = false) async {
        let token = UUID()
        loadToken = token
        state = .loading
        do {
            let listing = try await LibraryService.listing(folderID: folderID)
            guard loadToken == token else { return }
            currentFolderID = folderID
            breadcrumbs = listing.breadcrumbs
            folders = listing.folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            files = listing.files.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            state = .loaded
        } catch {
            guard loadToken == token else { return }
            // при ошибке сети не затираем уже показанный список — только сообщаем о проблеме
            state = .error((error as? LocalizedError)?.errorDescription ?? "Не удалось загрузить")
            if !keepExistingOnError { folders = []; files = [] }
        }
    }

    private func refreshUsage() async {
        usedBytes = try? await LibraryService.usage().usedBytes
    }

    // MARK: Поиск (по всей библиотеке, не только текущей папке — так работает серверный /search)

    func search(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { searchResults = nil; return }
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            guard let hits = try? await LibraryService.search(query: trimmed) else { return }
            guard !Task.isCancelled else { return }
            searchResults = hits
        }
    }

    func clearSearch() {
        searchTask?.cancel()
        searchQuery = ""
        searchResults = nil
    }

    // MARK: Операции с файлами и папками (меняют сервер, потом локальный список)

    func createFolder(name: String) async {
        do {
            let folder = try await LibraryService.createFolder(name: name, parentID: currentFolderID)
            folders.append(folder)
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            toast = describeError(error, action: "создать папку")
        }
    }

    func rename(file: LibFile, to name: String) async {
        do {
            let updated = try await LibraryService.renameFile(file.id, to: name, ifMatch: file.version)
            replace(file: updated)
        } catch {
            toast = describeError(error, action: "переименовать файл")
            await refresh()
        }
    }

    func rename(folder: LibFolder, to name: String) async {
        do {
            let updated = try await LibraryService.renameFolder(folder.id, to: name, ifMatch: folder.version)
            replace(folder: updated)
        } catch {
            toast = describeError(error, action: "переименовать папку")
            await refresh()
        }
    }

    func move(file: LibFile, to folderID: UUID?) async {
        do {
            _ = try await LibraryService.moveFile(file.id, to: folderID, ifMatch: file.version)
            files.removeAll { $0.id == file.id }
            toast = "Перемещено"
        } catch {
            toast = describeError(error, action: "переместить файл")
        }
    }

    func move(folder: LibFolder, to parentID: UUID?) async {
        do {
            _ = try await LibraryService.moveFolder(folder.id, to: parentID, ifMatch: folder.version)
            folders.removeAll { $0.id == folder.id }
            toast = "Перемещено"
        } catch {
            toast = describeError(error, action: "переместить папку")
        }
    }

    func delete(file: LibFile) async {
        do {
            try await LibraryService.deleteFile(file.id, ifMatch: file.version)
            files.removeAll { $0.id == file.id }
            await refreshUsage()
        } catch {
            toast = describeError(error, action: "удалить файл")
        }
    }

    func delete(folder: LibFolder) async {
        do {
            try await LibraryService.deleteFolder(folder.id, ifMatch: folder.version)
            folders.removeAll { $0.id == folder.id }
            await refreshUsage()
        } catch {
            toast = describeError(error, action: "удалить папку")
        }
    }

    private func replace(file: LibFile) {
        guard let index = files.firstIndex(where: { $0.id == file.id }) else { return }
        files[index] = file
        files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func replace(folder: LibFolder) {
        guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { return }
        folders[index] = folder
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func describeError(_ error: Error, action: String) -> String {
        if case APIError.server(_, "version_conflict") = error {
            return "Не удалось \(action): данные изменились на сервере, список обновлён"
        }
        if case APIError.server(_, "name_conflict") = error {
            return "Такое имя уже занято"
        }
        return (error as? LocalizedError)?.errorDescription ?? "Не удалось \(action)"
    }
}
