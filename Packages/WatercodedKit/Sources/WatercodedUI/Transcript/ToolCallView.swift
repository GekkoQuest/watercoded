import SwiftUI
import WatercodedCore
import WatercodedDesign

/// A collapsible card for one tool call: summary line, then input and output on demand.
struct ToolCallView: View {
    let record: ToolCallRecord
    /// Calls a subagent made inside this one (only for subagent/Task calls).
    var children: [ToolCallRecord] = []
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Button {
                withAnimation(Motion.quick) { isExpanded.toggle() }
            } label: {
                header
            }
            .buttonStyle(.plain)

            if isExpanded {
                if !children.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xSmall) {
                        ForEach(children, id: \.callID) { SubagentStepRow(record: $0) }
                    }
                    .padding(.leading, Spacing.large)
                }
                VStack(alignment: .leading, spacing: Spacing.medium) {
                    if record.kind == .shell {
                        ShellToolInputView(input: record.input)
                    } else if (try? JSONValue(parsing: record.input)) != .object([:]) {
                        ToolCodeBlock(title: "Input", text: record.input)
                    }
                    if let output = record.output, !output.isEmpty {
                        ToolCodeBlock(title: "Output", text: output)
                    }
                }
                .padding(.top, Spacing.xSmall)
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: record.kind.symbolName)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(record.name).fontWeight(.semibold)
            Text(record.summary)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.small)
            if !children.isEmpty {
                Text("\(children.count) \(children.count == 1 ? "step" : "steps")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            statusIcon
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
        }
        .contentShape(.rect)
    }

    private var statusIcon: some View {
        ToolStatusIcon(status: record.status)
    }
}

private struct ToolStatusIcon: View {
    let status: ToolCallRecord.Status

    var body: some View {
        switch status {
        case .running: ProgressView().controlSize(.mini)
        case .succeeded: Image(systemName: "checkmark").foregroundStyle(.green)
        case .failed: Image(systemName: "xmark").foregroundStyle(.red)
        case .denied: Image(systemName: "hand.raised.slash").foregroundStyle(.orange)
        }
    }
}

/// One line per step a subagent took.
private struct SubagentStepRow: View {
    let record: ToolCallRecord

    var body: some View {
        HStack(spacing: Spacing.small) {
            Image(systemName: record.kind.symbolName).foregroundStyle(.secondary).frame(width: 14)
            Text(record.name).font(.callout.weight(.medium))
            Text(record.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Spacing.small)
            ToolStatusIcon(status: record.status)
        }
    }
}
