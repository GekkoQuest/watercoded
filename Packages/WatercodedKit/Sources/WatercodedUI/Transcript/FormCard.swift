import AppKit
import Orchestrator
import SwiftUI
import WatercodedCore
import WatercodedDesign

/// An MCP server asking for input: a short form, or a link to open. Submitting sends the values to the
/// tool that asked; Decline lets the tool fail cleanly.
struct FormCard: View {
    let record: FormRecord
    let controller: CurrentController
    @State private var texts: [String: String] = [:]
    @State private var flags: [String: Bool] = [:]
    @State private var choices: [String: String] = [:]
    @State private var selections: [String: Set<String>] = [:]
    @State private var openedLink = false
    @State private var linkFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            VStack(alignment: .leading, spacing: Spacing.xxSmall) {
                Label(record.serverName.map { "MCP · \($0)" } ?? "MCP", systemImage: "puzzlepiece.extension")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(record.message).font(.headline).fixedSize(horizontal: false, vertical: true)
            }
            switch record.status {
            case .pending where isPending:
                if let url = record.url {
                    linkForm(url)
                } else {
                    fieldsForm
                }
            case .pending:
                Text("No longer waiting for an answer.").foregroundStyle(.secondary)
            case .submitted:
                summary
            case .declined:
                Label("Declined", systemImage: "xmark.circle").foregroundStyle(.secondary)
            }
        }
        .padding(Spacing.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(.purple.opacity(0.1)), in: RoundedRectangle(cornerRadius: Radius.large))
        .onAppear(perform: applyDefaults)
    }

    private var isPending: Bool {
        controller.pendingForm?.requestID == record.requestID
    }

    // MARK: Link mode

    private func linkForm(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            Text(url.host() ?? url.absoluteString).font(.callout.monospaced()).foregroundStyle(.secondary)
            HStack {
                Button("Open Link", systemImage: "arrow.up.right.square") {
                    openedLink = NSWorkspace.shared.open(url)
                    linkFailed = !openedLink
                }
                .buttonStyle(.glassProminent)
                Button("Done") { Task { await controller.submitForm([:], summary: ["Link": "Opened"]) } }
                    .disabled(!openedLink)
                    .help("Continue once you've finished in the browser")
                Spacer()
                Button("Decline") { Task { await controller.declineForm() } }
            }
            if linkFailed {
                Text("Couldn't open this link. Check the address and try again.").font(.callout).foregroundStyle(.red)
            }
        }
    }

    // MARK: Fields

    private var fieldsForm: some View {
        VStack(alignment: .leading, spacing: Spacing.medium) {
            ForEach(record.fields) { field in
                VStack(alignment: .leading, spacing: Spacing.xSmall) {
                    if case .boolean = field.kind {
                        Toggle(field.title, isOn: flag(field.key))
                    } else {
                        Text(field.isRequired ? field.title : "\(field.title) (optional)").fontWeight(.medium)
                        control(for: field)
                    }
                    if let detail = field.detail {
                        Text(detail).font(.caption).foregroundStyle(.secondary)
                    }
                    if let problem = problem(with: field) {
                        Text(problem).font(.caption).foregroundStyle(.red)
                    }
                }
            }
            HStack {
                Button("Submit") { submit() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(record.fields.contains { isMissing($0) || problem(with: $0) != nil })
                Spacer()
                Button("Decline") { Task { await controller.declineForm() } }
            }
        }
    }

    @ViewBuilder private func control(for field: FormRecord.Field) -> some View {
        switch field.kind {
        case let .text(format, _, _):
            TextField(field.title, text: text(field.key), prompt: Text(Self.placeholder(format)))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        case .number:
            TextField(field.title, text: text(field.key), prompt: Text("Number"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: 160)
        case .boolean:
            EmptyView()
        case let .choice(options):
            Picker(field.title, selection: choice(field.key)) {
                Text("Choose…").tag("")
                ForEach(options) { Text($0.title).tag($0.value) }
            }
            .labelsHidden()
            .fixedSize()
        case let .multipleChoice(options, _, _):
            ForEach(options) { option in
                Toggle(option.title, isOn: Binding(
                    get: { selections[field.key]?.contains(option.value) == true },
                    set: { isOn in
                        if isOn {
                            selections[field.key, default: []].insert(option.value)
                        } else {
                            selections[field.key]?.remove(option.value)
                        }
                    }
                ))
            }
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Spacing.xxSmall) {
            Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            ForEach(record.fields.filter { record.summary?[$0.title] != nil }) { field in
                Text("\(field.title): \(record.summary?[field.title] ?? "")").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Values

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { texts[key] ?? "" }, set: { texts[key] = $0 })
    }

    private func flag(_ key: String) -> Binding<Bool> {
        Binding(get: { flags[key] ?? false }, set: { flags[key] = $0 })
    }

    private func choice(_ key: String) -> Binding<String> {
        Binding(get: { choices[key] ?? "" }, set: { choices[key] = $0 })
    }

    private func applyDefaults() {
        for field in record.fields {
            guard let value = field.defaultValue else { continue }
            switch field.kind {
            case .text: texts[field.key] = value.string
            case .number: texts[field.key] = value.double.map { $0.formatted(.number.grouping(.never)) }
            case .boolean: flags[field.key] = value.bool
            case .choice: choices[field.key] = value.string
            case .multipleChoice: selections[field.key] = Set(value.array?.compactMap(\.string) ?? [])
            }
        }
    }

    /// Why a field can't be submitted yet, or `nil` when it's fine.
    private func problem(with field: FormRecord.Field) -> String? {
        let text = (texts[field.key] ?? "").trimmingCharacters(in: .whitespaces)
        switch field.kind {
        case let .text(format, minLength, maxLength):
            if text.isEmpty {
                return nil // required-but-empty only blocks Submit (see isMissing), without an error message
            }
            if let minLength, text.count < minLength {
                return "At least \(minLength) characters."
            }
            if let maxLength, text.count > maxLength {
                return "At most \(maxLength) characters."
            }
            return Self.formatProblem(text, format: format)
        case let .number(integer, minimum, maximum):
            guard !text.isEmpty else { return nil }
            guard let number = Double(text), !integer || number == number.rounded() else {
                return integer ? "Enter a whole number." : "Enter a number."
            }
            if let minimum, number < minimum {
                return "At least \(minimum.formatted())."
            }
            if let maximum, number > maximum {
                return "At most \(maximum.formatted())."
            }
            return nil
        case let .multipleChoice(_, minItems, maxItems):
            let count = selections[field.key]?.count ?? 0
            if let minItems, count < minItems, count > 0 || field.isRequired {
                return "Choose at least \(minItems)."
            }
            if let maxItems, count > maxItems {
                return "Choose at most \(maxItems)."
            }
            return nil
        case .boolean, .choice:
            return nil
        }
    }

    private func isMissing(_ field: FormRecord.Field) -> Bool {
        guard field.isRequired else { return false }
        switch field.kind {
        case .text, .number: return (texts[field.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
        case .choice: return (choices[field.key] ?? "").isEmpty
        case .multipleChoice: return selections[field.key]?.isEmpty ?? true
        case .boolean: return false
        }
    }

    private func submit() {
        guard !record.fields.contains(where: { isMissing($0) || problem(with: $0) != nil }) else { return }
        var values: [String: JSONValue] = [:]
        var shown: [String: String] = [:]
        for field in record.fields {
            switch field.kind {
            case .text:
                let text = (texts[field.key] ?? "").trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                values[field.key] = .string(text)
                shown[field.title] = text
            case .number:
                guard let number = Double((texts[field.key] ?? "").trimmingCharacters(in: .whitespaces))
                else { continue }
                values[field.key] = .number(number)
                shown[field.title] = number.formatted()
            case .boolean:
                let value = flags[field.key] ?? false
                values[field.key] = .bool(value)
                shown[field.title] = value ? "Yes" : "No"
            case let .choice(options):
                guard let value = choices[field.key], !value.isEmpty else { continue }
                values[field.key] = .string(value)
                shown[field.title] = options.first { $0.value == value }?.title ?? value
            case let .multipleChoice(options, _, _):
                let chosen = options.filter { selections[field.key]?.contains($0.value) == true }
                guard !chosen.isEmpty || field.isRequired else { continue }
                values[field.key] = .array(chosen.map { .string($0.value) })
                shown[field.title] = chosen.map(\.title).joined(separator: ", ")
            }
        }
        Task { await controller.submitForm(values, summary: shown) }
    }

    private static func placeholder(_ format: String?) -> String {
        switch format {
        case "email": "name@example.com"
        case "uri": "https://"
        case "date": "YYYY-MM-DD"
        case "date-time": "YYYY-MM-DDTHH:MM:SSZ"
        default: ""
        }
    }

    private static func formatProblem(_ text: String, format: String?) -> String? {
        switch format {
        case "email":
            text.contains("@") && text.contains(".") ? nil : "Enter an email address."
        case "uri":
            URL(string: text)?.scheme == nil ? "Enter a full URL, including https://." : nil
        case "date":
            (try? Date(text, strategy: .iso8601.year().month().day())) == nil ? "Use YYYY-MM-DD." : nil
        case "date-time":
            (try? Date(text, strategy: .iso8601)) == nil ? "Use a date and time like 2026-11-09T14:30:00Z." : nil
        default:
            nil
        }
    }
}
