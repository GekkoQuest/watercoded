import WatercodedCore

extension CodexWireTranslator {
    /// codex-cli 0.167.0 delivers request_user_input_async as an agentMessage with structured
    /// questions, not as item/tool/requestUserInput. Its accepted tool result is not a user answer.
    static func asyncQuestions(_ item: JSONValue) -> [QuestionRecord.Question] {
        (item["questions"]?.array ?? []).compactMap { question in
            guard let title = question["title"]?.string, !title.isEmpty else { return nil }
            let options = (question["options"]?.array ?? []).compactMap { option in
                option.string.map { QuestionRecord.Question.Option(label: $0) }
            }
            return QuestionRecord.Question(text: title, options: options)
        }
    }
}
