import Orchestrator
import SwiftUI
import WatercodedDesign

/// A quiet line above the composer: how long the turn has run, output tokens and generation speed,
/// plus the session's total. Ticks every second while the agent works.
struct TurnStatsBar: View {
    let controller: CurrentController

    var body: some View {
        if let stats = controller.turnStats {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                line(stats, now: context.date)
            }
        } else if let total = controller.current.outputTokens, total > 0 {
            line(nil, now: .now)
        }
    }

    private func line(_ stats: TurnStats?, now: Date) -> some View {
        HStack(spacing: Spacing.small) {
            if let stats {
                Text(stats.isActive ? "Working" : "Last turn")
                item(Self.duration((stats.endedAt ?? now).timeIntervalSince(stats.startedAt)), icon: "clock")
                if stats.outputTokens > 0 {
                    item("\(Self.compact(stats.outputTokens)) tokens", icon: "text.word.spacing")
                }
                if let speed = stats.tokensPerSecond {
                    item("\(Int(speed.rounded())) tok/s", icon: "gauge.with.dots.needle.67percent")
                }
            }
            Spacer(minLength: 0)
            if let total = controller.current.outputTokens, total > 0 {
                Text("\(Self.compact(total)) tokens this session")
                    .help("Output tokens generated in this session, thinking included")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .padding(.horizontal, Spacing.xSmall)
        .accessibilityElement(children: .combine)
    }

    private func item(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .labelStyle(.titleAndIcon)
            .imageScale(.small)
    }

    static func compact(_ tokens: Int) -> String {
        tokens < 1000 ? "\(tokens)" : tokens
            .formatted(.number.notation(.compactName).precision(.fractionLength(0 ... 1)))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total)s" : "\(total / 60)m \(String(format: "%02d", total % 60))s"
    }
}
