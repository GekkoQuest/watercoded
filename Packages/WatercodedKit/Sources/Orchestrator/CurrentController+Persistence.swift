import Foundation
import WatercodedCore

extension CurrentController {
    /// Writes pending changes immediately.
    func flush() async {
        saveTask?.cancel()
        saveTask = nil
        guard !isDiscarded else { return }
        let previous = saveInFlight
        var snapshot = current
        if snapshot.relay != nil {
            snapshot.relay = appliedRelay ?? snapshot.relay
        }
        let revision = transcriptRevision
        let items = transcript
        let text = streamingText + pendingStreamingText
        let task = Task { [self] in
            await previous?.value
            guard !isDiscarded else { return }
            do {
                if transcriptLoadError == nil {
                    try await repository.saveSession(
                        snapshot,
                        transcript: revision == savedTranscriptRevision ? nil : items,
                        streamingText: text
                    )
                    savedTranscriptRevision = revision
                } else {
                    try await repository.saveCurrent(snapshot)
                }
            } catch {
                // Keep the old durable checkpoint and leave the revision dirty for a later retry.
            }
        }
        saveInFlight = task
        await task.value
    }

    /// Long turns checkpoint periodically rather than postponing every write until output stops.
    func scheduleProgressSave() {
        guard !isDiscarded, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self else { return }
            await flush()
        }
    }

    /// Coalesces bursts of changes into one write.
    func scheduleSave() {
        guard !isDiscarded else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, let self else { return }
            await flush()
        }
    }
}
