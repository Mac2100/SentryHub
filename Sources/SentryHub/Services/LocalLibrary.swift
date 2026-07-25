import AppKit
import Combine
import Foundation
import SwiftUI

// MARK: - File operations

/// The file-level half of saving and deleting clips, kept free of any UI state
/// so it can run off the main actor.
enum ClipFiles {
    struct CopyPair: Sendable {
        let source: URL
        let destination: URL
    }

    /// Everything that has to be copied for one clip, as source → destination
    /// pairs inside a TeslaCam-shaped tree rooted at `root`.
    static func copyPlan(for clip: Clip, into root: URL) -> [CopyPair] {
        let fm = FileManager.default
        let categoryFolder = root.appendingPathComponent(
            clip.category.folderName, isDirectory: true
        )

        if clip.ownsDirectory {
            // A Sentry/Saved event folder — take all of it, so event.json and
            // the car's own thumbnail come along.
            let target = categoryFolder.appendingPathComponent(clip.name, isDirectory: true)
            let entries = (try? fm.contentsOfDirectory(
                at: clip.directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )) ?? []
            return entries.map {
                CopyPair(source: $0, destination: target.appendingPathComponent($0.lastPathComponent))
            }
        }

        // A Recent clip is loose files in a folder it shares with every other
        // recording on the drive. Copying the folder would drag the whole
        // rolling buffer along with it.
        var pairs = clip.allFiles.map {
            CopyPair(
                source: $0,
                destination: categoryFolder.appendingPathComponent($0.lastPathComponent)
            )
        }
        for name in clip.sidecarFileNames {
            let candidate = clip.directory.appendingPathComponent(name)
            guard fm.fileExists(atPath: candidate.path) else { continue }
            pairs.append(
                CopyPair(source: candidate, destination: categoryFolder.appendingPathComponent(name))
            )
        }
        return pairs
    }

    /// Copies one clip's files. Returns a message on the first failure.
    static func copy(_ pairs: [CopyPair]) -> String? {
        let fm = FileManager.default
        for pair in pairs {
            do {
                try fm.createDirectory(
                    at: pair.destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // A previous attempt may have been interrupted part-way.
                if fm.fileExists(atPath: pair.destination.path) {
                    try fm.removeItem(at: pair.destination)
                }
                try fm.copyItem(at: pair.source, to: pair.destination)
            } catch {
                return error.localizedDescription
            }
        }
        return nil
    }

    /// Sends files to the Trash, falling back to an outright delete.
    ///
    /// Dashcam drives are exFAT and usually have no Trash to move anything
    /// into, so deleting off the drive frequently *is* permanent — which is why
    /// the confirmation the user sees says exactly that.
    static func trash(_ urls: [URL]) -> String? {
        let fm = FileManager.default
        for url in urls where fm.fileExists(atPath: url.path) {
            do {
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                do {
                    try fm.removeItem(at: url)
                } catch {
                    return error.localizedDescription
                }
            }
        }
        return nil
    }

    /// Free space on the volume holding `url`, when the system will say.
    static func availableCapacity(at url: URL) -> Int64? {
        let values = try? url.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        )
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

// MARK: - The local library

/// SentryHub's own copy of the footage — the half of the library that survives
/// the drive being unplugged.
///
/// Clips are copied into Application Support in exactly the layout the scanner
/// already understands:
///
/// ```
/// ~/Library/Application Support/SentryHub/Library/
///   SentryClips/2026-07-24_11-27-41/{*.mp4, event.json, thumb.png}
///   SavedClips/…
///   RecentClips/2026-07-24_11-27-41-front.mp4, …
/// ```
///
/// Keeping Tesla's own layout buys two things: the same `LibraryScanner` reads
/// the vault and the drive, and the saved footage stays a plain folder of MP4s
/// that outlives SentryHub itself.
@MainActor
final class LocalLibrary: ObservableObject {
    static let shared = LocalLibrary()

    @Published private(set) var clips: [Clip] = []
    @Published private(set) var isScanning = false
    /// Non-nil while a copy or delete is running.
    @Published private(set) var transfer: Transfer?

    /// Fires after `clips` has settled. `objectWillChange` is too early for the
    /// merge — it arrives before the new value lands — and an explicit subject
    /// says who depends on this far more plainly than `$clips` would.
    let clipsDidChange = PassthroughSubject<[Clip], Never>()

    struct Transfer: Equatable {
        enum Kind: Equatable { case saving, removing }

        var kind: Kind
        var completed: Int
        var total: Int
        var currentName: String

        var label: String {
            kind == .saving ? "Saving to this Mac" : "Removing from this Mac"
        }

        var fraction: Double {
            total == 0 ? 0 : Double(completed) / Double(total)
        }
    }

    /// Leave a little room rather than filling the boot volume to the brim.
    private static let headroom: Int64 = 2_000_000_000

    let root: URL

    private var durationTask: Task<Void, Never>?

    private init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        root = base
            .appendingPathComponent("SentryHub", isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
    }

    // MARK: - Reading

    var totalBytes: Int64 {
        clips.reduce(0) { $0 + $1.byteCount }
    }

    func clip(for id: Clip.ID) -> Clip? {
        clips.first { $0.id == id }
    }

    func contains(_ id: Clip.ID) -> Bool {
        clips.contains { $0.id == id }
    }

    func rescan() async {
        let folder = root
        guard FileManager.default.fileExists(atPath: folder.path) else {
            clips = []
            clipsDidChange.send(clips)
            return
        }
        isScanning = true
        durationTask?.cancel()
        let result = await Task.detached(priority: .userInitiated) {
            try? LibraryScanner.scan(root: folder)
        }.value
        clips = result?.clips ?? []
        isScanning = false
        clipsDidChange.send(clips)
        resolveDurationsInBackground()
    }

    /// Same treatment the drive scan gets: the scanner assumes 60-second
    /// segments, so the real lengths are filled in afterwards.
    private func resolveDurationsInBackground() {
        let snapshot = clips
        guard !snapshot.isEmpty else { return }
        durationTask = Task { [weak self] in
            var updated: [Clip] = []
            updated.reserveCapacity(snapshot.count)
            for clip in snapshot {
                if Task.isCancelled { return }
                updated.append(await LibraryScanner.resolveDurations(for: clip))
            }
            if Task.isCancelled { return }
            await MainActor.run { [weak self] in
                guard let self, self.clips.count == updated.count else { return }
                self.clips = updated
                self.clipsDidChange.send(updated)
            }
        }
    }

    // MARK: - Saving

    /// Copies clips onto this Mac. Pass the *drive* copies — these are the files
    /// being read from.
    func save(_ items: [Clip]) async {
        let pending = items.filter { !contains($0.id) }
        guard !pending.isEmpty, transfer == nil else { return }

        do {
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true
            )
        } catch {
            ToastCenter.shared.show(
                "Couldn't create the local library",
                detail: error.localizedDescription,
                style: .error
            )
            return
        }

        let needed = pending.reduce(Int64(0)) { $0 + $1.byteCount }
        if let free = ClipFiles.availableCapacity(at: root), needed + Self.headroom > free {
            ToastCenter.shared.show(
                "Not enough room on this Mac",
                detail: "Saving \(pending.count) clip\(pending.count == 1 ? "" : "s") needs "
                    + "\(Format.bytes(needed)), and only \(Format.bytes(free)) is free.",
                style: .error
            )
            return
        }

        var failures: [String] = []
        for (index, clip) in pending.enumerated() {
            transfer = Transfer(
                kind: .saving, completed: index, total: pending.count, currentName: clip.name
            )
            let plan = ClipFiles.copyPlan(for: clip, into: root)
            let failure = await Task.detached(priority: .utility) {
                ClipFiles.copy(plan)
            }.value
            if let failure { failures.append("\(clip.name): \(failure)") }
        }
        transfer = nil
        await rescan()

        let saved = pending.count - failures.count
        if failures.isEmpty {
            ToastCenter.shared.show(
                "Saved \(saved) clip\(saved == 1 ? "" : "s") to this Mac",
                detail: "\(Format.bytes(needed)) — available with the drive unplugged.",
                style: .success
            )
        } else {
            ToastCenter.shared.show(
                saved > 0 ? "Saved \(saved), failed \(failures.count)" : "Couldn't save the clips",
                detail: failures.first,
                style: .error
            )
        }
    }

    // MARK: - Removing

    /// Deletes the local copies. The drive, if it's still attached, is untouched.
    func remove(_ ids: [Clip.ID]) async {
        let targets = ids.compactMap { clip(for: $0) }
        guard !targets.isEmpty, transfer == nil else { return }

        var failures: [String] = []
        for (index, clip) in targets.enumerated() {
            transfer = Transfer(
                kind: .removing, completed: index, total: targets.count, currentName: clip.name
            )
            let urls = clip.storedItems
            let failure = await Task.detached(priority: .utility) {
                ClipFiles.trash(urls)
            }.value
            if let failure { failures.append("\(clip.name): \(failure)") }
        }
        transfer = nil
        await rescan()

        let removed = targets.count - failures.count
        if failures.isEmpty {
            ToastCenter.shared.show(
                "Removed \(removed) clip\(removed == 1 ? "" : "s") from this Mac",
                style: .info
            )
        } else {
            ToastCenter.shared.show(
                "Couldn't remove every clip", detail: failures.first, style: .error
            )
        }
    }

    /// Empties the whole vault, used by Settings.
    func removeEverything() async {
        await remove(clips.map(\.id))
    }

    func revealInFinder() {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}
