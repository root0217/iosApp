import SwiftUI

/// Полоса активных загрузок над списком: имя, прогресс, ошибка. Не перекрывает весь экран —
/// загрузка не должна блокировать работу с остальной библиотекой.
struct UploadBanner: View {
    @ObservedObject var uploads: UploadManager

    var body: some View {
        VStack(spacing: 6) {
            ForEach(uploads.items) { item in
                UploadRow(item: item)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

private struct UploadRow: View {
    @ObservedObject var item: UploadItem

    var body: some View {
        HStack(spacing: 10) {
            icon
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                progressLine
            }
            Spacer()
        }
        .padding(10)
        .background(Theme.field, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var icon: some View {
        switch item.status {
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        default:
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private var progressLine: some View {
        switch item.status {
        case .queued:
            Text("В очереди").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        case .uploading(let progress):
            ProgressView(value: progress).tint(Theme.accent)
        case .finishing:
            Text("Завершается…").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        case .done:
            Text("Готово").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        case .failed(let message):
            Text(message).font(.system(size: 11)).foregroundStyle(.red).lineLimit(1)
        }
    }
}
