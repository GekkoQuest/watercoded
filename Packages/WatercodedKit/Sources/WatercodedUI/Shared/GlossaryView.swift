import SwiftUI
import WatercodedDesign

/// What the water in the message field and sidebar means. Opened from Help and the welcome screen.
public struct GlossaryView: View {
    public static let windowID = "glossary"

    public init() {}

    /// Keep in sync with the table at the top of the README.
    private let water: [(symbol: String, meaning: String)] = [
        ("drop.halffull", "How full it is: how much of the model's context window the conversation uses."),
        ("water.waves", "Ripples: the agent is writing a reply."),
        ("drop.fill", "Drops falling in: tool calls (bigger drops for edits and commands)."),
        (
            "hand.raised.fill",
            "A droplet hanging from the top: the agent is waiting for your approval. "
                + "It falls in when you allow, and evaporates when you deny."
        ),
        (
            "aqi.medium",
            "Murky water: your check (Verify) or the agent's last test or build failed, or the turn failed."
        ),
        ("bubbles.and.sparkles", "Rising bubbles: subagents at work."),
        ("arrow.down.to.line", "A burst of bubbles as the level drops: the conversation was compacted."),
        (
            "thermometer.snowflake",
            "Light frost: the prompt cache expired, so the next turn re-reads the whole context."
        ),
        (
            "thermometer.sun",
            "Heat haze: a subscription limit is over 80% used, or an API-key session has spent more than $5."
        ),
        ("snowflake", "Frost, and the water stops moving: the session is archived.")
    ]

    public var body: some View {
        Form {
            Section("Reading the water") {
                ForEach(water, id: \.meaning) { item in
                    Label(item.meaning, systemImage: item.symbol)
                }
                Text("The water fills each session's message box, and a small glass in the sidebar shows the same. "
                    + "Drag the window and the water sloshes. Shake it to offer to stop the agent. "
                    + "With Reduce Motion on, the water stays still and only the level changes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, idealWidth: 520, minHeight: 480)
    }
}
