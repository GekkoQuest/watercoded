import Foundation

/// One entry in a Current's conversation, in display order.
public struct TranscriptItem: Identifiable, Hashable, Codable, Sendable {
    public enum Content: Hashable, Codable, Sendable {
        case user(text: String)
        case userImages(count: Int)
        case assistant(text: String)
        case toolCall(ToolCallRecord)
        case notice(Notice)
        case thinking(ThinkingRecord)
        case plan(PlanRecord)
        case question(QuestionRecord)
    }

    public let id: UUID
    public let date: Date
    public var content: Content

    public init(id: UUID = UUID(), date: Date = .now, content: Content) {
        self.id = id
        self.date = date
        self.content = content
    }
}

/// A tool invocation and (once finished) its result.
public struct ToolCallRecord: Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case running
        case succeeded
        case failed
        case denied
    }

    /// Provider-assigned tool call identifier.
    public let callID: String
    public var name: String
    public var kind: ToolKind
    /// One-line human summary, e.g. the shell command or file path.
    public var summary: String
    /// The raw input, pretty-printed JSON.
    public var input: String
    public var output: String?
    public var status: Status
    /// The subagent (Task) call this call was made inside, if any.
    public var parentCallID: String?

    public init(
        callID: String,
        name: String,
        kind: ToolKind,
        summary: String,
        input: String,
        output: String? = nil,
        status: Status = .running,
        parentCallID: String? = nil
    ) {
        self.callID = callID
        self.name = name
        self.kind = kind
        self.summary = summary
        self.input = input
        self.output = output
        self.status = status
        self.parentCallID = parentCallID
    }
}

/// A system message shown inline in the transcript.
public struct Notice: Hashable, Codable, Sendable {
    public enum Level: String, Codable, Sendable {
        case info
        case warning
        case error
    }

    public var level: Level
    public var text: String

    public init(_ level: Level, _ text: String) {
        self.level = level
        self.text = text
    }
}

/// Model reasoning shown collapsed. Some models redact the text and report only its size.
public struct ThinkingRecord: Hashable, Codable, Sendable {
    public var text: String
    public var estimatedTokens: Int?

    public init(text: String, estimatedTokens: Int?) {
        self.text = text
        self.estimatedTokens = estimatedTokens
    }
}

/// A plan the agent proposed (e.g. at the end of Plan mode), awaiting Build or revision.
public struct PlanRecord: Hashable, Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case pending
        case approved
        case revised
    }

    public var requestID: String
    public var markdown: String
    public var status: Status
    public var feedback: String?

    public init(requestID: String, markdown: String, status: Status = .pending, feedback: String? = nil) {
        self.requestID = requestID
        self.markdown = markdown
        self.status = status
        self.feedback = feedback
    }
}

/// Multiple-choice questions the agent asked, and the user's answers.
public struct QuestionRecord: Hashable, Codable, Sendable {
    public struct Question: Hashable, Codable, Sendable, Identifiable {
        public struct Option: Hashable, Codable, Sendable, Identifiable {
            public var label: String
            public var detail: String?
            public var id: String {
                label
            }

            public init(label: String, detail: String? = nil) {
                self.label = label
                self.detail = detail
            }
        }

        public var text: String
        public var header: String?
        public var options: [Option]
        public var allowsMultiple: Bool
        public var id: String {
            text
        }

        public init(text: String, header: String? = nil, options: [Option], allowsMultiple: Bool = false) {
            self.text = text
            self.header = header
            self.options = options
            self.allowsMultiple = allowsMultiple
        }
    }

    public var requestID: String
    public var questions: [Question]
    /// Question text → chosen answer(s), joined with ", " for multi-select.
    public var answers: [String: String]?

    public init(requestID: String, questions: [Question], answers: [String: String]? = nil) {
        self.requestID = requestID
        self.questions = questions
        self.answers = answers
    }

    public var isAnswered: Bool {
        answers != nil
    }
}
