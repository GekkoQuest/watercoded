import AgentKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Toolbar control showing how full the context window is; details (tokens, estimated cost) in a popover.
struct UsageButton: View {
    let controller: CurrentController
    @State private var isShowingDetails = false

    var body: some View {
        let usage = controller.current.usage
        Button {
            isShowingDetails.toggle()
        } label: {
            Label {
                Text("\(Int((usage.contextFraction * 100).rounded()))% context")
                    .monospacedDigit()
            } icon: {
                Gauge(value: usage.contextFraction) { EmptyView() }
                    .gaugeStyle(.accessoryCircularCapacity)
                    .scaleEffect(0.45)
                    .frame(width: 18, height: 18)
            }
            .labelStyle(.titleAndIcon)
        }
        .help("How much of the model's context window this session is using")
        .popover(isPresented: $isShowingDetails, arrowEdge: .bottom) {
            UsageDetails(controller: controller)
        }
    }
}

private struct UsageDetails: View {
    let controller: CurrentController

    var body: some View {
        let usage = controller.current.usage
        VStack(alignment: .leading, spacing: Spacing.medium) {
            row("Context") {
                Text("\(compact(usage.contextTokens)) of \(usage.contextWindow.map(compact) ?? "unknown") tokens")
            }
            if controller.current.lastTurnEndedAt != nil {
                row("Cache") {
                    VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                        if controller.isPromptCacheCold() {
                            Label("Expired", systemImage: "snowflake").foregroundStyle(.cyan)
                            caption(
                                "The next message re-reads the whole context: slower, and it uses more of your limits."
                            )
                        } else {
                            Label("Warm", systemImage: "flame").foregroundStyle(.orange)
                            if let ended = controller.current.lastTurnEndedAt, let ttl = usage.cacheTTL {
                                let expiry = ended.addingTimeInterval(ttl)
                                caption("Expires \(expiry.formatted(.relative(presentation: .named))).")
                            }
                        }
                    }
                }
            }

            switch usage.billing {
            case .subscription?:
                subscription(usage.planUsage)
            case .apiKey?:
                if controller.capabilities.contains(.costReporting) {
                    row("Cost") {
                        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                            Text(usage.costUSD, format: .currency(code: "USD").precision(.fractionLength(2)))
                                .monospacedDigit()
                            caption("Billed to your API key.")
                        }
                    }
                }
            case nil:
                if controller.capabilities.contains(.costReporting), usage.costUSD > 0 {
                    row("Estimated cost") {
                        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                            Text(usage.costUSD, format: .currency(code: "USD").precision(.fractionLength(2)))
                                .monospacedDigit()
                            caption("At API list prices. If you use a subscription plan, you aren't billed per token.")
                        }
                    }
                }
            }

            if let provider = controller.providerDescriptor {
                row("Agent") {
                    Text([provider.displayName, controller.current.model].compactMap(\.self).joined(separator: " · "))
                }
            }
        }
        .padding(Spacing.large)
        .frame(width: 320, alignment: .leading)
    }

    private func subscription(_ plan: PlanUsage?) -> some View {
        row("Plan") {
            VStack(alignment: .leading, spacing: Spacing.small) {
                Text("Your subscription. No per-token charges.")
                if let plan {
                    ForEach(plan.windows) { window in
                        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                            HStack {
                                Text(window.title)
                                Spacer()
                                Text(window.utilization, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                            }
                            ProgressView(value: min(1, max(0, window.utilization)))
                                .tint(window.utilization > 0.8 ? .orange : .accentColor)
                            if let reset = window.resetsAt {
                                caption("Resets \(reset.formatted(.relative(presentation: .named)))")
                            }
                        }
                    }
                } else {
                    caption("Plan limits appear after the agent's next reply.")
                }
            }
        }
    }

    private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.medium) {
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func compact(_ value: Int) -> String {
        value.formatted(.number.notation(.compactName))
    }
}
