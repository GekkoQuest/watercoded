import SwiftUI
import WatercodedCore
import WatercodedDesign

/// The agent's task list as a compact progress line that expands into the full checklist.
struct TaskProgressHeader: View {
    let tasks: [TaskItem]
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Button {
                withAnimation(Motion.quick) { isExpanded.toggle() }
            } label: {
                HStack(spacing: Spacing.small) {
                    ProgressView(value: Double(tasks.completedCount), total: Double(tasks.count))
                        .frame(width: 80)
                    Text("\(tasks.completedCount) of \(tasks.count)")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    if let current = tasks.current {
                        Text(current.title).lineLimit(1)
                    } else if tasks.completedCount == tasks.count {
                        Text("All tasks done").foregroundStyle(.green)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .font(.callout)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    ForEach(tasks) { task in
                        Label {
                            Text(task.title)
                                .strikethrough(task.status == .completed)
                                .foregroundStyle(task.status == .completed ? .secondary : .primary)
                        } icon: {
                            Image(systemName: symbol(for: task.status))
                                .foregroundStyle(task.status == .completed ? Color.green : .secondary)
                        }
                        .font(.callout)
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.medium)
        .padding(.vertical, Spacing.small)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tasks.completedCount) of \(tasks.count) tasks done")
    }

    private func symbol(for status: TaskItem.Status) -> String {
        switch status {
        case .completed: "checkmark.circle.fill"
        case .inProgress: "circle.dotted"
        case .pending: "circle"
        }
    }
}
