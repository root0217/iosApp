import SwiftUI

struct FileInfoSheet: View {
    let file: LibFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row("Название", file.name)
                row("Исходное имя", file.originalName)
                row("Тип", file.mimeType)
                row("Размер", Format.size(file.sizeBytes))
                row("Добавлен", file.createdAt.formatted(date: .abbreviated, time: .shortened))
                row("Изменён", file.updatedAt.formatted(date: .abbreviated, time: .shortened))
                row("SHA-256", String(file.sha256.prefix(16)) + "…")
            }
            .navigationTitle("Сведения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Готово") { dismiss() } }
            }
        }
        .presentationDetents([.medium])
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(Theme.secondary)
            Spacer()
            Text(value).lineLimit(1).truncationMode(.middle)
        }
        .font(.system(size: 14))
    }
}
