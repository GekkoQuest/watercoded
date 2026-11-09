import AgentKit
import Foundation
import WatercodedCore

/// A scripted, offline provider: replays a believable session without spending tokens or
/// touching files. Used for demos, UI work, previews and tests.
///
/// Besides the built-in demo, every `*.json` script in ``scriptsDirectory`` appears as a model,
/// including Currents saved with "Save as Replay Script".
public struct ReplayProvider: TranscriptRecording {
    public static let id: ProviderID = "replay"
    public static let standardModelID = "standard"

    /// Multiplies every scripted delay. `0` replays instantly (tests).
    private let pace: Double
    public let scriptsDirectory: URL

    public init(pace: Double = 1, scriptsDirectory: URL = ReplayProvider.defaultScriptsDirectory) {
        self.pace = pace
        self.scriptsDirectory = scriptsDirectory
    }

    public static var defaultScriptsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".watercoded/replays", directoryHint: .isDirectory)
    }

    public var descriptor: ProviderDescriptor {
        let recorded = savedScriptNames().map { AgentModel(id: $0, displayName: $0) }
        return ProviderDescriptor(
            id: Self.id,
            displayName: "Replay (Demo)",
            symbolName: "play.circle",
            tintHue: 0.55,
            capabilities: [.streamingText, .toolApprovals, .interrupt, .costReporting, .questions, .planMode],
            models: [AgentModel(id: Self.standardModelID, displayName: "Built-in demo", isDefault: true)] + recorded,
            installHint: "Built in.",
            isDemo: true
        )
    }

    public func availability() async -> ProviderAvailability {
        .available(version: "1.0")
    }

    public func startSession(_ configuration: SessionConfiguration) async throws -> any AgentSession {
        try ReplaySession(script: script(named: configuration.model), pace: pace)
    }

    // MARK: Scripts

    func script(named name: String?) throws -> ReplayScript {
        guard let name, name != Self.standardModelID, name != "replay" else { return .standard }
        let data = try Data(contentsOf: scriptsDirectory.appending(path: "\(name).json"))
        return try JSONDecoder().decode(ReplayScript.self, from: data)
    }

    private func savedScriptNames() -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: scriptsDirectory,
            includingPropertiesForKeys: nil
        ))
            ?? []
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }
            .sorted()
    }

    // MARK: TranscriptRecording

    public func record(_ transcript: [TranscriptItem], named name: String) throws -> URL {
        let script = ReplayScript(recording: transcript)
        try FileManager.default.createDirectory(at: scriptsDirectory, withIntermediateDirectories: true)
        let url = scriptsDirectory.appending(path: "\(Slug.make(from: name, fallback: "recording")).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(script).write(to: url, options: .atomic)
        return url
    }
}
