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
    /// Atomically publishes a replay boundary and the transcript version it describes.
    /// A nil transcript retains the existing version, allowing cheap metadata and streaming saves.
    func saveSession(_ current: Current, transcript: [TranscriptItem]?, streamingText: String) async throws
    func loadStreamingText(for id: CurrentID) async throws -> String
}

/// JSON files under Application Support:
///
/// ```
/// Watercoded/
///   pools.json
///   currents/<current-id>/current.json
///   currents/<current-id>/transcript-<uuid>.json
///   currents/<current-id>/attachments/<sha256>
/// ```
///
/// Every file is wrapped in a versioned envelope and written atomically.
public actor FileWorkspaceRepository: WorkspaceRepository {
    public static let schemaVersion = 1

    public let root: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var transcriptStores: [CurrentID: TranscriptStorage] = [:]

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
        let url = folder(for: current.id).appending(path: "current.json")
        var envelope = try readEnvelope(Current.self, from: url) ?? Envelope(
            schemaVersion: Self.schemaVersion,
            value: current
        )
        envelope.value = current
        try writeEnvelope(envelope, to: url)
    }

    public func deleteCurrent(_ id: CurrentID) throws {
        transcriptStores[id] = nil
        let folder = folder(for: id)
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    public func loadTranscript(for id: CurrentID) throws -> [TranscriptItem] {
        let directory = folder(for: id)
        let manifest = try readEnvelope(Current.self, from: directory.appending(path: "current.json"))
        if let file = manifest?.transcriptFile {
            guard file.hasPrefix("transcript-"), file.hasSuffix(".json"), !file.contains("/") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return try TranscriptStorage.load(from: directory.appending(path: file), directory: directory)
        }
        return try read([TranscriptItem].self, from: directory.appending(path: "transcript.json")) ?? []
    }

    public func loadStreamingText(for id: CurrentID) async throws -> String {
        try readEnvelope(Current.self, from: folder(for: id).appending(path: "current.json"))?.streamingText ?? ""
    }

    public func saveTranscript(_ transcript: [TranscriptItem], for id: CurrentID) async throws {
        if let current = try read(Current.self, from: folder(for: id).appending(path: "current.json")) {
            try await saveSession(current, transcript: transcript, streamingText: "")
        } else {
            try write(transcript, to: folder(for: id).appending(path: "transcript.json"))
        }
    }

    public func saveSession(_ current: Current, transcript: [TranscriptItem]?, streamingText: String) async throws {
        let directory = folder(for: current.id)
        let manifestURL = directory.appending(path: "current.json")
        let previous = try readEnvelope(Current.self, from: manifestURL)
        var manifest = Envelope(schemaVersion: Self.schemaVersion, value: current)
        manifest.transcriptFile = previous?.transcriptFile
        manifest.streamingText = streamingText.isEmpty ? nil : streamingText
        if let transcript {
            let file = "transcript-\(UUID().uuidString).json"
            var storage = transcriptStores[current.id] ?? TranscriptStorage()
            try storage.save(transcript, to: directory.appending(path: file), directory: directory)
            transcriptStores[current.id] = storage
            manifest.transcriptFile = file
        }
        // The immutable transcript and attachments are complete before this single commit point.
        // A failed write leaves the previous manifest and replay boundary usable.
        try writeEnvelope(manifest, to: manifestURL)
        if transcript != nil {
            let previousFile = previous?.transcriptFile ?? "transcript.json"
            if previousFile != manifest.transcriptFile {
                try? FileManager.default.removeItem(at: directory.appending(path: previousFile))
            }
        }
    }

    // MARK: Files

    private struct Envelope<Value: Codable>: Codable {
        var schemaVersion: Int
        var value: Value
        var transcriptFile: String?
        var streamingText: String?
    }

    private func folder(for id: CurrentID) -> URL {
        root.appending(path: "currents/\(id)", directoryHint: .isDirectory)
    }

    private func read<Value: Codable>(_ type: Value.Type, from url: URL) throws -> Value? {
        try readEnvelope(type, from: url)?.value
    }

    private func write(_ value: some Codable, to url: URL) throws {
        try writeEnvelope(Envelope(schemaVersion: Self.schemaVersion, value: value), to: url)
    }

    private func readEnvelope<Value: Codable>(_: Value.Type, from url: URL) throws -> Envelope<Value>? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(Envelope<Value>.self, from: Data(contentsOf: url))
    }

    private func writeEnvelope(_ envelope: Envelope<some Codable>, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(envelope).write(to: url, options: .atomic)
    }
}

/// Non-persistent storage for previews and tests.
public actor InMemoryWorkspaceRepository: WorkspaceRepository {
    private var pools: [Pool]
    private var currents: [CurrentID: Current] = [:]
    private var transcripts: [CurrentID: [TranscriptItem]] = [:]
    private var streaming: [CurrentID: String] = [:]

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
        streaming[id] = nil
    }

    public func loadTranscript(for id: CurrentID) -> [TranscriptItem] {
        transcripts[id] ?? []
    }

    public func saveTranscript(_ transcript: [TranscriptItem], for id: CurrentID) {
        transcripts[id] = transcript
    }

    public func saveSession(_ current: Current, transcript: [TranscriptItem]?, streamingText: String) async {
        currents[current.id] = current
        if let transcript {
            transcripts[current.id] = transcript
        }
        streaming[current.id] = streamingText
    }

    public func loadStreamingText(for id: CurrentID) async -> String {
        streaming[id] ?? ""
    }
}
