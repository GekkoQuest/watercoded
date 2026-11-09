import Foundation
import WatercodedCore

/// A provider that can save a finished Current as a replayable script (e.g. for demos and
/// UI test fixtures). The UI finds it through the registry, so it never imports the provider.
public protocol TranscriptRecording: AgentProvider {
    /// Saves `transcript` as a script named `name` and returns where it was written.
    func record(_ transcript: [TranscriptItem], named name: String) throws -> URL
}

extension ProviderRegistry {
    /// The first registered provider that can record transcripts.
    public var recorder: (any TranscriptRecording)? {
        providers.lazy.compactMap { $0 as? any TranscriptRecording }.first
    }
}
