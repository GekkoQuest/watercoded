import Foundation

/// A local document and an optional source location, separate from the URL used to open the file.
struct LocalFileReference: Identifiable, Hashable {
    let url: URL
    var line: Int?
    var column: Int?
    var id: String {
        "\(url.absoluteString):\(line ?? 0):\(column ?? 0)"
    }
}

enum TranscriptLink: Equatable {
    case file(LocalFileReference)
    case external(URL)
    case unsupported

    /// Markdown paths are often scheme-less URLs. Passing those straight to Launch Services causes
    /// Finder's -50 error. Resolve them against the session folder and remove source-location suffixes.
    static func resolve(_ destination: URL, relativeTo directory: URL) -> Self {
        let scheme = destination.scheme?.lowercased()
        if ["http", "https", "mailto"].contains(scheme) {
            return .external(destination)
        }
        let raw = destination.relativeString
        let location = /:([1-9][0-9]*)(?::([1-9][0-9]*))?$/
        let hasLocation = raw.firstMatch(of: location) != nil
        guard scheme == nil || scheme == "file" || (hasLocation && scheme?.contains(".") == true),
              destination.host() == nil || destination.host() == "" || destination.host() == "localhost" else {
            return .unsupported
        }
        var path = destination.isFileURL || scheme == nil ? destination.path(percentEncoded: false)
            : raw.removingPercentEncoding ?? raw
        var line: Int?
        var column: Int?
        if let fragment = destination.fragment(),
           let match = fragment.firstMatch(of: /^L([1-9][0-9]*)(?:C([1-9][0-9]*))?(?:-L?[0-9]+)?$/) {
            line = Int(match.1)
            column = match.2.flatMap { Int($0) }
        }
        // An actual colon-containing filename takes precedence over the source-location convention.
        let exact = fileURL(path, relativeTo: directory)
        if !FileManager.default.fileExists(atPath: exact.path), let match = path.firstMatch(of: location) {
            line = Int(match.1)
            column = match.2.flatMap { Int($0) }
            path = String(path[..<match.range.lowerBound])
        }
        guard !path.isEmpty else { return .unsupported }
        return .file(LocalFileReference(url: fileURL(path, relativeTo: directory), line: line, column: column))
    }

    private static func fileURL(_ path: String, relativeTo directory: URL) -> URL {
        let base = URL(filePath: directory.path, directoryHint: .isDirectory)
        return URL(filePath: (path as NSString).expandingTildeInPath, relativeTo: base).standardizedFileURL
    }
}
