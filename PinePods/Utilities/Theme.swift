import SwiftUI

/// Accent colors the user can pick. Each has a matching alternate app icon.
enum AccentTheme: String, CaseIterable, Identifiable, Codable, Sendable {
    case pine, ocean, indigo, violet, rose, crimson, tangerine, amber, teal, graphite

    var id: String { rawValue }

    var name: String {
        switch self {
        case .pine: "Pine"
        case .ocean: "Ocean"
        case .indigo: "Indigo"
        case .violet: "Violet"
        case .rose: "Rose"
        case .crimson: "Crimson"
        case .tangerine: "Tangerine"
        case .amber: "Amber"
        case .teal: "Teal"
        case .graphite: "Graphite"
        }
    }

    /// Mid-tone values chosen to stay legible on both light and dark backgrounds.
    var hex: UInt32 {
        switch self {
        case .pine: 0x549E8A
        case .ocean: 0x2F7FD6
        case .indigo: 0x5856D6
        case .violet: 0x8E5CE6
        case .rose: 0xE0558A
        case .crimson: 0xD64541
        case .tangerine: 0xE8793A
        case .amber: 0xC08A1E
        case .teal: 0x1A98A8
        case .graphite: 0x5F6B7A
        }
    }

    var color: Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    /// Alternate icon in the asset catalog; nil is the primary (pine) icon.
    var iconName: String? {
        self == .pine ? nil : "AppIcon-\(name)"
    }
}

@MainActor
enum Theme {
    /// The user's accent. Views that read it re-render when it changes.
    static var accent: Color { SettingsStore.shared.accent.color }
}

/// SF Symbols only ships numbered skip glyphs for these intervals.
enum SkipSymbol {
    static let intervals = [5, 10, 15, 30, 45, 60, 75, 90]

    static func forward(_ seconds: Int) -> String {
        intervals.contains(seconds) ? "goforward.\(seconds)" : "goforward"
    }

    static func backward(_ seconds: Int) -> String {
        intervals.contains(seconds) ? "gobackward.\(seconds)" : "gobackward"
    }
}

enum PlaybackSpeed {
    static let options: [Double] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.5, 3.0]

    static func label(_ speed: Double) -> String {
        speed.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// Scale-and-fade press feedback for icon and pill buttons.
struct PressableButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}
