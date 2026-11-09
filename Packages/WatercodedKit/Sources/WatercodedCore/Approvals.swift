import Foundation

/// A standing approval: tool calls that match are allowed without asking.
///
/// Watercoded applies these itself (per Pool) rather than writing provider settings files,
/// so rules work the same for every provider and never touch the user's repository.
public struct ApprovalRule: Hashable, Codable, Sendable, Identifiable {
    /// Tool name, e.g. `Bash`, `Edit`.
    public var toolName: String
    /// For shell tools: a command prefix ending in ` *` (e.g. `npm test *`) or an exact command.
    /// `nil` allows every call of the tool.
    public var pattern: String?

    public init(toolName: String, pattern: String? = nil) {
        self.toolName = toolName
        self.pattern = pattern
    }

    public var id: String {
        "\(toolName)(\(pattern ?? "*"))"
    }

    /// Human-readable form, e.g. `Bash: npm test *`.
    public var displayName: String {
        pattern.map { "\(toolName): \($0)" } ?? "Any \(toolName)"
    }

    /// Whether a call of `toolName` with `subject` (its command or path) is covered by this rule.
    public func matches(toolName: String, subject: String?) -> Bool {
        guard toolName == self.toolName else { return false }
        guard let pattern else { return true }
        guard let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        if pattern.hasSuffix(" *") || pattern.hasSuffix(":*") {
            let prefix = String(pattern.dropLast(2))
            return subject == prefix || subject.hasPrefix(prefix + " ")
        }
        return subject == pattern
    }

    /// Parses Claude Code's rule syntax: `Bash(npm test:*)`, `Bash(npm test *)`, `Edit`.
    public init?(claudeRule: String) {
        guard let open = claudeRule.firstIndex(of: "(") else {
            guard !claudeRule.isEmpty else { return nil }
            self.init(toolName: claudeRule)
            return
        }
        guard claudeRule.hasSuffix(")") else { return nil }
        let tool = String(claudeRule[..<open])
        let inner = String(claudeRule[claudeRule.index(after: open) ..< claudeRule.index(before: claudeRule.endIndex)])
        self.init(toolName: tool, pattern: inner.isEmpty ? nil : inner.replacingOccurrences(of: ":*", with: " *"))
    }

    /// A sensible rule for a shell command: the program plus, for multi-command tools like `npm` or
    /// `git`, its subcommand, then ` *` (`npm test --watch` → `npm test *`, `./run.sh x` → `./run.sh *`).
    public static func suggested(forCommand command: String) -> String {
        let words = command.split(separator: " ")
        guard let program = words.first else { return "*" }
        let multiCommand: Set = [
            "npm", "pnpm", "yarn", "bun", "swift", "cargo", "go", "make", "git", "xcodebuild", "python", "python3"
        ]
        if multiCommand.contains(String(program)), words.count > 1,
           let next = words.dropFirst().first, !next.hasPrefix("-"), !next.contains("/"), !next.contains("=") {
            return "\(program) \(next) *"
        }
        return "\(program) *"
    }
}

/// Image data attached to a user message.
public struct ImageAttachment: Hashable, Codable, Sendable, Identifiable {
    public var id = UUID()
    /// e.g. `image/png`.
    public var mediaType: String
    public var data: Data
    public var filename: String?

    public init(mediaType: String, data: Data, filename: String? = nil) {
        self.mediaType = mediaType
        self.data = data
        self.filename = filename
    }
}

/// A command the agent understands when sent as a message (e.g. `/compact`).
public struct SlashCommand: Hashable, Codable, Sendable, Identifiable {
    public var name: String
    public var summary: String
    public var argumentHint: String?

    public init(name: String, summary: String, argumentHint: String? = nil) {
        self.name = name
        self.summary = summary
        self.argumentHint = argumentHint
    }

    public var id: String {
        name
    }
}

/// What the agent loaded for this session: shown read-only so users see what the agent sees.
public struct AgentEnvironment: Hashable, Codable, Sendable {
    public struct Server: Hashable, Codable, Sendable, Identifiable {
        public var name: String
        public var status: String
        public var id: String {
            name
        }

        public init(name: String, status: String) {
            self.name = name
            self.status = status
        }
    }

    public var version: String?
    public var model: String?
    public var mcpServers: [Server]
    public var tools: [String]
    public var skills: [String]
    public var plugins: [String]
    /// Instruction files the agent read (e.g. CLAUDE.md), absolute paths.
    public var memoryFiles: [String]
    public var agents: [String]

    public init(
        version: String? = nil,
        model: String? = nil,
        mcpServers: [Server] = [],
        tools: [String] = [],
        skills: [String] = [],
        plugins: [String] = [],
        memoryFiles: [String] = [],
        agents: [String] = []
    ) {
        self.version = version
        self.model = model
        self.mcpServers = mcpServers
        self.tools = tools
        self.skills = skills
        self.plugins = plugins
        self.memoryFiles = memoryFiles
        self.agents = agents
    }
}

/// Where a background ("relayed") session lives, so the app can reattach after a relaunch.
public struct RelayHandle: Hashable, Codable, Sendable {
    /// Directory holding the relay's log, input pipe and pid file.
    public var directory: String
    /// Bytes of the log already processed.
    public var offset: Int64

    public init(directory: String, offset: Int64) {
        self.directory = directory
        self.offset = offset
    }

    public var url: URL {
        URL(filePath: directory, directoryHint: .isDirectory)
    }
}
