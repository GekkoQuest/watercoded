import Meniscus
import SwiftUI

/// The small vessel shown next to a Current in lists.
public struct VesselGlyph: View {
    private let vessel: Vessel
    private let tint: Color

    public init(vessel: Vessel, tint: Color) {
        self.vessel = vessel
        self.tint = tint
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        WaterSurfaceView(vessel: vessel, role: .glyph, tint: tint)
            .clipShape(RoundedRectangle(cornerRadius: Radius.small - Spacing.xxSmall, style: .continuous))
            .padding(Spacing.xxSmall)
            .background(.primary.opacity(0.025), in: shape)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [.primary.opacity(0.22), .primary.opacity(0.08), .primary.opacity(0.16)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ), lineWidth: 0.75
                )
            }
            .frame(width: Metrics.glyphSize.width, height: Metrics.glyphSize.height)
            .accessibilityHidden(true)
    }
}

/// The vessel behind a Current's composer: water fills the message field from the bottom as the
/// context window fills. Controls and text are layered on top, so the water never distorts them.
public struct ComposerVessel: View {
    private let vessel: Vessel
    private let tint: Color
    private let cornerRadius: CGFloat

    public init(vessel: Vessel, tint: Color, cornerRadius: CGFloat) {
        self.vessel = vessel
        self.tint = tint
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        WaterSurfaceView(vessel: vessel, role: .panel, tint: tint)
            .clipShape(shape)
            .overlay { shape.strokeBorder(.primary.opacity(0.10), lineWidth: 0.75) }
    }
}
