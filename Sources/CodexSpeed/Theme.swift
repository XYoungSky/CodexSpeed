import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var appearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
    func title(_ language: AppLanguage) -> String {
        switch self {
        case .system: return language.text("System", "跟随系统")
        case .light: return language.text("Light", "浅色")
        case .dark: return language.text("Dark", "深色")
        }
    }
}

enum HUDBackground: String, CaseIterable, Identifiable {
    case glass, solid, transparent
    var id: String { rawValue }

    static func saved(in defaults: UserDefaults = .standard) -> HUDBackground {
        if let value=defaults.string(forKey:"background"), let style=HUDBackground(rawValue:value) { return style }
        // Preserve the original Liquid Glass preference for existing installations.
        return defaults.object(forKey:"liquidGlass") as? Bool == false ? .solid : .glass
    }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .glass: return "Liquid Glass"
        case .solid: return language.text("Solid", "实色")
        case .transparent: return language.text("Transparent", "纯透明")
        }
    }
}

struct HUDSurface: ViewModifier {
    let style: HUDBackground
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    func body(content: Content) -> some View {
        if style == .transparent {
            // No material, tint, blur, border or background layer.
            content
        } else if #available(macOS 26.0, *), style == .glass, !reduceTransparency {
            content.glassEffect(.regular, in: .rect(cornerRadius: 16))
        } else {
            content.background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 16))
        }
    }
}
