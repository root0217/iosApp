import SwiftUI
import UIKit

enum AppConfig {
    /// Заголовок сайдбара
    static let name = "Меню"
    /// Подсказка в поле ввода
    static let placeholder = "Сообщение"
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        })
    }
}

enum Theme {
    static let background = Color(light: 0xFCFCFC, dark: 0x121212)
    static let field      = Color(light: 0xEFEFEF, dark: 0x2A2A2C)
    static let card       = Color(light: 0xFFFFFF, dark: 0x2A2A2C)
    static let accent     = Color(light: 0x2F5BE8, dark: 0x3D6BF2)
    static let updateBg   = Color(light: 0xE8F2FE, dark: 0x1B2A40)
    static let updateFg   = Color(light: 0x1A7CF0, dark: 0x5AA2FF)
    static let secondary  = Color(light: 0x8A8A8E, dark: 0x8E8E93)
}

/// Все шрифты в одном месте. Размеры сняты по скриншотам оригинала (высота заглавных букв и толщина штриха), гарнитура SF Pro.
enum Typo {
    static let title    = Font.system(size: 19.5, weight: .semibold)
    static let menuItem = Font.system(size: 14, weight: .medium)     // меню и история одного кегля, меню плотнее
    static let history  = Font.system(size: 14, weight: .regular)
    static let pill     = Font.system(size: 12, weight: .semibold)
    static let button   = Font.system(size: 14.5, weight: .semibold)
    static let input    = Font.system(size: 14, weight: .regular)
    static let body     = Font.system(size: 16, weight: .regular)    // текст сообщений: по скриншотам не измерить
}

/// Мягкая реакция на нажатие, как в оригинале.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
