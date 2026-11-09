import AgentKit
import Foundation

/// Reads the model catalog the Claude CLI caches under `<config>/cache/model-catalog/`.
///
/// This is an undocumented CLI cache (confirmed with claude 2.1.319), so every field is optional and
/// any surprise yields `nil`, which makes the app fall back to its built-in model list.
enum ClaudeModelCatalog {
    static func load(from directory: URL) -> ModelCatalog? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return nil }
        let masked = maskedIDs(in: directory)
        return files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "masked-ids.json" }
            .compactMap { url -> (fetchedAt: Double, catalog: ModelCatalog)? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return parse(data, masked: masked)
            }
            .max { $0.fetchedAt < $1.fetchedAt }?
            .catalog
    }

    static func parse(_ data: Data, masked: Set<String> = []) -> (fetchedAt: Double, catalog: ModelCatalog)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = root["catalog"] as? [String: Any],
              (catalog["surface"] as? String).map({ $0 == "cc" }) ?? true,
              let config = catalog["config"] as? [String: Any],
              let entries = config["models"] as? [[String: Any]] else { return nil }

        let models = entries.compactMap { entry -> ModelCatalog.Model? in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String,
                  !masked.contains(id), entry["confidential"] as? Bool != true else { return nil }
            let runtime = entry["runtime"] as? [String: Any]
            return ModelCatalog.Model(
                id: id,
                name: name,
                family: runtime?["family"] as? String,
                defaultEffort: runtime?["default_effort"] as? String,
                isFeatured: entry["section"] as? String == "main",
                effortLevels: runtime?["effort_levels"] as? [String]
            )
        }
        var aliases: [String: String] = [:]
        for (alias, target) in config["provider_alias_targets"] as? [String: [String: Any]] ?? [:] {
            if let id = target["default"] as? String {
                aliases[alias] = id
            }
        }
        guard !models.isEmpty else { return nil }
        return (root["fetchedAt"] as? Double ?? 0, ModelCatalog(models: models, aliases: aliases))
    }

    private static func maskedIDs(in directory: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: directory.appending(path: "masked-ids.json")),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ids = root["ids"] as? [String] else { return [] }
        return Set(ids)
    }
}
