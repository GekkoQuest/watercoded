import Foundation
import Testing
import WatercodedCore
@testable import Delegation

@Suite("Delegate MCP server")
struct DelegateMCPServerTests {
    private func mailbox() -> DelegationMailbox {
        DelegationMailbox(root: FileManager.default.temporaryDirectory
            .appending(path: "delegation-\(UUID().uuidString)"))
    }

    @Test func `it introduces itself and offers the app's agents`() throws {
        let box = mailbox()
        let initialize = try #require(DelegateMCPServer.handle(
            ["jsonrpc": "2.0", "id": 1, "method": "initialize", "params": ["protocolVersion": "2025-06-18"]],
            parentID: "p", agents: ["claude-code", "codex"], mailbox: box
        ))
        #expect(initialize["result"]?["serverInfo"]?["name"] == "watercoded")
        let list = try #require(DelegateMCPServer.handle(
            ["jsonrpc": "2.0", "id": 2, "method": "tools/list"], parentID: "p", agents: ["claude-code", "codex"],
            mailbox: box
        ))
        let tool = try #require(list["result"]?["tools"]?[0])
        #expect(tool["name"] == "delegate")
        #expect(tool["inputSchema"]?["properties"]?["agent"]?["enum"] == ["claude-code", "codex"])
        #expect(DelegateMCPServer.handle(
            ["jsonrpc": "2.0", "method": "notifications/initialized"],
            parentID: "p",
            agents: [],
            mailbox: box
        ) == nil)
    }

    @Test func `a call waits for the app's answer`() throws {
        let box = mailbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        // Play the app: answer the first request that arrives.
        let app = Thread {
            for _ in 0 ..< 100 {
                if let request = box.claimRequests().first {
                    #expect(request.agent == "codex")
                    #expect(request.parentID == "parent-1")
                    try? box.respond(DelegationResponse(id: request.id, text: "PINEAPPLE"))
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        app.start()
        let reply = try #require(DelegateMCPServer.handle(
            [
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/call",
                "params": ["name": "delegate", "arguments": ["agent": "codex", "task": "Say PINEAPPLE"]]
            ],
            parentID: "parent-1", agents: ["codex"], mailbox: box
        ))
        #expect(reply["result"]?["content"]?[0]?["text"] == "PINEAPPLE")
        #expect(reply["result"]?["isError"] == false)
    }

    @Test func `requests are claimed exactly once`() throws {
        let box = mailbox()
        defer { try? FileManager.default.removeItem(at: box.root) }
        try box.post(DelegationRequest(parentID: "p", agent: "codex", model: nil, effort: nil, task: "t"))
        #expect(box.claimRequests().count == 1)
        #expect(box.claimRequests().isEmpty)
    }
}
