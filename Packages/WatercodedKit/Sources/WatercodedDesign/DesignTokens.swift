import SwiftUI

/// Spacing scale (points). Use these instead of literals so layouts stay consistent.
public enum Spacing {
    public static let xxSmall: CGFloat = 2
    public static let xSmall: CGFloat = 4
    public static let small: CGFloat = 8
    public static let medium: CGFloat = 12
    public static let large: CGFloat = 16
    public static let xLarge: CGFloat = 24
    public static let xxLarge: CGFloat = 32
}

/// Corner radii. Glass shapes use continuous corners.
public enum Radius {
    public static let small: CGFloat = 6
    public static let medium: CGFloat = 8
    public static let large: CGFloat = 12
    public static let vessel: CGFloat = 8
}

/// Motion vocabulary for UI transitions (water has its own physics in Meniscus).
public enum Motion {
    public static let standard = Animation.smooth(duration: 0.35)
    public static let quick = Animation.smooth(duration: 0.2)
    public static let morph = Animation.bouncy(duration: 0.45, extraBounce: 0.05)
}

/// Fixed sizes for recurring elements.
public enum Metrics {
    public static let glyphSize = CGSize(width: 22, height: 30)
    public static let composerMaxLines = 10
    public static let suggestionVisibleRows = 8
    public static let suggestionRowHeight: CGFloat = 30
    public static let readableWidth: CGFloat = 760
}

extension Color {
    /// The water tint for a provider. Water always reads as water (aqua); the provider's hue only
    /// nudges it, so a warm brand color never looks like dirty water (murk means failure).
    public static func waterTint(hue: Double) -> Color {
        let aqua = 0.55
        let offset = ((hue - aqua + 0.5).truncatingRemainder(dividingBy: 1) + 1)
            .truncatingRemainder(dividingBy: 1) - 0.5
        return Color(hue: aqua + offset * 0.12, saturation: 0.62, brightness: 0.82)
    }
}
