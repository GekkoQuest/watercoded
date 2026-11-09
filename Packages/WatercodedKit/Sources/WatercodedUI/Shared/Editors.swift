import AppKit
import SwiftUI

/// An app that can open files or folders, detected by bundle identifier.
struct Editor: Identifiable, Hashable {
    let id: String
    let name: String

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    var icon: NSImage? {
        appURL.map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Popular editors, in menu order. Only installed ones are shown.
    static let known = [
        Editor(id: "com.apple.dt.Xcode", name: "Xcode"),
        Editor(id: "com.microsoft.VSCode", name: "Visual Studio Code"),
        Editor(id: "com.todesktop.230313mzl4w4u92", name: "Cursor"),
        Editor(id: "dev.zed.Zed", name: "Zed"),
        Editor(id: "com.sublimetext.4", name: "Sublime Text"),
        Editor(id: "com.panic.Nova", name: "Nova"),
        Editor(id: "com.jetbrains.fleet", name: "Fleet"),
        Editor(id: "com.apple.Terminal", name: "Terminal"),
        Editor(id: "com.mitchellh.ghostty", name: "Ghostty"),
        Editor(id: "com.googlecode.iterm2", name: "iTerm"),
        Editor(id: "dev.warp.Warp-Stable", name: "Warp")
    ]

    static var installed: [Editor] {
        known.filter { $0.appURL != nil }
    }

    func open(_ url: URL) {
        guard let appURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }
}

/// Menu items to open `url` in Finder or any installed editor or terminal.
struct OpenInMenuItems: View {
    let url: URL

    var body: some View {
        Button("Show in Finder", systemImage: "folder") {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        Divider()
        ForEach(Editor.installed) { editor in
            Button {
                editor.open(url)
            } label: {
                if let icon = editor.icon {
                    Label { Text(editor.name) } icon: { Image(nsImage: icon) }
                } else {
                    Text(editor.name)
                }
            }
        }
    }
}
