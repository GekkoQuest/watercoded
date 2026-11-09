import Foundation
import WatercodedCore

extension CodexWireTranslator {
    /// `/bin/zsh -lc 'npm test'` → `npm test`. Codex wraps commands in a login shell; the wrapped
    /// script is one shell word, so it's unquoted with POSIX rules. Anything else is shown as is.
    static func unwrapShell(_ command: String) -> String {
        for prefix in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c ", "sh -c "]
            where command.hasPrefix(prefix) {
            return shellWord(String(command.dropFirst(prefix.count))) ?? command
        }
        return command
    }

    /// The value of a single shell word (`'a'"b"\c` → `abc`), or `nil` if it isn't exactly one word.
    static func shellWord(_ text: String) -> String? {
        var result = ""
        var characters = text[...]
        while let character = characters.popFirst() {
            switch character {
            case "'":
                guard let end = characters.firstIndex(of: "'") else { return nil }
                result += characters[..<end]
                characters = characters[characters.index(after: end)...]
            case "\"":
                var closed = false
                while let inner = characters.popFirst() {
                    if inner == "\"" {
                        closed = true
                        break
                    }
                    if inner == "\\", let next = characters.first, "\"\\$`".contains(next) {
                        result.append(characters.removeFirst())
                    } else {
                        result.append(inner)
                    }
                }
                guard closed else { return nil }
            case "\\":
                guard let next = characters.popFirst() else { return nil }
                result.append(next)
            case " ", "\t", "\n":
                return nil // more than one word
            default:
                result.append(character)
            }
        }
        return result
    }

    static func tasks(from plan: JSONValue?) -> [TaskItem] {
        (plan?.array ?? []).enumerated().compactMap { index, step in
            guard let title = step["step"]?.string else { return nil }
            let status: TaskItem.Status = switch step["status"]?.string {
            case "completed": .completed
            case "inProgress": .inProgress
            default: .pending
            }
            return TaskItem(id: "plan-\(index)", title: title, status: status)
        }
    }

    static func windowTitle(minutes: Int?) -> String {
        switch minutes {
        case 300?: "5-hour limit"
        case 10080?: "Weekly limit"
        case let minutes? where minutes % 1440 == 0: "\(minutes / 1440)-day limit"
        case let minutes? where minutes % 60 == 0: "\(minutes / 60)-hour limit"
        default: "Usage limit"
        }
    }

    static func describe(_ paths: [String]) -> String {
        switch paths.count {
        case 0: "Edit files"
        case 1: (paths[0] as NSString).lastPathComponent
        default: "\((paths[0] as NSString).lastPathComponent) and \(paths.count - 1) more"
        }
    }
}
