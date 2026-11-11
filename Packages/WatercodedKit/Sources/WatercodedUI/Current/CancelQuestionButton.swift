import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// A compact dismissal control with a brief tooltip above the button.
struct CancelQuestionButton: View {
    let question: QuestionRecord
    let controller: CurrentController
    @Binding var isHovered: Bool
    @State private var isCancelling = false

    var body: some View {
        Button {
            isCancelling = true
            Task {
                await controller.cancelQuestion(question.requestID)
                isCancelling = false
            }
        } label: {
            Image(systemName: "xmark")
                .padding(Spacing.xSmall)
                .foregroundStyle(isHovered ? .primary : .secondary)
                .background(
                    Color.gray.opacity(isHovered ? 0.16 : 0),
                    in: RoundedRectangle(cornerRadius: Radius.small)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .onDisappear { isHovered = false }
        .accessibilityLabel(title)
        .disabled(isCancelling)
    }

    private var title: String {
        question.isAsynchronous ? "Cancel question" : "Cancel question and stop the turn"
    }
}

/// Rendered above the prompt's glass surface so the tooltip isn't clipped or refracted by it.
struct QuestionCancelTooltip: View {
    let question: QuestionRecord
    let isVisible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The overlay starts at the box's edge; account for its padding to sit near the ×.
        let tooltipInset = Spacing.small - Spacing.xxSmall
        Text(question.isAsynchronous ? "Cancel question" : "Cancel question and stop the turn")
            .font(.caption)
            .fixedSize()
            .padding(.horizontal, Spacing.small)
            .padding(.vertical, Spacing.xSmall)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.small))
            .visualEffect { content, geometry in
                content.offset(y: -geometry.size.height + tooltipInset)
            }
            .opacity(isVisible ? 1 : 0)
            .animation(reduceMotion ? nil : Motion.quick, value: isVisible)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
