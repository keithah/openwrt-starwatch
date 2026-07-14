import SwiftUI
import WattlineCore

@MainActor
public enum WattlineTheme {
    public static let accent = Color.indigo
    public static let charging = Color.green
    public static let discharging = Color.orange
    public static let surface = Color(red: 0.08, green: 0.09, blue: 0.12)
    public static let raisedSurface = Color(red: 0.115, green: 0.125, blue: 0.16)
    public static let recessedSurface = Color(red: 0.055, green: 0.06, blue: 0.08)
    public static let border = Color.white.opacity(0.1)
    public static let secondaryText = Color.white.opacity(0.62)
    public static let idle = Color.white.opacity(0.72)

    public static func color(for flow: PowerFlow) -> Color {
        switch flow {
        case .charging: charging
        case .discharging: discharging
        case .idle: idle
        }
    }
}

public struct WattlinePanel: ViewModifier {
    private let compact: Bool

    public init(compact: Bool = false) {
        self.compact = compact
    }

    public func body(content: Content) -> some View {
        content
            .padding(compact ? 14 : 18)
            .background(WattlineTheme.raisedSurface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(WattlineTheme.border, lineWidth: 1)
            }
    }
}

public extension View {
    func wattlinePanel(compact: Bool = false) -> some View {
        modifier(WattlinePanel(compact: compact))
    }
}

extension PowerFlow {
    var wattlineName: String {
        switch self {
        case .charging: "Charging"
        case .discharging: "Discharging"
        case .idle: "Idle"
        }
    }

    var wattlineSymbol: String {
        switch self {
        case .charging: "arrow.down"
        case .discharging: "arrow.up"
        case .idle: "minus"
        }
    }
}

extension Double {
    func wattlineFormatted(decimals: Int = 1) -> String {
        guard isFinite else { return "—" }
        return formatted(.number.precision(.fractionLength(decimals)))
    }
}
