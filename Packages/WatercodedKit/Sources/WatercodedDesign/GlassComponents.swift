import SwiftUI

/// A compact Liquid Glass capsule with an icon and text.
public struct GlassChip: View {
    private let title: String
    private let symbolName: String
    private let tint: Color?

    public init(_ title: String, systemImage: String, tint: Color? = nil) {
        self.title = title
        symbolName = systemImage
        self.tint = tint
    }

    public var body: some View {
        Label(title, systemImage: symbolName)
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, Spacing.medium)
            .padding(.vertical, Spacing.xSmall + 2)
            .glassEffect(
                tint.map { .regular.tint($0.opacity(0.35)) } ?? .regular,
                in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
            )
    }
}

/// A circular Liquid Glass button showing only an icon. Always provide a title for accessibility.
public struct GlassIconButton: View {
    private let title: String
    private let symbolName: String
    private let isProminent: Bool
    private let action: () -> Void

    public init(_ title: String, systemImage: String, isProminent: Bool = false, action: @escaping () -> Void) {
        self.title = title
        symbolName = systemImage
        self.isProminent = isProminent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 32, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isProminent ? Color.white : Color.primary)
        .glassEffect(
            isProminent ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
            in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous)
        )
        .help(title)
        .accessibilityLabel(title)
    }
}
