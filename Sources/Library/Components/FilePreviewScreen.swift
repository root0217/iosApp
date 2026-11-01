import SwiftUI

/// Полноэкранный просмотр файла из библиотеки: заголовок с закрытием и «Поделиться», ниже сам просмотрщик.
struct FilePreviewScreen: View {
    let file: LibFile
    let music: MusicManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            FilePreviewHost(file: file)
                .navigationTitle(file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Закрыть") { dismiss() }
                    }
                }
        }
    }
}
