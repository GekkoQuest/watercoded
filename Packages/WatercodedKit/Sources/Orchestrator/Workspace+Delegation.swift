import AgentKit
import Delegation
import Foundation
import WatercodedCore

/// How a delegated session's turn ended, returned to the agent that delegated it.
enum DelegationOutcome: Sendable {
    case answered(String)
    case failed(String)
}

/// Agents handing work to other agents: any provider to any provider (Claude Code → Codex, Codex → Claude Code,
/// or the same provider with another model). The parent's agent calls Watercoded's `delegate` MCP tool; Watercoded
/// starts a child Current in the parent's folder, shows it under the parent, and returns the child's final answer.
extension Workspace {
    /// How deep delegation may nest (a child may delegate, its child may too, and so on).
    static let maxDelegationDepth = 3

    /// The `delegate` server for a Current's agent, unless delegation is off or nesting is too deep.
    func mcpServers(for controller: CurrentController) -> [MCPServer] {
        guard let executable = delegationExecutable,
              depth(of: controller.current) < Self.maxDelegationDepth else { return [] }
        let agents = registry.descriptors.filter { !$0.isDemo }.map(\.id.rawValue)
        return [MCPServer(
            name: DelegateMCPServer.serverName,
            command: executable.path,
            arguments: [
                "--delegate-mcp", controller.id.rawValue.uuidString,
                "--agents", agents.joined(separator: ","),
                "--mailbox", delegationMailbox.root.path
            ],
            isTrusted: true, // the delegate call itself; the child's own actions still ask
            toolTimeout: DelegateMCPServer.timeout
        )]
    }

    /// The Currents a Current delegated to, oldest first.
    public func children(of id: CurrentID) -> [CurrentController] {
        currents.filter { $0.current.parentID == id }.sorted { $0.current.createdAt < $1.current.createdAt }
    }

    func depth(of current: Current) -> Int {
        var depth = 0
        var parent = current.parentID
        while let id = parent, depth <= Self.maxDelegationDepth {
            depth += 1
            parent = controller(id)?.current.parentID
        }
        return depth
    }

    // MARK: Requests

    func startWatchingDelegations() {
        delegationWatch?.cancel()
        delegationWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for request in delegationMailbox.claimRequests() {
                    Task { await self.handle(request) }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func handle(_ request: DelegationRequest) async {
        let outcome: DelegationOutcome
        do {
            let child = try await startDelegation(request)
            outcome = await withCheckedContinuation { continuation in
                delegationWaiters[child.id] = continuation
                Task { await child.send(request.task) }
            }
        } catch {
            outcome = .failed(error.localizedDescription)
        }
        let response = switch outcome {
        case let .answered(text): DelegationResponse(id: request.id, text: text)
        case let .failed(message): DelegationResponse(id: request.id, error: message)
        }
        try? delegationMailbox.respond(response)
    }

    /// Creates the child Current: the chosen agent and model, in the parent's folder and permission mode.
    func startDelegation(_ request: DelegationRequest) async throws -> CurrentController {
        guard let uuid = UUID(uuidString: request.parentID), let parent = controller(CurrentID(uuid)) else {
            throw DelegationError.parentGone
        }
        let providerID = Self.providerID(for: request.agent)
        // Real agents delegate to real agents; the demo may delegate to the demo.
        guard let provider = registry.provider(for: providerID),
              !provider.descriptor.isDemo || parent.providerDescriptor?.isDemo == true else {
            throw DelegationError.unknownAgent(
                request.agent,
                available: registry.descriptors.filter { !$0.isDemo }
                    .map(\.id.rawValue)
            )
        }
        guard case .available = await provider.availability() else {
            throw DelegationError.unavailable(provider.descriptor.displayName)
        }
        var child = Current(
            poolID: parent.current.poolID,
            title: NewCurrentRequest.title(fromPrompt: request.task),
            providerID: providerID,
            model: request.model.flatMap { $0.isEmpty ? nil : $0 },
            permissionMode: parent.current.permissionMode,
            channel: parent.current.channel // same folder: the parent sees the child's changes
        )
        child.parentID = parent.id
        child.effort = request.effort.flatMap { $0.isEmpty ? nil : $0 }
        child.titleSource = .prompt
        try await repository.saveCurrent(child)
        return adopt(child, transcript: [])
    }

    /// A delegated Current's turn ended: answer its parent's tool call.
    func delegatedTurnEnded(_ controller: CurrentController, _ event: AttentionEvent) {
        guard case let .turnFinished(outcome) = event,
              let waiter = delegationWaiters.removeValue(forKey: controller.id) else { return }
        waiter.resume(returning: Self.result(of: controller, outcome))
    }

    /// Answers a parent still waiting on a child that's going away (deleted or archived).
    func abandonDelegation(_ id: CurrentID) {
        delegationWaiters.removeValue(forKey: id)?
            .resume(returning: .failed("The delegated session was stopped in Watercoded before it finished."))
    }

    static func result(of controller: CurrentController, _ outcome: TurnOutcome) -> DelegationOutcome {
        switch outcome {
        case let .failed(message):
            return .failed("The delegated agent failed: \(message)")
        case .interrupted:
            return .failed("The delegated agent was stopped before it finished.")
        case .completed:
            let reply = controller.transcript.last {
                if case .assistant = $0.content {
                    true
                } else {
                    false
                }
            }
            guard case let .assistant(text)? = reply?.content
            else { return .answered("(The agent finished without a reply.)") }
            let who = [controller.providerDescriptor?.displayName, controller.current.environment?.model]
                .compactMap(\.self).joined(separator: " · ")
            return .answered("\(text)\n\n(From \(who), in Watercoded session “\(controller.current.title)”.)")
        }
    }

    /// Accepts provider ids and common names: `codex`, `claude-code`, `claude`.
    static func providerID(for agent: String) -> ProviderID {
        switch agent.lowercased() {
        case "claude", "claude code", "claudecode": "claude-code"
        default: ProviderID(rawValue: agent.lowercased())
        }
    }
}

enum DelegationError: Error, LocalizedError {
    case parentGone
    case unknownAgent(String, available: [String])
    case unavailable(String)

    var errorDescription: String? {
        switch self {
        case .parentGone: "The session that asked is no longer in Watercoded."
        case let .unknownAgent(agent, available):
            "There's no agent called “\(agent)”. Available: \(available.joined(separator: ", "))."
        case let .unavailable(name): "\(name) isn't installed and signed in on this Mac."
        }
    }
}
