import AVFoundation
import Foundation

/// Walks a TeslaCam drive (or any folder holding the same layout) and turns it
/// into `Clip` values. Everything happens locally; nothing is uploaded anywhere.
///
/// Expected layout:
/// ```
/// <root>/                       ← the drive, or a folder containing TeslaCam/
///   TeslaCam/
///     SentryClips/2025-12-21_20-59-54/{*.mp4, event.json, thumb.png}
///     SavedClips/2025-12-21_20-59-54/{*.mp4, event.json, thumb.png}
///     RecentClips/2025-12-21_20-59-54-front.mp4, …
/// ```
/// A folder that *is* `TeslaCam`, or that directly holds the three clip
/// folders, works just as well.
enum LibraryScanner {
    struct Result {
        var clips: [Clip]
        var warnings: [String]
        /// The folder that actually contained the clip directories.
        var resolvedRoot: URL
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    // MARK: - Entry point

    static func scan(root: URL) throws -> Result {
        let fm = FileManager.default
        let base = resolveBase(root: root, fm: fm)

        var clips: [Clip] = []
        var warnings: [String] = []

        for category in ClipCategory.allCases {
            let folder = base.appendingPathComponent(category.folderName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }

            do {
                clips.append(contentsOf: try scanCategory(category, at: folder, fm: fm))
            } catch {
                warnings.append("\(category.label): \(error.localizedDescription)")
            }
        }

        if clips.isEmpty {
            // Be forgiving: a user may have pointed at a single event folder, or
            // at a folder of loose clips they copied off the drive.
            clips = (try? scanLooseFolder(base, fm: fm)) ?? []
            if !clips.isEmpty {
                warnings.append(
                    "No SentryClips/SavedClips/RecentClips folders found — "
                    + "loaded loose clips from this folder instead."
                )
            }
        }

        clips.sort { $0.startDate > $1.startDate }
        return Result(clips: clips, warnings: warnings, resolvedRoot: base)
    }

    /// Accepts the drive root, the `TeslaCam` folder, or the folder holding the
    /// three clip directories.
    private static func resolveBase(root: URL, fm: FileManager) -> URL {
        let nested = root.appendingPathComponent("TeslaCam", isDirectory: true)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: nested.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return nested
        }
        return root
    }

    // MARK: - Categories

    private static func scanCategory(
        _ category: ClipCategory, at folder: URL, fm: FileManager
    ) throws -> [Clip] {
        let entries = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        let subfolders = entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
        let looseVideos = entries.filter { videoExtensions.contains($0.pathExtension.lowercased()) }

        var clips: [Clip] = []

        // Sentry / Saved: one folder per event.
        for subfolder in subfolders {
            if let clip = try? eventClip(category: category, folder: subfolder, fm: fm) {
                clips.append(clip)
            }
        }

        // Recent: loose files grouped by their timestamp prefix.
        if !looseVideos.isEmpty {
            clips.append(contentsOf: groupedClips(
                category: category, directory: folder, files: looseVideos, fm: fm
            ))
        }

        return clips
    }

    /// A Sentry/Saved event folder: every segment in it belongs to one clip.
    private static func eventClip(category: ClipCategory, folder: URL, fm: FileManager) throws -> Clip? {
        let entries = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let videos = entries.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { return nil }

        let segments = buildSegments(from: videos, fm: fm)
        guard !segments.isEmpty else { return nil }

        let event = loadEvent(in: folder, entries: entries)
        let thumbnail = entries.first {
            $0.lastPathComponent.lowercased() == "thumb.png"
                || $0.lastPathComponent.lowercased() == "thumb.jpg"
        }

        let name = folder.lastPathComponent
        let start = TeslaTimestamp.fileFormatter.date(from: name)
            ?? event?.timestamp
            ?? segments[0].timestamp

        return Clip(
            category: category,
            name: name,
            directory: folder,
            startDate: start,
            segments: segments,
            event: event,
            thumbnailURL: thumbnail
        )
    }

    /// Loose files (RecentClips): every timestamp prefix becomes its own clip.
    private static func groupedClips(
        category: ClipCategory, directory: URL, files: [URL], fm: FileManager
    ) -> [Clip] {
        let segments = buildSegments(from: files, fm: fm)
        return segments.map { segment in
            Clip(
                category: category,
                name: segment.id,
                directory: directory,
                startDate: segment.timestamp,
                segments: [segment],
                event: nil,
                thumbnailURL: nil
            )
        }
    }

    /// A folder the user copied clips into by hand.
    private static func scanLooseFolder(_ folder: URL, fm: FileManager) throws -> [Clip] {
        let entries = try fm.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )
        let videos = entries.filter { videoExtensions.contains($0.pathExtension.lowercased()) }
        guard !videos.isEmpty else { return [] }

        // If there's an event.json the whole folder is one event.
        if entries.contains(where: { $0.lastPathComponent == "event.json" }) {
            if let clip = try? eventClip(category: .saved, folder: folder, fm: fm) {
                return [clip]
            }
        }
        return groupedClips(category: .recent, directory: folder, files: videos, fm: fm)
    }

    // MARK: - Segments

    /// Groups files by their `YYYY-MM-DD_HH-MM-SS` prefix.
    private static func buildSegments(from files: [URL], fm: FileManager) -> [ClipSegment] {
        var grouped: [String: [CameraAngle: URL]] = [:]
        var sizes: [String: Int64] = [:]

        for file in files {
            guard let parts = TeslaTimestamp.components(ofFileNamed: file.lastPathComponent) else {
                continue
            }
            grouped[parts.prefix, default: [:]][parts.camera] = file
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            sizes[parts.prefix, default: 0] += Int64(size)
        }

        return grouped.compactMap { prefix, cameras -> ClipSegment? in
            guard let timestamp = TeslaTimestamp.fileFormatter.date(from: prefix) else { return nil }
            return ClipSegment(
                id: prefix,
                timestamp: timestamp,
                files: cameras,
                byteCount: sizes[prefix] ?? 0,
                // Tesla writes ~60 s per segment; the real value is resolved
                // asynchronously by `resolveDurations`.
                duration: 60
            )
        }
        .sorted { $0.timestamp < $1.timestamp }
    }

    // MARK: - event.json

    private static func loadEvent(in folder: URL, entries: [URL]) -> EventMetadata? {
        guard let url = entries.first(where: { $0.lastPathComponent == "event.json" }) else {
            return nil
        }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EventMetadata.self, from: data)
    }

    // MARK: - Durations

    /// Replaces the assumed 60 s segment length with the real duration read from
    /// the container, and fills in a location for clips `event.json` said
    /// nothing about. Runs off the main actor; call it after the initial scan so
    /// the library appears immediately.
    static func resolveDurations(for clip: Clip) async -> Clip {
        var updated = clip
        for index in updated.segments.indices {
            let segment = updated.segments[index]
            // Prefer the longest track in the segment: cameras occasionally stop
            // a frame or two early.
            var longest: TimeInterval = 0
            for url in segment.files.values {
                let asset = AVURLAsset(url: url)
                if let duration = try? await asset.load(.duration) {
                    let seconds = CMTimeGetSeconds(duration)
                    if seconds.isFinite, seconds > longest { longest = seconds }
                }
            }
            if longest > 0 {
                updated.segments[index].duration = longest
            }
        }
        return await resolveEmbeddedLocation(for: updated)
    }

    /// Tesla writes no `event.json` beside a Recent clip, so those cards had no
    /// location at all. Some firmware does stamp an ISO-6709 location atom into
    /// the MP4 itself — the player already reads it for the HUD, but the library
    /// never looked, so a fix sitting in the file went unused.
    ///
    /// This reads the real atom or gives up. It never borrows a position from a
    /// neighbouring clip: two recordings a minute apart are not the same place,
    /// and a plausible-looking wrong pin is worse than an empty one.
    private static func resolveEmbeddedLocation(for clip: Clip) async -> Clip {
        guard clip.coordinate == nil,
              let url = clip.segments.first.flatMap({ segment in
                  CameraAngle.preferredFocusOrder.compactMap { segment.files[$0] }.first
              }) else { return clip }

        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.metadata) else { return clip }

        for item in items {
            guard let identifier = item.identifier?.rawValue.lowercased(),
                  identifier.contains("location") else { continue }
            guard let string = try? await item.load(.stringValue),
                  let fix = TelemetryLoader.parseISO6709(string) else { continue }

            var updated = clip
            var event = updated.event ?? EventMetadata()
            event.latitude = fix.latitude
            event.longitude = fix.longitude
            updated.event = event
            return updated
        }
        return clip
    }
}
