import SwiftUI

/// Какой раздел приложения сейчас на экране. Сайдбар переключает его, RootView показывает нужный экран.
enum AppSection: Hashable {
    case chat
    case music
    case library
}

final class AppRouter: ObservableObject {
    @Published var section: AppSection = .chat
}
