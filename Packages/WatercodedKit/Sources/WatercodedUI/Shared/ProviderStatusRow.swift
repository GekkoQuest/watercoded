import AgentKit
import SwiftUI
import WatercodedDesign

/// A provider's name and availability, with install guidance inline when it's missing.
struct ProviderStatusRow: View {
    let descriptor: ProviderDescriptor
    let availability: ProviderAvailability?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            HStack {
                Label(descriptor.displayName, systemImage: descriptor.symbolName)
                Spacer()
                status
            }
            if case .notInstalled? = availability {
                guidance(descriptor.installHint)
            } else if case let .unavailable(reason)? = availability {
                guidance(reason)
            } else if case let .available(version?)? = availability,
                      let tested = descriptor.testedVersion, version != tested {
                guidance("Tested with version \(tested). Other versions may not work as expected.")
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch availability {
        case nil:
            ProgressView().controlSize(.small)
        case let .available(version)?:
            Label(version.map { "Ready · \($0)" } ?? "Ready", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .notInstalled?:
            Label("Not installed", systemImage: "arrow.down.circle").foregroundStyle(.orange)
        case .unavailable?:
            Label("Unavailable", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
        }
    }

    private func guidance(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
            Text(LocalizedStringKey(text))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = descriptor.installURL {
                Link("Install Guide", destination: url)
            }
        }
        .font(.callout)
    }
}
