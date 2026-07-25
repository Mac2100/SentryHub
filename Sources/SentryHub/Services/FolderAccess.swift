import AppKit
import Foundation

/// Remembers the TeslaCam folder between launches.
///
/// The app is not sandboxed, but macOS still gates removable volumes and the
/// Desktop/Documents/Downloads folders behind a consent prompt. Storing a
/// bookmark keeps the granted access alive across relaunches, and re-picking
/// the folder is all it takes to re-grant it.
enum FolderAccess {
    private static let bookmarkKey = "libraryFolderBookmark"
    private static let pathKey = "libraryFolderPath"

    /// URLs currently held open with `startAccessingSecurityScopedResource`.
    private static var activeScopes: [URL] = []

    static func remember(_ url: URL) {
        UserDefaults.standard.set(url.path, forKey: pathKey)
        if let data = try? url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        } else if let data = try? url.bookmarkData() {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    static func forget() {
        releaseAll()
        UserDefaults.standard.removeObject(forKey: bookmarkKey)
        UserDefaults.standard.removeObject(forKey: pathKey)
    }

    /// Restores the previously chosen folder, starting security-scoped access
    /// when the bookmark carries it.
    static func restore() -> URL? {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if url.startAccessingSecurityScopedResource() {
                    activeScopes.append(url)
                }
                if stale { remember(url) }
                return url
            }
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return url
            }
        }
        if let path = UserDefaults.standard.string(forKey: pathKey) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    static func releaseAll() {
        for url in activeScopes {
            url.stopAccessingSecurityScopedResource()
        }
        activeScopes.removeAll()
    }

    /// Best-effort guess at where the dashcam drive is mounted, used to seed the
    /// folder picker.
    static func likelyTeslaCamRoot() -> URL? {
        let fm = FileManager.default
        let volumes = (try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: "/Volumes", isDirectory: true),
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        for volume in volumes {
            let candidate = volume.appendingPathComponent("TeslaCam", isDirectory: true)
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return volume
            }
        }
        return nil
    }

    /// Shows the folder picker. Returns the chosen folder, or `nil` if cancelled.
    @MainActor
    static func chooseFolder(startingAt suggestion: URL? = nil) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Select your TeslaCam folder, or the drive that contains it."
        panel.directoryURL = suggestion ?? likelyTeslaCamRoot()
            ?? URL(fileURLWithPath: "/Volumes", isDirectory: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        remember(url)
        return url
    }
}
