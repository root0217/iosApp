import SwiftUI

struct SearchHitRow: View {
    let hit: SearchHitOut
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 12) {
                Image(systemName: hit.type == "folder" ? "folder.fill" : "doc")
                    .font(.system(size: 18))
                    .foregroundStyle(hit.type == "folder" ? Theme.accent : Theme.secondary)
                    .frame(width: 44, height: 44)
                    .background(Theme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(hit.type == "folder" ? "Папка" : (hit.subtitle ?? "Файл"))
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .frame(height: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }
}
