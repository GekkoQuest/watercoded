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
        Array(sequence(in: directory, upTo: limit))
    }

    /// Streams a bounded prefix without materializing the entire log or reading later output.
    public static func sequence(in directory: URL, upTo limit: Int64? = nil) -> RelayRecords {
        RelayRecords(url: directory.appending(path: RelayFiles.log), limit: limit)
    }

    /// Checks for unread bytes without decoding the log.
    public static func hasUnread(in directory: URL, after offset: Int64) -> Bool {
        let attributes = try? FileManager.default
            .attributesOfItem(atPath: directory.appending(path: RelayFiles.log).path)
        return ((attributes?[.size] as? NSNumber)?.int64Value ?? 0) > offset
    }

    /// Whether the relay in `directory` is still running.
    public static func isAlive(in directory: URL) -> Bool {
        guard let text = try? String(contentsOf: directory.appending(path: RelayFiles.pid), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return kill(pid, 0) == 0
    }
}

/// A single-pass sequence of complete relay records. Memory is bounded by a chunk and one line.
public struct RelayRecords: Sequence, Sendable {
    let url: URL
    let limit: Int64?

    public func makeIterator() -> Iterator {
        Iterator(url: url, limit: limit)
    }

    public final class Iterator: IteratorProtocol {
        private let reader: FileHandle?
        private let limit: Int64
        private var readBytes: Int64 = 0
        private var consumed: Int64 = 0
        private var buffer = Data()

        fileprivate init(url: URL, limit: Int64?) {
            reader = try? FileHandle(forReadingFrom: url)
            self.limit = limit ?? Int64.max
        }

        deinit { try? reader?.close() }

        public func next() -> (record: RelayRecord, end: Int64)? {
            while true {
                if let newline = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    let count = buffer.distance(from: buffer.startIndex, to: newline) + 1
                    buffer.removeSubrange(buffer.startIndex ... newline)
                    consumed += Int64(count)
                    return (RelayRecord(logLine: line), consumed)
                }
                guard readBytes < limit, let data = try? reader?.read(upToCount: Int(Swift.min(
                          65536,
                          limit - readBytes
                      ))),
                      !data.isEmpty else { return nil }
                readBytes += Int64(data.count)
                buffer.append(data)
            }
        }
    }
}
