import Foundation

/// Files and messages shared by the relay host (``RelayHost``) and its client (``RelayedProcess``).
///
/// A relay owns one agent process. Everything the agent prints is appended to `output.log`,
/// together with `{"__relay": …}` records for stderr, input echoes and the exit status, so a
/// client that reattaches later can replay exactly what happened. Input arrives through the
/// `input.fifo` named pipe.
public enum RelayFiles {
    public static let log = "output.log"
    public static let input = "input.fifo"
    public static let pid = "relay.pid"
}

/// One line of a relay log.
public enum RelayRecord: Equatable, Sendable {
    /// A line the agent wrote to stdout.
    case output(String)
    /// A line sent to the agent's stdin (echoed so replays know what was answered).
    case input(String)
    /// A line the agent wrote to stderr.
    case error(String)
    /// The agent exited.
    case exited(Int32)

    static let marker = #"{"__relay":"#

    /// Parses a log line.
    public init(logLine line: String) {
        guard line.hasPrefix(Self.marker),
              let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let kind = object["__relay"] as? String
        else {
            self = .output(line)
            return
        }
        switch kind {
        case "stdin": self = .input(object["line"] as? String ?? "")
        case "stderr": self = .error(object["line"] as? String ?? "")
        case "exit": self = .exited(Int32(object["code"] as? Int ?? -1))
        default: self = .output(line)
        }
    }

    /// The log line for a meta record.
    static func metaLine(_ kind: String, _ fields: [String: Any]) -> String {
        var object = fields
        object["__relay"] = kind
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Control commands the client sends through the input pipe.
    static let terminateCommand = metaLine("terminate", [:])
    static let interruptCommand = metaLine("interrupt", [:])
}

/// Reads a relay log as records, with each record's end offset.
public enum RelayLog {
    public static func records(in directory: URL, upTo limit: Int64? = nil) -> [(record: RelayRecord, end: Int64)] {
        guard let data = try? Data(contentsOf: directory.appending(path: RelayFiles.log)) else { return [] }
        let bytes = limit.map { data.prefix(Int($0)) } ?? data[...]
        var result: [(RelayRecord, Int64)] = []
        var start = bytes.startIndex
        while let newline = bytes[start...].firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: bytes[start ..< newline], as: UTF8.self)
            result.append((RelayRecord(logLine: line), Int64(newline - bytes.startIndex + 1)))
            start = bytes.index(after: newline)
        }
        return result
    }

    /// Whether the relay in `directory` is still running.
    public static func isAlive(in directory: URL) -> Bool {
        guard let text = try? String(contentsOf: directory.appending(path: RelayFiles.pid), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return kill(pid, 0) == 0
    }
}
