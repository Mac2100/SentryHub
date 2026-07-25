import AppKit
import Combine
import Foundation

/// Notices the dashcam drive being plugged in and pulled out.
///
/// Plugging the drive in is the moment the user wants the library, so waiting
/// for them to go and find the folder is a step that shouldn't exist. Pulling it
/// out matters just as much now that clips can be saved locally: the drive's
/// clips have to leave the gallery with it, while the saved ones stay.
@MainActor
final class DriveWatcher: ObservableObject {
    static let shared = DriveWatcher()

    /// A mounted volume holding a `TeslaCam` folder, if one is attached.
    @Published private(set) var detectedDrive: URL?

    let driveMounted = PassthroughSubject<URL, Never>()
    let driveUnmounted = PassthroughSubject<URL, Never>()

    private var observers: [NSObjectProtocol] = []
    private var isWatching = false

    private init() {}

    // MARK: - Watching

    func start() {
        guard !isWatching else { return }
        isWatching = true

        let center = NSWorkspace.shared.notificationCenter
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didMountNotification, object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    guard let url = Self.volumeURL(from: note) else { return }
                    DriveWatcher.shared.volumeMounted(url)
                }
            }
        )
        observers.append(
            center.addObserver(
                forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main
            ) { note in
                MainActor.assumeIsolated {
                    guard let url = Self.volumeURL(from: note) else { return }
                    DriveWatcher.shared.volumeUnmounted(url)
                }
            }
        )

        detectedDrive = FolderAccess.likelyTeslaCamRoot()
    }

    private static func volumeURL(from note: Notification) -> URL? {
        note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
    }

    private func volumeMounted(_ url: URL) {
        // The volume isn't always readable the instant the notification lands,
        // so give a slow drive a couple of chances before writing it off.
        Task { [weak self] in
            for delay in [0, 1, 3] as [UInt64] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                }
                guard let self else { return }
                guard FileManager.default.fileExists(atPath: url.path) else { return }
                if Self.holdsTeslaCam(url) {
                    self.detectedDrive = url
                    self.driveMounted.send(url)
                    return
                }
            }
        }
    }

    private func volumeUnmounted(_ url: URL) {
        if let detected = detectedDrive, detected == url || detected.path.hasPrefix(url.path) {
            detectedDrive = FolderAccess.likelyTeslaCamRoot()
        }
        driveUnmounted.send(url)
    }

    /// True when the volume looks like a dashcam drive.
    static func holdsTeslaCam(_ volume: URL) -> Bool {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        let candidate = volume.appendingPathComponent("TeslaCam", isDirectory: true)
        if fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
           isDirectory.boolValue {
            return true
        }
        // Some people copy the three folders to the root of a plain USB stick.
        return ClipCategory.allCases.contains { category in
            let folder = volume.appendingPathComponent(category.folderName, isDirectory: true)
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: folder.path, isDirectory: &isDir) && isDir.boolValue
        }
    }

    /// Volume name for the detected drive, for showing on screen.
    var detectedDriveName: String? {
        guard let detectedDrive else { return nil }
        let values = try? detectedDrive.resourceValues(forKeys: [.volumeNameKey])
        return values?.volumeName ?? detectedDrive.lastPathComponent
    }
}
