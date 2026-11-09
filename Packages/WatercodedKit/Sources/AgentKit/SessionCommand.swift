/// Provider operations behind the shared composer commands. Providers retain their own history,
/// goal evaluation and continuation behavior; the host does not simulate them with prompts.
public enum SessionCommand: Sendable, Hashable {
    case compact
    case goal(GoalAction)

    public enum GoalAction: Sendable, Hashable {
        case status
        case set(String)
        case clear
    }

    /// Claude Code's documented noninteractive command surface.
    public var slashText: String {
        switch self {
        case .compact: "/compact"
        case .goal(.status): "/goal"
        case let .goal(.set(objective)): "/goal \(objective)"
        case .goal(.clear): "/goal clear"
        }
    }
}
