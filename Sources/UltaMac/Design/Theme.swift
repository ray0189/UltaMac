import SwiftUI

/// Design tokens. Every screen uses these instead of ad-hoc values (see docs/Design-System.md).
enum Theme {
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Horizontal page margin.
        static let page: CGFloat = 28
    }

    enum Radius {
        static let card: CGFloat = 16
        static let control: CGFloat = 10
        static let chip: CGFloat = 7
    }

    /// Brand gradient: calm teal into deep blue.
    static let brand = LinearGradient(
        colors: [Color(red: 0.13, green: 0.78, blue: 0.68), Color(red: 0.16, green: 0.42, blue: 0.95)],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static func gradient(_ tint: Tint) -> LinearGradient {
        LinearGradient(colors: tint.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Section tints. Kept to a small, deliberate palette.
    enum Tint: Hashable {
        case brand, clean, storage, apps, performance, tools, settings, warning, danger, success

        var colors: [Color] {
            switch self {
            case .brand: [Color(red: 0.13, green: 0.78, blue: 0.68), Color(red: 0.16, green: 0.42, blue: 0.95)]
            case .clean: [Color(red: 0.20, green: 0.80, blue: 0.55), Color(red: 0.06, green: 0.60, blue: 0.60)]
            case .storage: [Color(red: 0.35, green: 0.55, blue: 1.00), Color(red: 0.36, green: 0.30, blue: 0.90)]
            case .apps: [Color(red: 0.55, green: 0.40, blue: 0.98), Color(red: 0.80, green: 0.35, blue: 0.85)]
            case .performance: [Color(red: 1.00, green: 0.55, blue: 0.30), Color(red: 0.95, green: 0.30, blue: 0.45)]
            case .tools: [Color(red: 0.50, green: 0.55, blue: 0.65), Color(red: 0.30, green: 0.35, blue: 0.48)]
            case .settings: [Color(red: 0.55, green: 0.58, blue: 0.62), Color(red: 0.40, green: 0.42, blue: 0.47)]
            case .warning: [Color(red: 1.00, green: 0.72, blue: 0.20), Color(red: 0.98, green: 0.52, blue: 0.10)]
            case .danger: [Color(red: 1.00, green: 0.38, blue: 0.36), Color(red: 0.86, green: 0.18, blue: 0.30)]
            case .success: [Color(red: 0.25, green: 0.82, blue: 0.45), Color(red: 0.10, green: 0.65, blue: 0.45)]
            }
        }

        var color: Color { colors[0] }
    }
}

extension View {
    /// Standard card surface: subtle fill, hairline border, soft shadow in light mode.
    func cardSurface(padding: CGFloat = Theme.Space.l) -> some View {
        self.padding(padding)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07))
            }
    }
}

/// Motion helpers that honour System Settings › Accessibility › Reduce Motion.
enum Motion {
    static var reduce: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    static var standard: Animation? { reduce ? nil : .smooth(duration: 0.35) }
    static var gentle: Animation? { reduce ? nil : .smooth(duration: 0.8) }
    static var spring: Animation? { reduce ? nil : .spring(response: 0.4, dampingFraction: 0.8) }
}

func animate(_ animation: Animation? = Motion.standard, _ body: () -> Void) {
    withAnimation(animation, body)
}
