import AgentKit
import Foundation
import GitKit
import WatercodedCore

/// Export, search, re-running and importing.
extension Workspace {
    // MARK: Export

    /// A Markdown write-up of a Current: what was asked, the outcome, files changed and checks.
    /// Without the transcript it doubles as a pull request description.
    public func markdown(for id: CurrentID, includeTranscript: Bool = true) async -> String {
        guard let controller = controller(id) else { return "" }
        let current = controller.current
        var lines = ["# \(current.title)", ""]
        if let summary = current.summary {
            lines += [summary, ""]
        }
        let prompts = controller.transcript.compactMap {
            if case let .user(text) = $0.content {
                text
            } else {
                nil
            }
        }
        if let first = prompts.first {
            lines += ["## Request", "", first.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n"), ""]
        }
        if let diff = try? await diff(for: id), !diff.isEmpty {
            lines += ["## Changes", "", "\(diff.files.count) files, +\(diff.additions) −\(diff.deletions)", ""]
            lines += diff.files.map { "- `\($0.path)` (+\($0.additions) −\($0.deletions))" } + [""]
        }
        if let check = current.lastCheck {
            lines += ["## Verification", "", "\(check.passed ? "✅" : "❌") `\(check.command)`", ""]
        } else {
            lines += ["## Verification", "", "No tests or builds were run by the agent.", ""]
        }
        if includeTranscript {
            lines += ["## Transcript", ""]
            for item in controller.transcript {
                switch item.content {
                case let .user(text): lines += ["**You:** \(text)", ""]
                case let .assistant(text): lines += [text, ""]
                case let .toolCall(record)
                    where record.parentCallID == nil: lines += ["- 🔧 \(record.name): `\(record.summary)`"]
                case let .plan(record): lines += ["**Plan:**", "", record.markdown, ""]
                case let .notice(notice): lines += ["_\(notice.text)_", ""]
                default: continue
                }
            }
        }
        lines
            .append(
                "_Made with [Watercoded](https://github.com/GekkoQuest/watercoded) · \(current.providerID.rawValue)\(current.model.map { " · \($0)" } ?? "")_"
            )
        return lines.joined(separator: "\n")
    }

    // MARK: Files

    /// Files in a Current's channel, for `@` mentions.
    public func files(for id: CurrentID) async -> [String] {
        guard let channel = controller(id)?.current.channel else { return [] }
        return await (try? git.listFiles(in: channel.url)) ?? []
    }

    // MARK: Search

    /// Whether to find sessions by name or search their contents as well.
    public enum SearchScope: String, CaseIterable, Sendable {
        case sessionNames
        case allContent
    }

    public struct SearchHit: Identifiable, Hashable {
        public let currentID: CurrentID
        public let itemID: UUID?
        public let snippet: String
        public var id: String {
            "\(currentID)-\(itemID?.uuidString ?? "title")"
        }
    }

    /// Case-insensitive search across every Current's titles, messages and tool calls.
    public func search(_ query: String, scope: SearchScope = .allContent, limit: Int = 200) -> [SearchHit] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2, limit > 0 else { return [] }
        var hits: [SearchHit] = []
        for controller in currents {
            if let range = controller.current.title.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) {
                hits.append(SearchHit(
                    currentID: controller.id,
                    itemID: nil,
                    snippet: Self.snippet(controller.current.title, around: range)
                ))
                if hits.count >= limit {
                    return hits
                }
            }
            guard scope == .allContent else { continue }
            for item in controller.transcript {
                let text: String? = switch item.content {
                case let .user(text), let .assistant(text): text
                case let .toolCall(record): "\(record.name) \(record.summary)"
                case let .plan(record): record.markdown
                case let .notice(notice): notice.text
                default: nil
                }
                guard let text,
                      let range = text.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else {
                    continue
                }
                hits.append(SearchHit(
                    currentID: controller.id,
                    itemID: item.id,
                    snippet: Self.snippet(text, around: range)
                ))
                if hits.count >= limit {
                    return hits
                }
            }
        }
        return hits
    }

    private static func snippet(_ text: String, around range: Range<String.Index>) -> String {
        let start = text.index(range.lowerBound, offsetBy: -40, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 80, limitedBy: text.endIndex) ?? text.endIndex
        let body = text[start ..< end].replacingOccurrences(of: "\n", with: " ")
        return (start > text.startIndex ? "…" : "") + body + (end < text.endIndex ? "…" : "")
    }

    // MARK: Re-run

    /// Starts a new Current with the same first prompt on another provider or model, in its own
    /// worktree, so the two results can be compared.
    public func rerun(_ id: CurrentID, providerID: ProviderID, model: String?) async throws -> CurrentController {
        guard let original = controller(id),
              let message = original.transcript.first(where: {
                  if case .user = $0.content {
                      true
                  } else {
                      false
                  }
              }),
              case let .user(prompt) = message.content
        else { throw WorkspaceError.poolNotFound }
        let label = model ?? registry.provider(for: providerID)?.descriptor.displayName ?? providerID.rawValue
        return try await startCurrent(NewCurrentRequest(
            poolID: original.current.poolID,
            prompt: prompt,
            images: Self.images(before: message.id, in: original.transcript),
            title: "\(original.current.title) (\(label))",
            providerID: providerID,
            model: model,
            effort: original.current.effort,
            permissionMode: original.current.permissionMode,
            isolation: .worktree
        ))
    }

    // MARK: Import

    public struct ImportCandidate: Identifiable, Hashable {
        public let providerID: ProviderID
        public let session: ImportableSession
        public var id: String {
            session.id
        }
    }

    /// Sessions agents ran in this pool outside Watercoded that haven't been imported yet.
    public func importCandidates(for poolID: PoolID) -> [ImportCandidate] {
        guard let pool = pool(poolID) else { return [] }
        let known = Set(currents.compactMap(\.current.providerSessionID))
        return registry.importers.flatMap { importer in
            importer.importableSessions(in: pool.rootURL)
                .filter { !known.contains($0.id) }
                .map { ImportCandidate(providerID: importer.descriptor.id, session: $0) }
        }
        .sorted { $0.session.updatedAt > $1.session.updatedAt }
    }

    /// Brings an outside session in as a Current in the pool's checkout; the next message resumes it.
    @discardableResult
    public func importSession(_ candidate: ImportCandidate, into poolID: PoolID) async throws -> CurrentController {
        guard let pool = pool(poolID),
              let importer = registry.importers.first(where: { $0.descriptor.id == candidate.providerID })
        else { throw WorkspaceError.poolNotFound }
        let transcript = try importer.transcript(ofSession: candidate.session.id, in: pool.rootURL)
        let channel = try await worktrees.makeCheckoutChannel(for: pool)
        var current = Current(
            poolID: pool.id,
            title: candidate.session.title,
            providerID: candidate.providerID,
            channel: channel,
            providerSessionID: candidate.session.id,
            status: .ashore,
            createdAt: candidate.session.updatedAt,
            updatedAt: candidate.session.updatedAt
        )
        current.titleSource = .prompt
        current.lastTurnEndedAt = candidate.session.updatedAt
        current.lastViewedAt = .now
        try await repository.saveCurrent(current)
        try await repository.saveTranscript(transcript, for: current.id)
        return adopt(current, transcript: transcript)
    }
}
