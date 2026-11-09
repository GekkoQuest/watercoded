import Foundation

/// What happened when one folder's changes were applied to another.
public enum ApplyResult: Sendable, Hashable {
    /// Applied; the paths that changed.
    case applied([String])
    /// Nothing changed between the two snapshots.
    case nothingToApply
    /// The changes don't fit the target as it is now (it changed the same lines meanwhile). Nothing was touched.
    case conflict(String)
}

extension GitClient {
    /// Applies the difference between two snapshot commits (`from` → `to`) to `folder`'s working tree.
    ///
    /// Used to bring a delegated helper's work back into its parent's folder. It applies only if the patch fits
    /// cleanly, so nothing the parent (or another helper) changed meanwhile is overwritten; the index is left alone.
    public func applyChanges(from base: String, to result: String, into folder: URL) async throws -> ApplyResult {
        let files = try await run(["diff", "--name-only", base, result], in: folder)
            .split(separator: "\n").map(String.init)
        guard !files.isEmpty else { return .nothingToApply }
        let patch = try await run(
            ["diff", "--binary", "--no-color", "--no-ext-diff", base, result],
            in: folder,
            trim: false
        )
        let patchFile = FileManager.default.temporaryDirectory.appending(path: "watercoded-\(UUID().uuidString).patch")
        try patch.write(to: patchFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: patchFile) }
        do {
            try await run(["apply", "--check", "--whitespace=nowarn", patchFile.path], in: folder)
        } catch {
            return .conflict(error.localizedDescription)
        }
        try await run(["apply", "--whitespace=nowarn", patchFile.path], in: folder)
        return .applied(files)
    }
}
