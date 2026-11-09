import AgentKit
import Foundation
import WatercodedCore

extension CurrentController {
    /// Shared session commands followed by the provider's additional commands. Shared names win.
    public var promptCommands: [SlashCommand] {
        let shared = PromptCommand.allCases.filter { supports($0) }.map(\.descriptor)
        var names = Set(shared.map { $0.name.lowercased() })
        return shared + availableCommands.filter { names.insert($0.name.lowercased()).inserted }
    }

    /// Whether this draft invokes a command handled by Watercoded, even during an active turn.
    public func isLocalPromptCommand(_ text: String) -> Bool {
        PromptCommand.parse(text) != nil
    }

    /// Submits composer input. Returns false on validation errors so the composer can keep the draft.
    /// Internal agent instructions use `send` directly and never pass through command parsing.
    public func submitPrompt(_ text: String, images: [ImageAttachment] = []) async -> Bool {
        guard current.status != .settled else {
            return commandError("This session is archived. Reopen it to continue.")
        }
        guard let (command, argument) = PromptCommand.parse(text) else {
            guard !isTurnActive || capabilities.contains(.queueing) else {
                return commandError("Wait for the current turn to finish before sending a message.")
            }
            await send(text, images: images)
            return true
        }
        guard supports(command) else {
            return commandError(
                "/\(command.rawValue) is unavailable in this session. Use /help to see available commands."
            )
        }
        guard images.isEmpty else {
            return commandError("Send attached images with a message, or remove them before running a command.")
        }
        let managesGoal = command == .goal && (argument.isEmpty || argument.lowercased() == "clear")
        guard !isTurnActive || command == .help || command == .status || command == .stop || managesGoal else {
            return commandError("Wait for the current turn to finish before using /\(command.rawValue).")
        }
        guard argument.isEmpty || command.acceptsArgument else {
            return commandError("/\(command.rawValue) does not take arguments.")
        }
        return await run(command, argument: argument)
    }

    private func supports(_ command: PromptCommand) -> Bool {
        switch command {
        case .help, .status: true
        case .model: providerDescriptor != nil
        case .effort: providerDescriptor?.effortLevels.isEmpty == false
        case .mode: capabilities.contains(.toolApprovals)
        case .plan: capabilities.contains(.planMode)
        case .stop: capabilities.contains(.interrupt)
        case .verify: canVerify
        case .compact: capabilities.contains(.compaction)
        case .goal: capabilities.contains(.goals)
        }
    }

    private func run(_ command: PromptCommand, argument: String) async -> Bool {
        switch command {
        case .help:
            commandNotice(promptCommands.map {
                "/\($0.name)\($0.argumentHint.map { " \($0)" } ?? "") — \($0.summary)"
            }.joined(separator: "\n"))
        case .status:
            commandNotice("""
            Agent: \(providerDescriptor?.displayName ?? "Unavailable")
            Model: \(current.model ?? "Default")
            Effort: \(current.effort ?? "Auto")
            Mode: \(current.permissionMode.displayName)
            Context: \(current.usage.contextTokens) tokens\(current.usage.contextWindow.map { " of \($0)" } ?? "")
            """)
        case .model:
            return await modelCommand(argument)
        case .effort:
            return await effortCommand(argument)
        case .mode:
            return await modeCommand(argument)
        case .plan:
            await setPermissionMode(.plan)
            if argument.isEmpty {
                commandNotice("Plan mode enabled. Send a message to ask the agent for a plan.")
            } else {
                await send(argument)
            }
        case .stop:
            guard isTurnActive else {
                commandNotice("No turn is running.")
                return true
            }
            await interrupt()
        case .verify:
            guard !isVerifying else { return commandError("Verification is already running.") }
            // Like the Verify button, leave the composer available while the check runs.
            Task { await verify() }
        case .compact:
            return await runSessionCommand(.compact)
        case .goal:
            return await goalCommand(argument)
        }
        return true
    }

    private func goalCommand(_ argument: String) async -> Bool {
        let action: SessionCommand.GoalAction
        switch argument.lowercased() {
        case "": action = .status
        case "clear": action = .clear
        case "pause", "resume", "stop", "off", "reset", "none", "cancel":
            return commandError("Use /goal clear to remove a goal, or /goal <objective> to start one.")
        default:
            guard argument.count <= 4000 else { return commandError("Keep the goal within 4,000 characters.") }
            action = .set(argument)
        }
        return await runSessionCommand(.goal(action))
    }

    private func runSessionCommand(_ command: SessionCommand) async -> Bool {
        append(.user(text: command.slashText))
        let startsWork = switch command {
        case .compact, .goal(.set): true
        case .goal(.status), .goal(.clear): false
        }
        if startsWork {
            // Reserve the session before startup/snapshots yield, just as sending a message does.
            isTurnActive = true
            update { $0.status = .flowing }
        }
        await waitForWorktreeCleanup()
        if case .goal(.set) = command {
            await recordTurnStart()
        }
        do {
            let session = try await ensureSession()
            if let summary = try await session.runCommand(command) {
                commandNotice(summary)
            }
            scheduleSave()
            return true
        } catch {
            if startsWork {
                isTurnActive = false
                update { $0.status = .ashore }
            }
            return commandError(error.localizedDescription)
        }
    }

    private func modelCommand(_ argument: String) async -> Bool {
        let catalog = await provider?.modelCatalog()
        let choices = catalog?.choices ?? []
        let models = choices.isEmpty ? providerDescriptor?.models ?? [] : choices
        if argument.isEmpty {
            commandNotice("Model: \(current.model ?? "Default"). Use /model <name> or /model default.\n"
                + "Available: \(models.map(\.id).joined(separator: ", ")).")
            return true
        }
        let isDefault = argument.lowercased() == "default"
        guard isDefault || capabilities.contains(.customModels)
            || models.contains(where: { $0.id == argument }) || catalog?.model(named: argument) != nil else {
            return commandError("Unknown model: \(argument). Use /model to see available models.")
        }
        await setModel(isDefault ? nil : argument)
        commandNotice("Model set to \(current.model ?? "Default").")
        return true
    }

    private func effortCommand(_ argument: String) async -> Bool {
        let catalog = await provider?.modelCatalog()
        let configuredModel = await provider?.configuredDefaultModel()
        let model = current.model ?? configuredModel ?? catalog?.defaultModelID
        let modelLevels = model.flatMap { catalog?.model(named: $0)?.effortLevels }
        let levels = modelLevels.flatMap { $0.isEmpty ? nil : $0 } ?? providerDescriptor?.effortLevels ?? []
        if argument.isEmpty {
            commandNotice("Effort: \(current.effort ?? "Auto"). Use /effort <level> or /effort auto.\n"
                + "Available: \(levels.joined(separator: ", ")).")
            return true
        }
        let level = argument.lowercased()
        guard level == "auto" || levels.contains(level) else {
            return commandError("Unknown effort: \(argument). Use /effort to see available levels.")
        }
        await setEffort(level == "auto" ? nil : level)
        commandNotice("Effort set to \(current.effort ?? "Auto").")
        return true
    }

    private func modeCommand(_ argument: String) async -> Bool {
        let modes: [(String, PermissionMode)] = [
            ("ask", .ask), ("accept-edits", .acceptEdits), ("plan", .plan), ("full-access", .fullAccess)
        ].filter { $0.1 != .plan || capabilities.contains(.planMode) }
        if argument.isEmpty {
            commandNotice("Mode: \(current.permissionMode.displayName). Use /mode <name>.\n"
                + "Available: \(modes.map(\.0).joined(separator: ", ")).")
            return true
        }
        guard let mode = modes.first(where: { $0.0 == argument.lowercased() })?.1 else {
            return commandError("Unknown mode: \(argument). Use /mode to see available modes.")
        }
        guard mode != .fullAccess || current.permissionMode == .fullAccess else {
            return commandError("Choose Full Access from the permissions menu to review and confirm access.")
        }
        await setPermissionMode(mode)
        commandNotice("Mode set to \(mode.displayName).")
        return true
    }

    private func commandNotice(_ message: String) {
        append(.notice(Notice(.info, message)))
        scheduleSave()
    }

    private func commandError(_ message: String) -> Bool {
        append(.notice(Notice(.warning, message)))
        scheduleSave()
        return false
    }
}

private enum PromptCommand: String, CaseIterable {
    case help
    case status
    case compact
    case goal
    case model
    case effort
    case mode
    case plan
    case stop
    case verify

    var acceptsArgument: Bool {
        self == .model || self == .effort || self == .mode || self == .goal || self == .plan
    }

    var descriptor: SlashCommand {
        let summary: String
        let hint: String?
        switch self {
        case .help: (summary, hint) = ("Show available commands", nil)
        case .status: (summary, hint) = ("Show session settings and context usage", nil)
        case .compact: (summary, hint) = ("Compact the agent's conversation history", nil)
        case .goal: (summary, hint) = ("Show, set or clear the agent's goal", "[objective|clear]")
        case .model: (summary, hint) = ("Show or change the model", "[name|default]")
        case .effort: (summary, hint) = ("Show or change reasoning effort", "[level|auto]")
        case .mode: (summary, hint) = ("Show or change permissions", "[ask|accept-edits|plan|full-access]")
        case .plan: (summary, hint) = ("Switch to planning mode, optionally with a prompt", "[prompt]")
        case .stop: (summary, hint) = ("Interrupt the current turn", nil)
        case .verify: (summary, hint) = ("Run the repository's configured check", nil)
        }
        return SlashCommand(name: rawValue, summary: summary, argumentHint: hint)
    }

    static func parse(_ text: String) -> (PromptCommand, String)? {
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let first = parts.first, first.hasPrefix("/"),
              let command = PromptCommand(rawValue: String(first.dropFirst()).lowercased()) else { return nil }
        return (command, parts.count == 2 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "")
    }
}
