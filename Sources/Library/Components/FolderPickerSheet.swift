import SwiftUI

/// Простой выбор папки назначения для операции «Переместить»: идём вглубь по дереву, как в самой библиотеке.
struct FolderPickerSheet: View {
    let title: String
    let excludingSubtreeOf: UUID?       // при перемещении папки нельзя выбрать её же саму или её потомков
    let onPick: (UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var folderID: UUID?
    @State private var folderName = "Библиотека"
    @State private var breadcrumbs: [Breadcrumb] = []
    @State private var folders: [LibFolder] = []
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                } else if folders.isEmpty {
                    Text("Вложенных папок нет").foregroundStyle(Theme.secondary)
                } else {
                    List(folders) { folder in
                        Button {
                            Task { await load(folderID: folder.id) }
                        } label: {
                            Label(folder.name, systemImage: "folder")
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle(folderName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Отмена") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(title) {
                        onPick(folderID)
                        dismiss()
                    }
                }
            }
            .task { await load(folderID: nil) }
        }
    }

    private func load(folderID: UUID?) async {
        isLoading = true
        if let listing = try? await LibraryService.listing(folderID: folderID) {
            self.folderID = folderID
            self.breadcrumbs = listing.breadcrumbs
            self.folderName = listing.folder?.name ?? "Библиотека"
            self.folders = listing.folders.filter { $0.id != excludingSubtreeOf }
        }
        isLoading = false
    }
}
