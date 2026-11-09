import Foundation

extension CurrentController {
    /// Whether this Current can be continued in the agent's own CLI right now.
    public var canContinueInTerminal: Bool {
        !isTurnActive && terminalCommand != nil
    }

    /// Stops the app's agent (two processes must never drive one session) and writes a `.command`
    /// script that opens the channel and resumes the session in the agent's CLI. Open the returned
    /// file with Terminal. The Current stays in Watercoded; sending it a message later resumes it here.
    public func handOffToTerminal() async throws -> URL {
        guard let command = terminalCommand else {
            throw CocoaError(.featureUnsupported)
        }
        await stopSession()
        if current.status == .flowing || current.status == .waiting {
            update { $0.status = .ashore }
        }
        scheduleSave()

        let folder = FileManager.default.temporaryDirectory.appending(
            path: "watercoded-handoff",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appending(path: "\(id).command")
        let body = """
        #!/bin/zsh -l
        cd \(Self.shellQuoted(current.channel.url.path)) || exit 1
        clear
        exec \(command.map(Self.shellQuoted).joined(separator: " "))

        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private var terminalCommand: [String]? {
        guard let sessionID = current.providerSessionID else { return nil }
        return provider?.terminalResumeCommand(sessionID: sessionID)
    }

    nonisolated static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
