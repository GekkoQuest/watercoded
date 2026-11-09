import Orchestrator
import SwiftUI
import WatercodedDesign

/// Shown after a vigorous window shake: press and hold to settle (interrupt) the agent.
struct SettlePrompt: View {
    let controller: CurrentController
    let dismiss: () -> Void

    @State private var progress: CGFloat = 0
    @State private var isHolding = false
    private let holdDuration = 0.8

    var body: some View {
        HStack(spacing: Spacing.medium) {
            ZStack {
                Circle().stroke(.secondary.opacity(0.3), lineWidth: 3)
                Circle().trim(from: 0, to: progress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "hand.raised.fill").font(.system(size: 12))
            }
            .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Text("Stop “\(controller.current.title)”?").font(.headline).lineLimit(1)
                Text(isHolding ? "Keep holding…" : "Press and hold to interrupt the agent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Dismiss", systemImage: "xmark", action: dismiss)
                .labelStyle(.iconOnly)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.large)
        .padding(.vertical, Spacing.medium)
        .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Radius.large, style: .continuous))
        .onLongPressGesture(minimumDuration: holdDuration) {
            Task { await controller.interrupt() }
            dismiss()
        } onPressingChanged: { pressing in
            isHolding = pressing
            withAnimation(pressing ? .linear(duration: holdDuration) : Motion.quick) { progress = pressing ? 1 : 0 }
        }
        .task {
            try? await Task.sleep(for: .seconds(5))
            if !isHolding {
                withAnimation(Motion.standard) { dismiss() }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(named: "Stop") {
            Task { await controller.interrupt() }
            dismiss()
        }
    }
}
