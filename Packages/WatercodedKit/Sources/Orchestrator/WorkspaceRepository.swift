import Foundation
import WatercodedCore

/// Durable storage for pools, currents and transcripts.
public protocol WorkspaceRepository: Sendable {
    func loadPools() async throws -> [Pool]
    func savePools(_ pools: [Pool]) async throws
    func loadCurrents() async throws -> [Current]
    func saveCurrent(_ current: Current) async throws
    func deleteCurrent(_ id: CurrentID) async throws
    func loadTranscript(for id: CurrentID) async throws -> [TranscriptItem]
    func saveTranscript(_ transcript: [TranscriptItem], for id: CurrentID) async throws
}

/// JSON files under Application Support:
///
/// ```
/// Watercoded/
///   pools.json
///   currents/<current-id>/current.json
///   currents/<current-id>/transcript.json
/// ```
///
/// Every file is wrapped in a versioned envelope and written atomically.
public actor FileWorkspaceRepository: WorkspaceRepository {
    public static let schemaVersion = 1

    public let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(root: URL = FileWorkspaceRepository.defaultRoot) {
        self.root = root
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "Watercoded", directoryHint: .isDirectory)
    }

    public func loadPools() throws -> [Pool] {
        try read([Pool].self, from: root.appending(path: "pools.json")) ?? []
    }

    public func savePools(_ pools: [Pool]) throws {
        try write(pools, to: root.appending(path: "pools.json"))
    }

    public func loadCurrents() throws -> [Current] {
        let folder = root.appending(path: "currents", directoryHint: .isDirectory)
        let entries = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { try? read(Current.self, from: $0.appending(path: "current.json")) }
    }

    public func saveCurrent(_ current: Current) throws {
        try write(current, to: folder(for: current.id).appending(path: "current.json"))
    }

    public func deleteCurrent(_ id: CurrentID) throws {
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func loadTranscript(for id: CurrentID) throws -> [TranscriptItem] {
        try read([TranscriptItem].self, from: folder(for: id).appending(path: "transcript.json")) ?? []
    }

    public func saveTranscript(_ transcript: [TranscriptItem], for id: CurrentID) throws {
        try write(transcript, to: folder(for: id).appending(path: "transcript.json"))
    }

    // MARK: Files

    private struct Envelope<Value: Codable>: Codable {
        var schemaVersion: Int
        var value: Value
    }

    private func folder(for id: CurrentID) -> URL {
        root.appending(path: "currents/\(id)", directoryHint: .isDirectory)
    }

    private func read<Value: Codable>(_ type: Value.Type, from url: URL) throws -> Value? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let envelope = try decoder.decode(Envelope<Value>.self, from: Data(contentsOf: url))
        return envelope.value
    }

    private func write(_ value: some Codable, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(Envelope(schemaVersion: Self.schemaVersion, value: value))
        try data.write(to: url, options: .atomic)
    }
}

/// Non-persistent storage for previews and tests.
public actor InMemoryWorkspaceRepository: WorkspaceRepository {
    private var pools: [Pool]
    private var currents: [CurrentID: Current] = [:]
    private var transcripts: [CurrentID: [TranscriptItem]] = [:]

    public init(pools: [Pool] = []) {
        self.pools = pools
    }

    public func loadPools() -> [Pool] {
        pools
    }

    public func savePools(_ pools: [Pool]) {
        self.pools = pools
    }

    public func loadCurrents() -> [Current] {
        Array(currents.values)
    }

    public func saveCurrent(_ current: Current) {
        currents[current.id] = current
    }

    public func deleteCurrent(_ id: CurrentID) {
        currents[id] = nil
        transcripts[id] = nil
    }

    public func loadTranscript(for id: CurrentID) -> [TranscriptItem] {
        transcripts[id] ?? []
    }

    public func saveTranscript(_ transcript: [TranscriptItem], for id: CurrentID) {
        transcripts[id] = transcript
    }
}
