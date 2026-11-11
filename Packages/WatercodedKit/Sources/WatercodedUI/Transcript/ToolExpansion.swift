import Observation

/// Expansion belongs to the transcript, so lazy row recycling does not close a card.
@Observable
final class ToolExpansion {
    private(set) var expandedCalls: Set<String> = []

    func toggle(_ callID: String) {
        if !expandedCalls.insert(callID).inserted {
            expandedCalls.remove(callID)
        }
    }
}
