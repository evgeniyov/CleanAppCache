import SwiftUI

// MARK: - Color theme
//
// Two themes. Light is the reference set and dark is derived from it by
// structure rather than by mood — same cards, same radii.
//
// The palette is closed at these two: any further theme would need some forty
// colours of its own that the design system does not define.

public enum AppTheme: String, CaseIterable, Identifiable, Sendable {
    case light, dark
    public var id: String { rawValue }

    var labelKey: String { "theme.\(rawValue)" }

    public var isDark: Bool { self == .dark }
    public var colorScheme: ColorScheme { isDark ? .dark : .light }

    /// Primary accent — fills: buttons, checkboxes, gauges, the chart line.
    public var accent: Color { tokens.accent }

    /// Light accent, for E-cores and secondary bars.
    public var accent2: Color { tokens.accentBarLight }

    /// Content-area ground.
    public var background: Color { tokens.background }
}

@MainActor
public final class ThemeManager: ObservableObject {
    public static let shared = ThemeManager()

    private static let themeKey = "app.theme"

    @Published public var theme: AppTheme {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: Self.themeKey) }
    }

    private init() {
        // Light is the default. A stored value from an older build ("ocean",
        // "sunset") does not resolve; anything unrecognised lands on
        // light rather than on whichever case happens to be first.
        theme = AppTheme(rawValue: UserDefaults.standard.string(forKey: Self.themeKey) ?? "") ?? .light
    }
}

// MARK: - Color hex helper

public extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}
