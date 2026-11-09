import SwiftUI
import WatercodedDesign

/// What the water in the message field and sidebar means. Opened from Help and the welcome screen.
public struct GlossaryView: View {
    public static let windowID = "glossary"

    public init() {}

    private let water: [(symbol: String, meaning: String)] = [
        ("drop.halffull", "Water level: how much of the context window is used."),
        ("water.waves", "Ripples: the agent is streaming a reply."),
        ("drop.fill", "Drops falling in: tool calls (bigger drops for edits and commands)."),
        ("hand.raised.fill", "A droplet hanging from the rim: the agent is waiting for your approval."),
        ("aqi.medium", "Murky water: the last turn failed, or tools keep erroring."),
        ("snowflake", "Frost: the session is archived.")
    ]

    public var body: some View {
        Form {
            Section("Reading the water") {
                ForEach(water, id: \.meaning) { item in
                    Label(item.meaning, systemImage: item.symbol)
                }
                Text("Drag the window and the water sloshes. Shake it to offer to stop the agent. "
                    + "With Reduce Motion on, the water stays still and only the level changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480)
    }
}
