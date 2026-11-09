import AgentKit
import Foundation
import ProcessKit
import WatercodedCore

/// Asks a short-lived `codex app-server` which models the signed-in account can use.
enum CodexModelList {
    static func fetch(_ spec: ProcessSpec, timeout: Duration = .seconds(15)) async -> ModelCatalog? {
        guard let process = try? LineStreamingProcess(
            executable: spec.executable,
            arguments: spec.arguments,
            currentDirectory: spec.workingDirectory,
            environment: spec.environment
        ) else { return nil }
        defer { process.terminate(grace: .seconds(1)) }

        let messages: [JSONValue] = [
            ["id": 1, "method": "initialize", "params": CodexRequests.initialize()],
            ["method": "initialized"],
            ["id": 2, "method": "model/list", "params": [:]]
        ]
        for message in messages {
            guard (try? process.send(line: message.compactString())) != nil else { return nil }
        }
        return await withTaskGroup(of: ModelCatalog?.self) { group in
            group.addTask {
                for await line in process.standardOutputLines {
                    guard let message = try? JSONValue(parsing: line), message["id"]?.int == 2 else { continue }
                    return parse(message["result"])
                }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            defer { group.cancelAll() }
            // Whichever finishes first: the answer, or the timeout.
            guard let first = await group.next() else { return nil }
            return first
        }
    }

    /// `model/list`'s result: visible models with names and default efforts, and which is the default.
    static func parse(_ result: JSONValue?) -> ModelCatalog? {
        let entries = (result?["data"]?.array ?? []).filter { $0["hidden"]?.bool != true }
        let models = entries.compactMap { entry -> ModelCatalog.Model? in
            guard let id = entry["id"]?.string ?? entry["model"]?.string else { return nil }
            return ModelCatalog.Model(
                id: id,
                name: entry["displayName"]?.string ?? id,
                family: nil,
                defaultEffort: entry["defaultReasoningEffort"]?.string,
                isFeatured: true,
                effortLevels: entry["supportedReasoningEfforts"]?.array?.compactMap { $0["reasoningEffort"]?.string }
            )
        }
        guard !models.isEmpty else { return nil }
        let defaultID = entries.first { $0["isDefault"]?.bool == true }.flatMap { $0["id"]?.string }
        return ModelCatalog(models: models, aliases: [:], defaultModelID: defaultID)
    }
}
