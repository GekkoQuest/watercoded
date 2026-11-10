import AgentKit
import Foundation
import GitKit
import ProcessKit
import Testing
import WatercodedCore
@testable import Orchestrator

@MainActor
@Suite("Session lifecycle regressions", .serialized)
struct SessionLifecycleTests {
    @Test func `repository removal prevents late saves from recreating sessions`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let pool = try await fixture.workspace.addPool(at: fixture.repository)
        let controller = fixture.workspace.adopt(
            makeCurrent(path: fixture.repository.path, poolID: pool.id), transcript: []
        )
        controller.markViewed() // a save is already pending when removal begins
        await fixture.workspace.removePool(pool.id)
        controller.markViewed() // the selected screen disappears after removal
        await controller.flush()
        try await Task.sleep(for: .milliseconds(500))
        #expect(await fixture.storage.loadCurrents().isEmpty)
        #expect(fixture.workspace.currents.isEmpty)
    }

    @Test func `failed submissions preserve the draft and report failure`() async {
        let provider = LifecycleProvider(failsToSend: true)
        let controller = CurrentController(
            current: makeCurrent(), transcript: [], provider: provider, repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        controller.draft = "Try again"
        controller.draftImages = [ImageAttachment(mediaType: "image/png", data: Data([1, 2, 3]))]
        #expect(await controller.submitPrompt(controller.draft, images: controller.draftImages) == false)
        #expect(controller.current.status == .stalled)
        #expect(controller.draft == "Try again")
        #expect(controller.draftImages.count == 1)
        await controller.stopSession()
    }

    @Test(arguments: [false, true])
    func `effort changes wait for idle input and preserve resume identity`(nativeCommand: Bool) async throws {
        let provider = LifecycleProvider()
        let controller = CurrentController(
            current: makeCurrent(), transcript: [], provider: provider, repository: InMemoryWorkspaceRepository()
        )
        defer { controller.discard() }
        _ = try await controller.ensureSession()
        let first = try #require(await provider.sessions.first)
        controller.handle(.sessionStarted(SessionInfo(providerSessionID: "existing-session", model: nil)))
        controller.handle(.turnStarted)
        await controller.setEffort("high")
        #expect(controller.isTurnActive)
        #expect(await !first.terminated)
        _ = try await controller.ensureSession() // queued messages still use the running session
        #expect(await provider.sessions.count == 1)
        controller.handle(.turnFinished(.completed))
        if nativeCommand {
            #expect(await controller.submitPrompt("/compact"))
        } else {
            _ = try await controller.ensureSession()
        }
        #expect(await first.terminated)
        #expect(await provider.sessions.count == 2)
        #expect(await provider.configurations.last?.effort == "high")
        #expect(await provider.configurations.last?.resumeSessionID == "existing-session")
        #expect(controller.current.restartSessionWhenIdle == nil)
        await controller.stopSession()
    }

    @Test(arguments: [CurrentStatus.ashore, .stalled, .flowing, .waiting])
    func `every saved live relay is reattached`(status: CurrentStatus) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let directory = fixture.repository.appending(path: "relay")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "\(getpid())".write(to: directory.appending(path: RelayFiles.pid), atomically: true, encoding: .utf8)
        let handle = RelayHandle(directory: directory.path, offset: 0)
        let provider = LifecycleProvider()
        var current = makeCurrent(path: fixture.repository.path)
        current.status = status
        current.relay = handle
        let storage = InMemoryWorkspaceRepository()
        await storage.saveCurrent(current)
        let workspace = Workspace(
            registry: ProviderRegistry([provider]), repository: storage,
            delegationMailbox: fixture.workspace.delegationMailbox
        )
        await workspace.load()
        #expect(await provider.reattached == [handle])
        #expect(workspace.currents.first?.isSessionLive == true)
        #expect(workspace.currents.first?.current.status == status)
        await workspace.shutdown()
    }

    @Test func `deferred effort changes survive persistence and reattachment`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let directory = fixture.repository.appending(path: "relay")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "\(getpid())".write(to: directory.appending(path: RelayFiles.pid), atomically: true, encoding: .utf8)
        var current = makeCurrent(path: fixture.repository.path)
        current.status = .ashore
        current.effort = "high"
        current.restartSessionWhenIdle = true
        current.relay = RelayHandle(directory: directory.path, offset: 0)
        let decoded = try JSONDecoder().decode(Current.self, from: JSONEncoder().encode(current))
        await fixture.storage.saveCurrent(decoded)
        let provider = LifecycleProvider()
        let workspace = Workspace(
            registry: ProviderRegistry([provider]), repository: fixture.storage,
            delegationMailbox: fixture.workspace.delegationMailbox
        )
        await workspace.load()
        let controller = try #require(workspace.currents.first)
        #expect(controller.isSessionLive)
        _ = try await controller.ensureSession()
        #expect(await provider.configurations.last?.effort == "high")
        #expect(controller.current.restartSessionWhenIdle == nil)
        await controller.stopSession()
        await workspace.shutdown()
    }

    @Test func `stale idle relay handles are cleared without changing review status`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        var current = makeCurrent()
        current.status = .ashore
        current.relay = RelayHandle(directory: fixture.repository.appending(path: "missing").path, offset: 0)
        await fixture.storage.saveCurrent(current)
        let workspace = Workspace(
            registry: ProviderRegistry([LifecycleProvider()]), repository: fixture.storage,
            delegationMailbox: fixture.workspace.delegationMailbox
        )
        await workspace.load()
        #expect(workspace.currents.first?.current.relay == nil)
        #expect(workspace.currents.first?.current.status == .ashore)
        await workspace.shutdown()
    }

    @Test func `uncommitted changes work before and after the first commit`() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let folder = fixture.repository.deletingLastPathComponent().appending(path: "unborn")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pool = try await fixture.workspace.initializeRepositoryAndAddPool(at: folder)
        let channel = try await WorktreeManager().makeCheckoutChannel(for: pool)
        var current = makeCurrent(poolID: pool.id)
        current.channel = channel
        let controller = fixture.workspace.adopt(current, transcript: [])
        defer { controller.discard() }
        let url = folder.appending(path: "new file.txt")
        try "new\n".write(to: url, atomically: true, encoding: .utf8)
        var diff = try await fixture.workspace.diff(for: controller.id, scope: .uncommitted)
        #expect(diff.files.map(\.path) == ["new file.txt"])
        try await fixture.workspace.revert(#require(diff.files.first), in: controller.id, scope: .uncommitted)
        #expect(try await fixture.workspace.diff(for: controller.id, scope: .uncommitted).isEmpty)
        try "new\n".write(to: url, atomically: true, encoding: .utf8)
        try await GitClient().commitAll(in: folder, message: "Initial", identity: ("Tests", "tests@tests.invalid"))
        #expect(try await fixture.workspace.diff(for: controller.id, scope: .uncommitted).isEmpty)
        try "changed\n".write(to: url, atomically: true, encoding: .utf8)
        diff = try await fixture.workspace.diff(for: controller.id, scope: .uncommitted)
        try await fixture.workspace.revert(#require(diff.files.first), in: controller.id, scope: .uncommitted)
        #expect(try String(contentsOf: url, encoding: .utf8) == "new\n")
    }

    private func makeCurrent(path: String = "/tmp", poolID: PoolID = PoolID()) -> Current {
        Current(
            poolID: poolID, title: "Lifecycle", providerID: "lifecycle",
            channel: Channel(kind: .checkout, path: path, branch: "main", baseCommit: "HEAD")
        )
    }
}

private actor LifecycleProvider: AgentProvider {
    nonisolated let descriptor = ProviderDescriptor(
        id: "lifecycle", displayName: "Lifecycle", symbolName: "", tintHue: 0,
        capabilities: [.backgroundSessions, .resume, .queueing, .compaction], models: [], installHint: ""
    )
    let failsToSend: Bool
    var sessions: [LifecycleSession] = []
    var configurations: [SessionConfiguration] = []
    var reattached: [RelayHandle] = []

    init(failsToSend: Bool = false) {
        self.failsToSend = failsToSend
    }

    func availability() async -> ProviderAvailability {
        .available(version: nil)
    }

    func startSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        configurations.append(configuration)
        let session = LifecycleSession(failsToSend: failsToSend)
        sessions.append(session)
        return session
    }

    func reattachSession(_ handle: RelayHandle) async throws -> any AgentSession {
        reattached.append(handle)
        return LifecycleSession(failsToSend: false)
    }
}

private actor LifecycleSession: AgentSession {
    nonisolated let events: AsyncStream<AgentEvent>
    private let continuation: AsyncStream<AgentEvent>.Continuation
    let failsToSend: Bool
    var terminated = false

    init(failsToSend: Bool) {
        self.failsToSend = failsToSend
        (events, continuation) = AsyncStream.makeStream()
    }

    func send(_: UserMessage) async throws {
        if failsToSend {
            throw AgentError.sessionClosed
        }
    }

    func runCommand(_: SessionCommand) async throws -> String? {
        nil
    }

    func respond(to _: PermissionRequest.ID, with _: PermissionDecision) async throws {}
    func interrupt() async throws {}
    func terminate() async {
        terminated = true
        continuation.finish()
    }
}
