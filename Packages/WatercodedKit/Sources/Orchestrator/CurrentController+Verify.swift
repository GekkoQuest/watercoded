import AgentKit
import Foundation
import ProcessKit
import WatercodedCore

extension CurrentController {
    /// Whether the repository has a check command to run.
    public var canVerify: Bool {
        verifySettings() != nil
    }

    /// Runs the repository's check command in the channel and records the result, which the water
    /// shows as clear (passed) or murky (failed). Shown in the transcript like a command.
    public func verify() async {
        guard let settings = verifySettings(), !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        let callID = "watercoded-verify-\(UUID().uuidString)"
        handle(.toolCallStarted(ToolCall(
            callID: callID,
            name: "Verify",
            kind: .shell,
            summary: settings.command,
            input: [:]
        )))
        var output = ""
        var passed = false
        do {
            let result = try await ProcessRunner.run(
                executable: URL(filePath: "/bin/zsh"),
                arguments: ["-lc", settings.command],
                currentDirectory: current.channel.url,
                environment: ShellEnvironment.shared.environment(),
                timeout: .seconds(20 * 60)
            )
            output = String((result.standardOutput + result.standardError).suffix(12000))
            passed = result.succeeded
        } catch {
            output = error.localizedDescription
        }
        handle(.toolCallFinished(callID: callID, output: output, isError: !passed))
        update { $0.lastCheck = CheckResult(command: settings.command, passed: passed) }
        append(.notice(passed
                ? Notice(.info, "Verified: `\(settings.command)` passed.")
                : Notice(
                    .error,
                    "Verify failed: `\(settings.command)`. Ask the agent to fix it, or check the output above."
                )))
        scheduleSave()
    }
}
