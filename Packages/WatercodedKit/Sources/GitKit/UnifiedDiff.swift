import Foundation

/// A parsed `git diff` (unified format).
public struct UnifiedDiff: Sendable, Hashable {
    public var files: [FileDiff]

    public init(files: [FileDiff]) {
        self.files = files
    }

    public var additions: Int {
        files.reduce(0) { $0 + $1.additions }
    }

    public var deletions: Int {
        files.reduce(0) { $0 + $1.deletions }
    }

    public var isEmpty: Bool {
        files.isEmpty
    }
}

public struct FileDiff: Sendable, Hashable, Identifiable {
    public enum Change: String, Sendable, Hashable {
        case added
        case deleted
        case modified
        case renamed
    }

    public var id: String {
        path
    }

    public var path: String
    public var oldPath: String?
    public var change: Change
    public var isBinary: Bool
    public var hunks: [Hunk]

    public var additions: Int {
        hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .addition } }
    }

    public var deletions: Int {
        hunks.reduce(0) { $0 + $1.lines.count { $0.kind == .deletion } }
    }
}

public struct Hunk: Sendable, Hashable {
    public var header: String
    public var lines: [DiffLine]
}

public struct DiffLine: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case context
        case addition
        case deletion
    }

    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?
    /// The line is the last in its file and has no newline after it (`\ No newline at end of file`).
    public var isMissingNewline: Bool

    public init(
        kind: Kind,
        text: String,
        oldNumber: Int? = nil,
        newNumber: Int? = nil,
        isMissingNewline: Bool = false
    ) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.isMissingNewline = isMissingNewline
    }
}

extension UnifiedDiff {
    /// Parses the output of `git diff` (including `--no-index` patches).
    public init(parsing text: String) {
        var parser = UnifiedDiffParser()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            parser.consume(String(line))
        }
        self.init(files: parser.finish())
    }
}

/// Line-by-line state machine behind ``UnifiedDiff/init(parsing:)``.
private struct UnifiedDiffParser {
    private var files: [FileDiff] = []
    private var file: FileDiff?
    private var hunk: Hunk?
    private var oldLine = 0
    private var newLine = 0

    mutating func consume(_ line: String) {
        if line.hasPrefix("diff --git ") {
            flushFile()
            file = FileDiff(
                path: Self.pathFromDiffHeader(line),
                oldPath: nil,
                change: .modified,
                isBinary: false,
                hunks: []
            )
        } else if line.hasPrefix("@@") {
            flushHunk()
            (oldLine, newLine) = Self.hunkStarts(line)
            hunk = Hunk(header: line, lines: [])
        } else if hunk != nil {
            consumeHunkLine(line)
        } else {
            consumeHeaderLine(line)
        }
    }

    mutating func finish() -> [FileDiff] {
        flushFile()
        return files
    }

    private mutating func consumeHeaderLine(_ line: String) {
        if line.hasPrefix("new file mode") || line == "--- /dev/null" {
            file?.change = .added
        } else if line.hasPrefix("deleted file mode") {
            file?.change = .deleted
        } else if line.hasPrefix("rename from ") {
            file?.oldPath = GitPatchPath.decode(String(line.dropFirst("rename from ".count)))
            file?.change = .renamed
        } else if line.hasPrefix("rename to ") {
            file?.path = GitPatchPath.decode(String(line.dropFirst("rename to ".count)))
        } else if line.hasPrefix("Binary files ") {
            file?.isBinary = true
        } else if line.hasPrefix("--- "), line != "--- /dev/null" {
            file?.path = Self
                .stripPrefix(GitPatchPath.decode(String(line.dropFirst(4)).components(separatedBy: "\t")[0]))
        } else if line.hasPrefix("+++ "), line != "+++ /dev/null" {
            file?.path = Self
                .stripPrefix(GitPatchPath.decode(String(line.dropFirst(4)).components(separatedBy: "\t")[0]))
        }
    }

    private mutating func consumeHunkLine(_ line: String) {
        let text = String(line.dropFirst())
        switch line.first {
        case "+":
            hunk?.lines.append(DiffLine(kind: .addition, text: text, newNumber: newLine))
            newLine += 1
        case "-":
            hunk?.lines.append(DiffLine(kind: .deletion, text: text, oldNumber: oldLine))
            oldLine += 1
        case " ":
            hunk?.lines.append(DiffLine(kind: .context, text: text, oldNumber: oldLine, newNumber: newLine))
            oldLine += 1
            newLine += 1
        case "\\":
            // "\ No newline at end of file" applies to the line before it; patches must say so too.
            if let last = hunk?.lines.indices.last {
                hunk?.lines[last].isMissingNewline = true
            }
        default:
            break // blank separators
        }
    }

    private mutating func flushHunk() {
        if let hunk {
            file?.hunks.append(hunk)
        }
        hunk = nil
    }

    private mutating func flushFile() {
        flushHunk()
        if let file {
            files.append(file)
        }
        file = nil
    }

    /// `diff --git a/x b/y` → `y`.
    private static func pathFromDiffHeader(_ line: String) -> String {
        stripPrefix(GitPatchPath.destination(in: String(line.dropFirst("diff --git ".count))))
    }

    private static func stripPrefix(_ path: String) -> String {
        if path.hasPrefix("a/") || path.hasPrefix("b/") {
            String(path.dropFirst(2))
        } else {
            path
        }
    }

    /// `@@ -12,5 +12,7 @@ …` → (12, 12).
    private static func hunkStarts(_ header: String) -> (Int, Int) {
        let ranges = header.split(separator: " ").dropFirst().prefix(2)
        func start(_ token: Substring?) -> Int {
            guard let token else { return 1 }
            return Int(token.dropFirst().split(separator: ",").first ?? "1") ?? 1
        }
        return (start(ranges.first), start(ranges.dropFirst().first))
    }
}
