import AgentKit
import Foundation
import WatercodedCore

extension CurrentController {
    func handleForm(_ form: FormRecord) {
        flushStreamingText()
        pendingForm = form
        append(.form(form))
        update { $0.status = .waiting }
        onAttention?(self, .questionAsked(form.message))
    }

    /// Sends the pending MCP form: values by field key. For link forms, the user opened the link.
    public func submitForm(_ values: [String: JSONValue], summary: [String: String]) async {
        await finishForm(.submitted, summary: summary, response: .accept(values))
    }

    /// Declines the pending MCP form; the tool that asked gets no input.
    public func declineForm() async {
        await finishForm(.declined, summary: nil, response: .decline)
    }

    private func finishForm(_ status: FormRecord.Status, summary: [String: String]?, response: FormResponse) async {
        guard let form = pendingForm else { return }
        pendingForm = nil
        if let index = transcript.lastIndex(where: {
            if case let .form(record) = $0.content {
                record.requestID == form.requestID
            } else {
                false
            }
        }), case var .form(record) = transcript[index].content {
            record.status = status
            record.summary = summary
            transcript[index].content = .form(record)
        }
        scheduleSave()
        await resolve(form.requestID, allowed: status == .submitted) {
            try await $0.respondToForm(form.requestID, with: response)
        }
    }
}
