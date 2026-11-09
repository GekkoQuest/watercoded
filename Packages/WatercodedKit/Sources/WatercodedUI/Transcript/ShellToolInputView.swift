import SwiftUI
import WatercodedCore
import WatercodedDesign

/// Decode the JSON envelope, preserving the command's actual newlines, quotes and indentation.
struct ShellToolInputView: View {
    let input: String

    var body: some View {
        if let value = try? JSONValue(parsing: input),
           let command = value["command"]?.string {
            if let description = value["description"]?.string, !description.isEmpty {
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            ToolCodeBlock(title: "Command", text: command)
            if let options = otherOptions(value) {
                DisclosureGroup("Other options") {
                    ToolCodeBlock(title: "Options", text: options.prettyString())
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } else if (try? JSONValue(parsing: input)) != .object([:]) {
            // Not every shell-related tool runs a command (for example, stopping a background job).
            ToolCodeBlock(title: "Input", text: input)
        }
    }

    private func otherOptions(_ value: JSONValue) -> JSONValue? {
        guard var fields = value.object else { return nil }
        fields.removeValue(forKey: "command")
        fields.removeValue(forKey: "description")
        return fields.isEmpty ? nil : .object(fields)
    }
}
