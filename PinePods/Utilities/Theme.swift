import SwiftUI

let PineGreen = Color(red: 0.33, green: 0.62, blue: 0.54)

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
