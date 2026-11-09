import AgentKit
import Foundation
import ProcessKit
import Testing
import WatercodedCore
@testable import ClaudeCodeProvider

@Suite("Claude question round trip")
struct ClaudeQuestionTests {
    @Test func `single multi and custom answers return through the session protocol`() async throws {
        // A deterministic stdio peer exercises the real ClaudeCodeSession without spending tokens.
        // It asks a batch of questions and echoes the actual updatedInput received from the app.
        let script = #"""
        import json, signal, sys
        signal.alarm(10)
        def emit(value):
            print(json.dumps(value), flush=True)
        for line in sys.stdin:
            value = json.loads(line)
            if value.get('type') == 'user':
                questions = [
                    {'question':'Pick a color','header':'Color','multiSelect':False,
                     'options':[{'label':'Red','description':'Warm'},{'label':'Blue','description':'Cool'}]},
                    {'question':'Pick features','header':'Features','multiSelect':True,
                     'options':[{'label':'Search'},{'label':'Export'}]},
                    {'question':'Name the release','header':'Name','multiSelect':False,
                     'options':[{'label':'Alpha'},{'label':'Beta'}]}
                ]
                emit({'type':'control_request','request_id':'question-batch',
                      'request':{'subtype':'can_use_tool','tool_name':'AskUserQuestion',
                                 'input':{'questions':questions}}})
            elif value.get('type') == 'control_response':
                updated = value['response']['response']['updatedInput']
                emit({'type':'assistant','message':{'id':'echo','content':[
                    {'type':'text','text':json.dumps(updated)}]}})
                emit({'type':'result','subtype':'success','result':'Answers received','is_error':False})
                break
        """#
        let session = try await ClaudeCodeSession.launch(
            ProcessSpec(
                executable: URL(filePath: "/usr/bin/python3"), arguments: ["-u", "-c", script],
                workingDirectory: FileManager.default.temporaryDirectory, environment: [:]
            ), relay: nil, relayDirectory: nil
        )
        try await session.send(UserMessage(text: "Ask the questions"))
        let answers = ["Pick a color": "Blue", "Pick features": "Search, Export", "Name the release": "My own name"]
        var echoed: JSONValue?
        var sawQuestion = false
        for await event in session.events {
            switch event {
            case let .questionAsked(id, questions):
                sawQuestion = true
                #expect(id == "question-batch")
                #expect(questions.map(\.allowsMultiple) == [false, true, false])
                #expect(questions.first?.options.first?.detail == "Warm")
                try await session.answer(id, with: answers)
            case let .messageCompleted(_, text): echoed = try JSONValue(parsing: text)
            default: break
            }
            if case .turnFinished = event {
                break
            }
        }
        await session.terminate()
        #expect(sawQuestion)
        #expect(echoed?["answers"] == .object(answers.mapValues(JSONValue.string)))
        #expect(echoed?["questions"]?.array?.count == 3)
        #expect(echoed?["questions"]?[1]?["multiSelect"] == true)
    }
}
