import Foundation

/// The environment agents and git should run with.
///
/// Apps launched from Finder or the Dock get a minimal `PATH` (`/usr/bin:/bin:…`), so CLIs
/// installed by Homebrew, npm, `~/.local/bin` etc. are invisible. We ask the user's login shell
/// for its `PATH` once, merge in well-known install locations, and cache the result.
public actor ShellEnvironment {
    public static let shared = ShellEnvironment()

    private var cached: [String: String]?

    /// Well-known install locations, appended if the login shell didn't mention them.
    static let fallbackDirectories = [
        "~/.local/bin", "~/.bun/bin", "~/.npm-global/bin", "~/.cargo/bin",
        "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    public init() {}

    /// The process environment with a login-shell-quality `PATH`.
    public func environment() async -> [String: String] {
        if let cached {
            return cached
        }
        var environment = ProcessInfo.processInfo.environment
        let loginPath = await Self.loginShellPath()
        environment["PATH"] = Self.mergedPath(primary: loginPath, current: environment["PATH"])
        cached = environment
        return environment
    }

    /// Resolves an executable name to a full path using ``environment()``.
    public func locate(_ name: String) async -> URL? {
        if name.hasPrefix("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? URL(filePath: name) : nil
        }
        let path = await environment()["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            let candidate = (String(directory) as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(filePath: candidate)
            }
        }
        return nil
    }

    /// Clears the cache, e.g. after the user installs a CLI.
    public func invalidate() {
        cached = nil
    }

    // MARK: Internals

    static func mergedPath(primary: String?, current: String?) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        var ordered: [String] = []
        let sources = [primary ?? "", current ?? "", fallbackDirectories.joined(separator: ":")]
        for source in sources {
            for raw in source.split(separator: ":") {
                let entry = raw.hasPrefix("~") ? home + raw.dropFirst() : String(raw)
                if !entry.isEmpty, seen.insert(entry).inserted {
                    ordered.append(entry)
                }
            }
        }
        return ordered.joined(separator: ":")
    }

    private static func loginShellPath() async -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        // -l: login shell (reads .zprofile etc.), -i is avoided because it can prompt or print banners.
        let marker = "__WATERCODED_PATH__"
        let result = try? await ProcessRunner.run(
            executable: URL(filePath: shell),
            arguments: ["-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""],
            timeout: .seconds(4)
        )
        guard let output = result?.standardOutput,
              let start = output.range(of: marker),
              let end = output.range(of: marker, range: start.upperBound ..< output.endIndex)
        else { return nil }
        return String(output[start.upperBound ..< end.lowerBound])
    }
}
