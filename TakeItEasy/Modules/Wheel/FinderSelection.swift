import Foundation

nonisolated struct FinderSelection: Sendable {
    /// Folder of the front Finder window (or the Desktop): where "Nuovo file" goes.
    let folder: URL
    let items: [URL]

    private static let source = """
    tell application "Finder"
        set out to {POSIX path of (insertion location as alias)}
        repeat with item_ in (get selection)
            set end of out to POSIX path of (item_ as alias)
        end repeat
        return out
    end tell
    """

    struct ScriptError: LocalizedError {
        let errorDescription: String?
    }

    /// Reads the current Finder selection via Apple Events. NSAppleScript blocks until Finder
    /// replies, so it runs off the main thread.
    static func read() async throws -> FinderSelection {
        try await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error) else {
                let message = error?[NSAppleScript.errorMessage] as? String
                throw ScriptError(errorDescription: message ?? String(localized: "Finder non ha risposto"))
            }
            let paths = (0..<result.numberOfItems).compactMap { result.atIndex($0 + 1)?.stringValue }
            guard let folder = paths.first else { throw ScriptError(errorDescription: String(localized: "Finder non ha risposto")) }
            return FinderSelection(folder: URL(fileURLWithPath: folder, isDirectory: true),
                                   items: paths.dropFirst().map { URL(fileURLWithPath: $0) })
        }.value
    }
}
