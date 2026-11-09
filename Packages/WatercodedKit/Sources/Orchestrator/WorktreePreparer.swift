import Foundation
import ProcessKit
import WatercodedCore

/// Prepares a fresh worktree from a repository's ``WorktreeSetup``: clones ignored files across,
/// then runs the setup script. Returns a log for the transcript.
struct WorktreePreparer: Sendable {
    struct Outcome: Sendable {
        var log: String
        var failed: Bool
    }

    let environment: ShellEnvironment

    func prepare(_ worktree: URL, from repository: URL, with setup: WorktreeSetup) async -> Outcome {
        var log: [String] = []
        var failed = false

        for path in setup.copyPaths {
            let source = repository.appending(path: path)
            let destination = worktree.appending(path: path)
            guard FileManager.default.fileExists(atPath: source.path) else {
                log.append("Skipped \(path): not found in the repository.")
                continue
            }
            guard !FileManager.default.fileExists(atPath: destination.path) else {
                log.append("Skipped \(path): already present.")
                continue
            }
            // `cp -c` clones on APFS (instant, shares storage); plain `cp` covers other volumes.
            var copied = await copy(["-cR", source.path, destination.path])
            if !copied {
                copied = await copy(["-R", source.path, destination.path])
            }
            if copied {
                log.append("Copied \(path)")
            } else {
                log.append("Couldn't copy \(path).")
                failed = true
            }
        }

        if let script = setup.script?.trimmingCharacters(in: .whitespacesAndNewlines), !script.isEmpty {
            log.append("$ \(script.replacingOccurrences(of: "\n", with: "\n$ "))")
            do {
                let result = try await ProcessRunner.run(
                    executable: URL(filePath: "/bin/zsh"),
                    arguments: ["-lc", script],
                    currentDirectory: worktree,
                    environment: environment.environment(),
                    timeout: .seconds(15 * 60)
                )
                let output = (result.standardOutput + result.standardError)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !output.isEmpty {
                    log.append(String(output.suffix(8000)))
                }
                if !result.succeeded {
                    log.append("The setup script failed.")
                    failed = true
                }
            } catch {
                log.append("The setup script couldn't run: \(error.localizedDescription)")
                failed = true
            }
        }
        return Outcome(log: log.joined(separator: "\n"), failed: failed)
    }

    private func copy(_ arguments: [String]) async -> Bool {
        await (try? ProcessRunner.run(executable: URL(filePath: "/bin/cp"), arguments: arguments))?.succeeded == true
    }
}
