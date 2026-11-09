import Foundation
import WatercodedCore

/// Rebuilds the agent's task list from its tool calls.
///
/// Claude Code has two flavors: `TodoWrite` (the whole list each time) and the newer
/// `TaskCreate` / `TaskUpdate` (incremental; the new task's number arrives in the result).
struct ClaudeTaskTracker {
    private(set) var items: [TaskItem] = []
    private var pendingCreates: [String: String] = [:]
    private var pendingUpdates: [String: JSONValue] = [:]

    /// Returns `true` when ``items`` changed.
    mutating func toolStarted(callID: String, name: String, input: JSONValue) -> Bool {
        switch name {
        case "TodoWrite":
            guard let todos = input["todos"]?.array else { return false }
            items = todos.enumerated().compactMap { index, todo in
                guard let title = todo["content"]?.string ?? todo["subject"]?.string else { return nil }
                return TaskItem(id: "\(index + 1)", title: title, status: Self.status(todo["status"]?.string))
            }
            return true
        case "TaskCreate":
            pendingCreates[callID] = input["subject"]?.string ?? input["description"]?.string ?? "Task"
            return false
        case "TaskUpdate":
            pendingUpdates[callID] = input
            return false
        default:
            return false
        }
    }

    /// Returns `true` when ``items`` changed.
    mutating func toolFinished(callID: String, output: String, isError: Bool) -> Bool {
        if let title = pendingCreates.removeValue(forKey: callID) {
            guard !isError else { return false }
            items.append(TaskItem(id: Self.taskNumber(in: output) ?? callID, title: title))
            return true
        }
        if let input = pendingUpdates.removeValue(forKey: callID) {
            guard !isError, let id = input["taskId"]?.string ?? input["taskId"]?.int.map(String.init),
                  let index = items.firstIndex(where: { $0.id == id }) else { return false }
            if input["status"]?.string == "deleted" {
                items.remove(at: index)
                return true
            }
            if let status = input["status"]?.string {
                items[index].status = Self.status(status)
            }
            if let subject = input["subject"]?.string {
                items[index].title = subject
            }
            return true
        }
        return false
    }

    static func status(_ value: String?) -> TaskItem.Status {
        switch value {
        case "completed": .completed
        case "in_progress": .inProgress
        default: .pending
        }
    }

    /// `Task #12 created successfully: …` → `"12"`.
    static func taskNumber(in output: String) -> String? {
        guard let hash = output.firstIndex(of: "#") else { return nil }
        let digits = output[output.index(after: hash)...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : String(digits)
    }
}
