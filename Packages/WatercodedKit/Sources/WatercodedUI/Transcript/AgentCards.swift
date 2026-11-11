import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Collapsed reasoning. Claude redacts the text of its thinking, so often only the size is shown.
struct ThinkingView: View {
    let record: ThinkingRecord
    @State private var isExpanded = false

    var body: some View {
        let hasText = !record.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            Button {
                withAnimation(Motion.quick) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Spacing.small) {
                    Image(systemName: "brain")
                    Text(title)
                    if hasText {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!hasText)

            if isExpanded, hasText {
                Text(record.text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, Spacing.large)
            }
        }
        .opacity(0.85)
    }

    private var title: String {
        guard let tokens = record.estimatedTokens, tokens > 0 else { return "Thought" }
        return "Thought (~\(tokens.formatted(.number.notation(.compactName))) tokens)"
    }
}

/// The plan an agent proposes at the end of Plan mode. Build lets it start; Keep Planning sends feedback.
struct PlanCard: View {
    let record: PlanRecord
    let controller: CurrentController
    @State private var feedback = ""
    @State private var isRevising = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            HStack {
                Label("Proposed Plan", systemImage: "list.bullet.clipboard").font(.headline)
                Spacer()
                statusBadge
            }
            MarkdownView(text: record.markdown)
            if let feedback = record.feedback {
                Label("You asked: \(feedback)", systemImage: "arrowshape.turn.up.backward")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if record.status == .pending, controller.pendingPlan?.requestID == record.requestID {
                actions
            }
        }
        .padding(Spacing.large)
        .glassEffect(.regular.tint(.accentColor.opacity(0.12)), in: RoundedRectangle(cornerRadius: Radius.large))
    }

    @ViewBuilder private var actions: some View {
        if isRevising {
            HStack(alignment: .bottom, spacing: Spacing.small) {
                TextField("What should change?", text: $feedback, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1 ... 4)
                    .onSubmit(sendFeedback)
                Button("Send", action: sendFeedback)
                    .keyboardShortcut(.defaultAction)
                Button("Cancel") { isRevising = false }
            }
        } else {
            HStack(spacing: Spacing.small) {
                Button("Build") { Task { await controller.approvePlan() } }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.return, modifiers: [.command, .shift])
                    .help("Approve the plan; the agent starts making changes (⇧⌘↩)")
                Button("Keep Planning…") { isRevising = true }
                    .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder private var statusBadge: some View {
        switch record.status {
        case .pending: EmptyView()
        case .approved: Label("Building", systemImage: "hammer").foregroundStyle(.green).font(.caption)
        case .revised: Label("Revising", systemImage: "arrow.uturn.backward").foregroundStyle(.secondary).font(.caption)
        }
    }

    private func sendFeedback() {
        let text = feedback
        isRevising = false
        Task { await controller.revisePlan(feedback: text) }
    }
}

/// Multiple-choice questions from the agent, answered with a click.
struct QuestionCard: View {
    let record: QuestionRecord
    let controller: CurrentController
    @State private var selections: [String: Set<String>] = [:]
    @State private var otherAnswers: [String: String] = [:]
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.large) {
            ForEach(record.questions) { question in
                VStack(alignment: .leading, spacing: Spacing.small) {
                    if let header = question.header {
                        Text(header.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text(question.text).font(.headline)
                    if let answer = record.answers?[question.text] {
                        Label {
                            Text(answer).foregroundStyle(.primary)
                        } icon: {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor)
                        }
                    } else if isPending {
                        options(for: question)
                    }
                }
            }
            if record.isCancelled {
                Label("Cancelled", systemImage: "xmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if isPending {
                HStack(spacing: Spacing.small) {
                    Button("Send", action: submit)
                        .buttonStyle(.glassProminent)
                        .disabled(!isComplete)
                    Button("Cancel") {
                        isSubmitting = true
                        Task {
                            await controller.cancelQuestion(record.requestID)
                            isSubmitting = false
                        }
                    }
                    .buttonStyle(.glass)
                    .help(record.isAsynchronous ? "Cancel question" : "Cancel question and stop the turn")
                }
            }
        }
        .padding(Spacing.large)
        .disabled(isSubmitting)
        .glassEffect(.regular.tint(.accentColor.opacity(0.06)), in: RoundedRectangle(cornerRadius: Radius.large))
    }

    private var isPending: Bool {
        !record.isAnswered && !record.isCancelled && controller.current.status != .settled
            && (controller.pendingQuestion?.requestID == record.requestID
                || controller.pendingAsyncQuestions.contains { $0.requestID == record.requestID })
    }

    /// A single single-choice question answers on click; anything else needs a Submit.
    private var needsSubmitButton: Bool {
        record.questions.count > 1 || record.questions.contains(where: \.allowsMultiple)
    }

    private var isComplete: Bool {
        record.questions.allSatisfy { answer(for: $0) != nil }
    }

    private func options(for question: QuestionRecord.Question) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xSmall) {
            ForEach(question.options) { option in
                let isSelected = selections[question.text]?.contains(option.label) == true
                Button {
                    choose(option.label, in: question)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Spacing.small) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" :
                            (question.allowsMultiple ? "square" : "circle"))
                            .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                            Text(option.label).fontWeight(.medium)
                            if let detail = option.detail {
                                Text(detail).font(.callout).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.xSmall)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
            TextField("Other…", text: Binding(
                get: { otherAnswers[question.text] ?? "" },
                set: { otherAnswers[question.text] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .onSubmit {
                if !needsSubmitButton {
                    submit()
                }
            }
        }
    }

    private func choose(_ label: String, in question: QuestionRecord.Question) {
        if question.allowsMultiple {
            var set = selections[question.text] ?? []
            if set.contains(label) {
                set.remove(label)
            } else {
                set.insert(label)
            }
            selections[question.text] = set
        } else {
            selections[question.text] = [label]
            otherAnswers[question.text] = nil
            if !needsSubmitButton {
                submit()
            }
        }
    }

    private func answer(for question: QuestionRecord.Question) -> String? {
        if let other = otherAnswers[question.text]?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
            return other
        }
        let chosen = question.options.map(\.label).filter { selections[question.text]?.contains($0) == true }
        return chosen.isEmpty ? nil : chosen.joined(separator: ", ")
    }

    private func submit() {
        var answers: [String: String] = [:]
        for question in record.questions {
            guard let answer = answer(for: question) else { return }
            answers[question.text] = answer
        }
        isSubmitting = true
        Task {
            await controller.answer(answers, requestID: record.requestID)
            isSubmitting = false
        }
    }
}
