import SwiftUI

/// Renders a ``Vessel``'s water over a plain interior backdrop.
///
/// The water refracts whatever is drawn beneath it, so never put text *inside* this view.
/// Text layered on top of it (as in the composer) stays sharp.
public struct WaterSurfaceView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let vessel: Vessel
    private let role: VesselRole
    private let tint: Color

    public init(vessel: Vessel, role: VesselRole, tint: Color) {
        self.vessel = vessel
        self.role = role
        self.tint = tint
    }

    public var body: some View {
        VesselInterior()
            .modifier(WaterEffect(
                frame: vessel.frame(for: role), tint: tint,
                compact: role == .glyph, reduceTransparency: reduceTransparency, reduceMotion: reduceMotion
            ))
            .onGeometryChange(for: CGSize.self) { $0.size } action: { vessel.resize(role, to: $0) }
    }
}

private struct WaterEffect: ViewModifier {
    let frame: RenderFrame
    let tint: Color
    let compact: Bool
    let reduceTransparency: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content.layerEffect(
            WaterShaders.library.water(
                .boundingRect,
                .float(reduceMotion ? 0 : frame.time),
                .float(frame.level),
                .floatArray(frame.heights),
                .floatArray(frame.particles),
                .float4(frame.hang.x, frame.hang.y, frame.hang.z, frame.hang.w),
                .float(frame.clarity),
                .float(frame.frost),
                .color(tint),
                .float(frame.heat),
                .float(compact ? 1 : 0),
                .float(reduceTransparency ? 1 : 0)
            ),
            maxSampleOffset: CGSize(width: 28, height: 28)
        )
    }
}

enum WaterShaders {
    /// `Water.metal` is compiled into this module's resource bundle by Xcode.
    static let library = ShaderLibrary.bundle(.module)
}

private struct VesselInterior: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        LinearGradient(
            colors: dark ? [Color(white: 0.12), Color(white: 0.14)] : [Color(white: 0.99), Color(white: 0.96)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}
