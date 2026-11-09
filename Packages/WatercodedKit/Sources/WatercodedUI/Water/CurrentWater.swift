import AgentKit
import Meniscus
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// How a Current's state reads as water. The single place this mapping lives.
extension CurrentController {
    func waterState(at now: Date = .now) -> WaterState {
        WaterState(
            level: current.usage.contextFraction,
            // Murky means the last test or build failed, or the turn itself failed.
            isHealthy: current.status != .stalled && current.lastCheck?.passed != false,
            isStreaming: isTurnActive && !isAwaitingUser,
            hasSubagents: activity.activeSubagents > 0,
            isFrozen: current.status == .settled,
            isAwaitingApproval: isAwaitingUser,
            isChilled: isPromptCacheCold(at: now),
            heat: heat
        )
    }

    /// 0...1 haze: rises as a subscription window passes 80%, or as API spend in this Current
    /// approaches $20.
    var heat: Double {
        let usage = current.usage
        switch usage.billing {
        case .subscription?:
            let peak = usage.planUsage?.windows.map(\.utilization).max() ?? 0
            return min(1, max(0, (peak - 0.8) / 0.2))
        case .apiKey?:
            return min(1, max(0, (usage.costUSD - 5) / 15))
        case nil:
            return 0
        }
    }

    var waterTint: Color {
        .waterTint(hue: providerDescriptor?.tintHue ?? 0.58)
    }
}

extension ToolKind {
    var dropSize: DropSize {
        switch self {
        case .read, .search: .small
        case .web, .mcp, .other: .medium
        case .edit, .shell, .subagent: .large
        }
    }
}

extension WaterEngine {
    func vessel(for controller: CurrentController) -> Vessel {
        vessel(for: controller.id, initial: controller.waterState())
    }
}

/// Keeps one Current's vessel in sync with its state. Mounted once per Current (invisibly)
/// so impulses such as drops fire exactly once, however many views show the vessel.
struct CurrentWaterSync: View {
    let controller: CurrentController
    @Environment(WaterEngine.self) private var engine
    /// Ticks so time-based states (the prompt cache going cold) update without other changes.
    @State private var now = Date.now

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: controller.waterState(at: now), initial: true) { _, state in
                engine.vessel(for: controller).apply(state)
            }
            .onChange(of: controller.activity.toolCallCount) { old, new in
                guard new > old else { return }
                engine.vessel(for: controller).perform(.drop(controller.activity.lastToolKind?.dropSize ?? .medium))
            }
            .onChange(of: controller.activity.approvalsAnswered) { old, new in
                guard new > old else { return }
                let allowed = controller.activity.lastApprovalAllowed
                engine.vessel(for: controller).perform(allowed ? .approvalGranted : .approvalDenied)
            }
            .onChange(of: controller.activity.compactions) { old, new in
                guard new > old else { return }
                engine.vessel(for: controller).perform(.drained)
            }
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    now = .now
                }
            }
            .onDisappear { engine.removeVessel(for: controller.id) }
    }
}
