import AgentKit
import ClaudeCodeProvider
import CodexProvider
import Foundation
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Composer commands")
struct PromptCommandTests {
    @Test func `both real providers offer shared commands before the first message`() {
        for provider: any AgentProvider in [ClaudeCodeProvider(), CodexProvider()] {
            let controller = makeController(provider)
            defer { controller.discard() }
            let names = Set(controller.promptCommands.map(\.name))
            #expect(names.isSuperset(of: [
                "help",
                "status",
                "compact",
                "goal",
                "plan",
                "model",
                "effort",
                "mode",
                "stop"
            ]))
            #expect(!names.contains("verify"))
            controller.verifySettings = { VerifySettings(command: "true") }
            #expect(controller.promptCommands.contains { $0.name == "verify" })
        }
    }

    @Test func `shared names win and provider additions survive`() {
        let controller = makeController()
        defer { controller.discard() }
        controller.handle(.commandsAvailable([
            SlashCommand(name: "MODEL", summary: "Provider model menu"),
            SlashCommand(name: "review", summary: "Review changes")
        ]))
        #expect(controller.promptCommands.filter { $0.name.lowercased() == "model" }.count == 1)
        #expect(controller.promptCommands.last?.name == "review")
    }

    @Test func `settings and help run locally without starting an agent`() async {
        let provider = CommandProvider()
        let controller = makeController(provider)
        defer { controller.discard() }
        for text in ["/help", "/status", "/model precise", "/effort high", "/mode accept-edits", "/plan"] {
            #expect(await controller.submitPrompt(text))
        }
        #expect(controller.current.model == "precise")
        #expect(controller.current.effort == "high")
        #expect(controller.current.permissionMode == .plan)
        #expect(!controller.isSessionLive)
        #expect(await provider.session.messages.isEmpty)
    }

    @Test func `invalid input cannot change settings or become an agent prompt`() async {
        let provider = CommandProvider()
        let controller = makeController(provider)
        defer { controller.discard() }
        for text in ["/effort ultra", "/mode nonsense", "/help extra", "/model unknown", "/mode full-access"] {
            #expect(await !controller.submitPrompt(text))
        }
        #expect(controller.current.permissionMode == .ask)
        #expect(controller.current.model == nil)
        #expect(controller.current.effort == nil)
        #expect(await provider.session.messages.isEmpty)
    }

    @Test func `native operations use the provider contract and plan sends its prompt in plan mode`() async {
        let provider = CommandProvider()
        let controller = makeController(provider)
        defer { controller.discard() }
        #expect(await controller.submitPrompt("/compact"))
        controller.isTurnActive = false // the provider finished compaction
        #expect(await controller.submitPrompt("/goal Make the tests pass"))
        #expect(await controller.submitPrompt("/goal"))
        #expect(await controller.submitPrompt("/goal clear"))
        #expect(await provider.session.commands == [
            .compact,
            .goal(.set("Make the tests pass")),
            .goal(.status),
            .goal(.clear)
        ])
        controller.isTurnActive = false
        #expect(await controller.submitPrompt("/plan Explain the migration"))
        #expect(controller.current.permissionMode == .plan)
        #expect(await provider.session.messages.map(\.text) == ["Explain the migration"])
        #expect(await provider.session.mode == .plan)
        await controller.stopSession()
    }

    @Test func `active turns allow inspection and stopping but reject settings changes`() async {
        let provider = CommandProvider()
        let controller = makeController(provider)
        controller.session = provider.session
        controller.isTurnActive = true
        defer { controller.discard() }
        #expect(await controller.submitPrompt("/status"))
        #expect(await !controller.submitPrompt("/model precise"))
        #expect(await !controller.submitPrompt("/compact"))
        #expect(await controller.submitPrompt("/goal clear"))
        #expect(await controller.submitPrompt("/stop"))
        #expect(await provider.session.interrupts == 1)
        #expect(controller.current.model == nil)
    }

    @Test func `native additions and ordinary messages pass through unchanged`() async {
        let provider = CommandProvider()
        let controller = makeController(provider)
        defer { controller.discard() }
        #expect(await controller.submitPrompt("/review 123"))
        #expect(await provider.session.messages.map(\.text) == ["/review 123"])
        await controller.stopSession()
    }

    @Test func `unsupported and archived commands never launch a provider`() async {
        let controller = makeController(nil)
        defer { controller.discard() }
        #expect(controller.promptCommands.map(\.name) == ["help", "status"])
        #expect(await !controller.submitPrompt("/compact"))
        controller.update { $0.status = .settled }
        #expect(await !controller.submitPrompt("/help"))
    }

    @Test func `command validation preserves drafts and images`() async {
        let provider = CommandProvider()
        let controller = makeController(provider)
        defer { controller.discard() }
        controller.draft = "/compact"
        let image = ImageAttachment(mediaType: "image/png", data: Data([1, 2, 3]))
        controller.draftImages = [image]
        #expect(await !controller.submitPrompt(controller.draft, images: controller.draftImages))
        #expect(controller.draft == "/compact")
        #expect(controller.draftImages == [image])
        #expect(await provider.session.commands.isEmpty)
    }

    @Test func `provider errors release a reserved command turn`() async {
        let provider = CommandProvider()
        let controller = makeController(provider)
        defer { controller.discard() }
        await provider.session.rejectCommands()
        #expect(await !controller.submitPrompt("/compact"))
        #expect(!controller.isTurnActive)
        #expect(controller.current.status == .ashore)
        await controller.stopSession()
    }

    private func makeController(_ provider: (any AgentProvider)? = CommandProvider()) -> CurrentController {
        CurrentController(
            current: Current(
                poolID: PoolID(), title: "Commands",
                providerID: provider?.descriptor.id ?? ProviderID(rawValue: "missing"),
                model: nil, permissionMode: .ask,
                channel: Channel(kind: .checkout, path: "/tmp", branch: "main", baseCommit: "abc")
            ),
            transcript: [], provider: provider,
            repository: FileWorkspaceRepository(root: FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString))
        )
    }
}

private struct CommandProvider: AgentProvider {
    let session = CommandSession()
    let descriptor = ProviderDescriptor(
        id: ProviderID(rawValue: "commands"), displayName: "Command test", symbolName: "terminal", tintHue: 0,
        capabilities: [.planMode, .toolApprovals, .interrupt, .liveSettings, .compaction, .goals],
        models: [AgentModel(id: "precise", displayName: "Precise")], installHint: "", effortLevels: ["low", "high"]
    )

    func availability() async -> ProviderAvailability {
        .available(version: nil)
    }

    func startSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        session
    }
}

private actor CommandSession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    var messages: [UserMessage] = []
    var commands: [SessionCommand] = []
    var interrupts = 0
    var mode: PermissionMode?
    private var shouldRejectCommands = false

    init() {
        (events, continuation) = AsyncStream.makeStream()
    }

    func send(_ message: UserMessage) async throws {
        messages.append(message)
    }

    func runCommand(_ command: SessionCommand) async throws -> String? {
        if shouldRejectCommands {
            throw AgentError.unsupported("Command")
        }
        commands.append(command)
        return nil
    }

    func rejectCommands() {
        shouldRejectCommands = true
    }

    func respond(to _: PermissionRequest.ID, with _: PermissionDecision) async throws {}
    func interrupt() async throws {
        interrupts += 1
    }

    func terminate() async {
        continuation.finish()
    }

    func setPermissionMode(_ mode: PermissionMode) async throws {
        self.mode = mode
    }
}
