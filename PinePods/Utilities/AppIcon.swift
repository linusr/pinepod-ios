import UIKit

/// Switches between the primary and alternate Home Screen icons.
@MainActor
enum AppIcon {
    static var current: AccentTheme {
        let name = UIApplication.shared.alternateIconName
        return AccentTheme.allCases.first { $0.iconName == name } ?? .pine
    }

    /// iOS confirms every change with its own alert; there is no silent switch.
    static func apply(_ theme: AccentTheme) {
        let application = UIApplication.shared
        guard application.supportsAlternateIcons, application.alternateIconName != theme.iconName else { return }
        Task {
            do {
                try await application.setAlternateIconName(theme.iconName)
            } catch {
                NSLog("[PinePods] app icon change failed: %@", error.localizedDescription)
            }
        }
    }
}
