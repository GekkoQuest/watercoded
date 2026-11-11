import AgentKit
import Foundation
import WatercodedCore

extension CurrentController {
    /// Dismisses a question permanently. Blocking questions also interrupt the waiting turn.
    public func cancelQuestion(_ requestID: String) async {
        guard let question = pendingQuestions.first(where: { $0.requestID == requestID }) else { return }
        if !question.isAsynchronous {
            do {
                try await session?.interrupt()
            } catch {
                append(.notice(Notice(.error, error.localizedDescription)))
                return
            }
            if pendingQuestion?.requestID == requestID {
                pendingQuestion = nil
            }
            if !isAwaitingUser, current.status == .waiting {
                update { $0.status = isTurnActive ? .flowing : .ashore }
            }
        }
        pendingAsyncQuestions.removeAll { $0.requestID == requestID }
        if let index = transcript.lastIndex(where: {
            if case let .question(record) = $0.content {
                return record.requestID == requestID
            }
            return false
        }), case var .question(record) = transcript[index].content {
            record.isCancelled = true
            transcript[index].content = .question(record)
        }
        scheduleSave()
    }

    /// Answers the pending question (question text → chosen label or labels).
    public func answer(_ answers: [String: String], requestID: String? = nil) async {
        guard let question = pendingQuestions.first(where: { requestID == nil || $0.requestID == requestID }),
              current.status != .settled else { return }
        if question.isAsynchronous {
            let message = question.questions.compactMap { item in
                answers[item.text].map { "\(item.text)\n\($0)" }
            }.joined(separator: "\n\n")
            guard !message.isEmpty else { return }
            // Async questions have no pending RPC to resolve. Steer the active turn, or start/resume
            // a turn if it already ended, through the provider's normal message path.
            guard await sendMessage(message) else { return }
            pendingAsyncQuestions.removeAll { $0.requestID == question.requestID }
        } else {
            pendingQuestion = nil
        }
        if let index = transcript.lastIndex(where: {
            if case let .question(record) = $0.content {
                record.requestID == question.requestID
            } else {
                false
            }
        }), case var .question(record) = transcript[index].content {
            record.answers = answers
            transcript[index].content = .question(record)
        }
        if !question.isAsynchronous {
            await resolve(question.requestID, allowed: true) {
                try await $0.answer(question.requestID, with: answers)
            }
        }
        scheduleSave()
    }

    func handleQuestionEvent(_ event: AgentEvent) {
        switch event {
        case let .questionAsked(id, questions): handleQuestion(requestID: id, questions: questions)
        case let .asyncQuestionAsked(id, questions): handleAsyncQuestion(requestID: id, questions: questions)
        default: break
        }
    }

    func handleQuestion(requestID: String, questions: [QuestionRecord.Question]) {
        flushStreamingText()
        let record = QuestionRecord(requestID: requestID, questions: questions)
        pendingQuestion = record
        append(.question(record))
        update { $0.status = .waiting }
        onAttention?(self, .questionAsked(questions.first?.text ?? "The agent has a question."))
    }

    func handleAsyncQuestion(requestID: String, questions: [QuestionRecord.Question]) {
        // Relay replay can deliver an existing question again. Keep the stored answer, and avoid
        // replacing other pending questions when the agent asks more than once.
        guard !transcript.contains(where: {
            if case let .question(record) = $0.content {
                return record.requestID == requestID
            }
            return false
        }) else { return }
        let record = QuestionRecord(requestID: requestID, questions: questions, isAsynchronous: true)
        pendingAsyncQuestions.append(record)
        append(.question(record))
        onAttention?(self, .questionAsked(questions.first?.text ?? "The agent has a question."))
        scheduleSave()
    }
}
