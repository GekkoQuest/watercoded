import AgentKit
import AppKit
import Meniscus
import Orchestrator
import SwiftUI
import UniformTypeIdentifiers
import WatercodedCore
import WatercodedDesign

/// Message input. Return sends, ⌥Return inserts a newline, ⌘. interrupts.
/// Paste, drop or attach images; type `@` to mention a file and `/` for the agent's commands.
struct ComposerView: View {
    @Bindable var controller: CurrentController
    @Environment(Workspace.self) private var workspace
    @Environment(WaterEngine.self) private var engine
    @FocusState private var isFocused: Bool
    @State private var files: [String] = []
    @State private var isDropTargeted = false
    @State private var isSubmitting = false

    /// The field and its buttons are concentric: every button sits `inset` from the field's edge,
    /// and the field's corner radius is the buttons' radius plus `inset`.
    private let buttonSize: CGFloat = 30
    private let inset: CGFloat = 6
    private let buttonRadius: CGFloat = 4
    private var cornerRadius: CGFloat {
        buttonRadius + inset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.small) {
            if !suggestions.isEmpty {
                SuggestionList(suggestions: suggestions, accept: accept)
            }
            VStack(alignment: .leading, spacing: Spacing.small) {
                if !controller.draftImages.isEmpty {
                    AttachmentStrip(images: $controller.draftImages)
                }
                inputRow
            }
            .padding(inset)
            .background {
                ComposerVessel(
                    vessel: engine.vessel(for: controller),
                    tint: controller.waterTint,
                    cornerRadius: cornerRadius
                )
                .accessibilityElement()
                .accessibilityLabel("Context \(Int(controller.current.usage.contextFraction * 100)) percent used")
            }
            .overlay {
                if isDropTargeted {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
            .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted, perform: acceptDrop)
        }
        .background(ImagePasteMonitor(isActive: isFocused && acceptsImages) { controller.draftImages += $0 })
        .onAppear { isFocused = true }
        .task(id: controller.id) { files = await workspace.files(for: controller.id) }
        .onChange(of: controller.draft) { old, new in
            // Text added from elsewhere (e.g. "Ask about this change") brings focus here.
            if new.count > old.count + 1 {
                isFocused = true
            }
        }
    }

    private var inputRow: some View {
        HStack(alignment: .bottom, spacing: Spacing.small) {
            if acceptsImages {
                ComposerButton(title: "Attach Images", systemImage: "paperclip", size: buttonSize, isProminent: false) {
                    chooseImages()
                }
            }
            TextField(placeholder, text: $controller.draft, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1 ... Metrics.composerMaxLines)
                .focused($isFocused)
                .onSubmit(send)
                .onKeyPress(.tab) {
                    guard let first = suggestions.first else { return .ignored }
                    accept(first)
                    return .handled
                }
                .frame(minHeight: buttonSize)
                .padding(.leading, acceptsImages ? 0 : Spacing.medium)
                .accessibilityLabel("Message")

            if controller.isTurnActive, controller.capabilities.contains(.interrupt) {
                ComposerButton(
                    title: "Interrupt (⌘.)",
                    systemImage: "stop.fill",
                    size: buttonSize,
                    isProminent: false
                ) {
                    Task { await controller.interrupt() }
                }
                .keyboardShortcut(".", modifiers: .command)
            }
            ComposerButton(
                title: "Send (↩)",
                systemImage: "arrow.up",
                size: buttonSize,
                isProminent: canSend,
                action: send
            )
            .disabled(!canSend)
        }
    }

    // MARK: Sending

    private var acceptsImages: Bool {
        controller.capabilities.contains(.images)
    }

    private var canSend: Bool {
        let hasContent = !controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !controller.draftImages.isEmpty
        let canQueue = !controller.isTurnActive || controller.capabilities.contains(.queueing)
            || controller.isLocalPromptCommand(controller.draft)
        return hasContent && canQueue && !isSubmitting && controller.current.status != .settled
    }

    private var placeholder: String {
        if controller.current.status == .settled {
            return "This session is archived. Reopen it to continue."
        }
        return controller.isTurnActive
            ? "Agent working… (/ for commands)"
            : "Reply to the agent… (@ for files, / for commands)"
    }

    private func send() {
        guard canSend else { return }
        let text = controller.draft
        let images = controller.draftImages
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            if await controller.submitPrompt(text, images: images) {
                if controller.draft == text {
                    controller.draft = ""
                }
                if controller.draftImages == images {
                    controller.draftImages = []
                }
            }
        }
    }

    // MARK: Completions

    private var suggestions: [Suggestion] {
        Suggestion.make(for: controller.draft, files: files, commands: controller.promptCommands)
    }

    private func accept(_ suggestion: Suggestion) {
        controller.draft = suggestion.apply(to: controller.draft)
        isFocused = true
    }

    // MARK: Images

    private func chooseImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        controller.draftImages += panel.urls.compactMap { ImageAttachment(fileURL: $0) }
    }

    private func acceptDrop(_ providers: [NSItemProvider]) -> Bool {
        guard acceptsImages else { return false }
        for provider in providers {
            _ = provider.loadDataRepresentation(for: .image) { data, _ in
                guard let data, let image = NSImage(data: data),
                      let attachment = ImageAttachment(image: image) else { return }
                Task { @MainActor in controller.draftImages.append(attachment) }
            }
        }
        return true
    }
}

/// A completion for the word being typed: a file after `@`, or a command after a leading `/`.
struct Suggestion: Identifiable, Hashable {
    enum Kind: Hashable {
        case file
        case command(summary: String, argumentHint: String?)
    }

    let kind: Kind
    let value: String
    var id: String {
        value
    }

    static func make(for draft: String, files: [String], commands: [SlashCommand]) -> [Suggestion] {
        if draft.hasPrefix("/"), !draft.contains(where: \.isWhitespace) {
            let typed = draft.dropFirst().lowercased()
            return commands.filter { typed.isEmpty || $0.name.lowercased().hasPrefix(typed) }
                .map { Suggestion(kind: .command(summary: $0.summary, argumentHint: $0.argumentHint), value: $0.name) }
        }
        guard let token = draft.split(separator: " ", omittingEmptySubsequences: false).last,
              token.hasPrefix("@"), !draft.hasSuffix(" ") else { return [] }
        let typed = token.dropFirst().lowercased()
        let matches = typed.isEmpty ? Array(files.prefix(8)) : files.filter { $0.lowercased().contains(typed) }
            .sorted { lhs, rhs in
                // Prefer matches in the file name over matches in the directory.
                let left = (lhs as NSString).lastPathComponent.lowercased().contains(typed)
                let right = (rhs as NSString).lastPathComponent.lowercased().contains(typed)
                return left != right ? left : lhs.count < rhs.count
            }
        return matches.prefix(8).map { Suggestion(kind: .file, value: $0) }
    }

    func apply(to draft: String) -> String {
        switch kind {
        case .command:
            return "/\(value) "
        case .file:
            guard let at = draft.range(of: "@", options: .backwards) else { return draft }
            return draft[..<at.lowerBound] + "@\(value) "
        }
    }
}

private struct SuggestionList: View {
    let suggestions: [Suggestion]
    let accept: (Suggestion) -> Void

    var body: some View {
        ScrollView {
            rows
        }
        .frame(height: CGFloat(min(suggestions.count, Metrics.suggestionVisibleRows)) * Metrics.suggestionRowHeight)
        .font(.callout)
        .padding(.vertical, Spacing.xSmall)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: Radius.medium, style: .continuous))
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    accept(suggestion)
                } label: {
                    HStack(spacing: Spacing.small) {
                        switch suggestion.kind {
                        case .file:
                            Image(systemName: "doc").foregroundStyle(.secondary)
                            Text(suggestion.value).lineLimit(1).truncationMode(.head)
                        case let .command(summary, argumentHint):
                            Text("/\(suggestion.value)").fontWeight(.medium)
                            if let argumentHint {
                                Text(argumentHint).foregroundStyle(.tertiary).lineLimit(1)
                            }
                            Text(summary).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if index == 0 {
                            Text("Tab").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, Spacing.medium)
                    .frame(height: Metrics.suggestionRowHeight)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct AttachmentStrip: View {
    @Binding var images: [ImageAttachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Spacing.small) {
                ForEach(images) { attachment in
                    if let image = NSImage(data: attachment.data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                            .overlay(alignment: .topTrailing) {
                                Button("Remove", systemImage: "xmark.circle.fill") {
                                    images.removeAll { $0.id == attachment.id }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .foregroundStyle(.white, .black.opacity(0.6))
                                .padding(2)
                            }
                    }
                }
            }
            .padding(.leading, Spacing.xSmall)
        }
        .scrollIndicators(.never)
    }
}

/// Catches ⌘V while the composer is focused and the clipboard holds an image (text fields
/// ignore pasted images), turning it into an attachment.
private struct ImagePasteMonitor: NSViewRepresentable {
    let isActive: Bool
    let onImages: ([ImageAttachment]) -> Void

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.onImages = onImages
        context.coordinator.setActive(isActive)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.setActive(false)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var onImages: ([ImageAttachment]) -> Void = { _ in }
        private var monitor: Any?

        func setActive(_ active: Bool) {
            if active, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                          event.charactersIgnoringModifiers == "v" else { return event }
                    let pasteboard = NSPasteboard.general
                    guard pasteboard.string(forType: .string) == nil,
                          let images = pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage], !images.isEmpty
                    else { return event }
                    self?.onImages(images.compactMap { ImageAttachment(image: $0) })
                    return nil
                }
            } else if !active, let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}

nonisolated extension ImageAttachment {
    /// Encodes an image for the agent: PNG, or JPEG when PNG would be too large to send.
    init?(image: NSImage, filename: String? = nil) {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        let maximum = 3_500_000
        if let png = bitmap.representation(using: .png, properties: [:]), png.count <= maximum {
            self.init(mediaType: "image/png", data: png, filename: filename)
        } else if let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]),
                  jpeg.count <= maximum {
            self.init(mediaType: "image/jpeg", data: jpeg, filename: filename)
        } else {
            return nil
        }
    }

    init?(fileURL: URL) {
        guard let image = NSImage(contentsOf: fileURL) else { return nil }
        self.init(image: image, filename: fileURL.lastPathComponent)
    }
}

/// A solid circular button that sits inside the composer's glass (glass-on-glass looks muddy).
private struct ComposerButton: View {
    let title: String
    let systemImage: String
    let size: CGFloat
    let isProminent: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(isProminent ? Color.white : Color.secondary)
                .frame(width: size, height: size)
                .background(
                    isProminent ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: RoundedRectangle(cornerRadius: 4, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .animation(Motion.quick, value: isProminent)
    }
}
