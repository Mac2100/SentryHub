import AVFoundation
import Combine
import CoreMedia
import Foundation
import SwiftUI

/// Tile arrangements offered by the transport bar.
enum CameraLayout: String, CaseIterable, Identifiable {
    case single, dual, cinema, quad, six

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: return "Single"
        case .dual: return "Side by Side"
        case .cinema: return "Cinema"
        case .quad: return "Quad"
        case .six: return "Six Up"
        }
    }

    var symbolName: String {
        switch self {
        case .single: return "rectangle"
        case .dual: return "rectangle.split.2x1"
        case .cinema: return "rectangle.grid.2x2"
        case .quad: return "square.grid.2x2"
        case .six: return "square.grid.3x2"
        }
    }

    /// Tile rectangles come from `TileLayoutEngine`, shared with the exporter.
}

/// Drives every camera feed of one clip off a single timeline.
///
/// Each camera gets its own `AVPlayer` fed by an `AVMutableComposition` that
/// stitches the clip's ~60 s segments into one continuous track (gaps where a
/// camera is missing become empty time ranges, so all feeds stay aligned).
/// Playback is started on every player at the same host time, and a periodic
/// drift check nudges any feed that slips.
@MainActor
final class PlayerModel: ObservableObject {
    let clip: Clip

    @Published private(set) var players: [CameraAngle: AVPlayer] = [:]
    @Published private(set) var availableCameras: [CameraAngle] = []
    @Published private(set) var duration: TimeInterval = 0
    @Published private(set) var currentTime: TimeInterval = 0
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = true
    @Published private(set) var loadError: String?

    @Published var focusedCamera: CameraAngle = .front
    @Published var layout: CameraLayout = .six
    @Published var playbackRate: Double = 1
    @Published var isFullScreen = false

    /// Trim handles, in seconds from the start of the clip.
    @Published var trimStart: TimeInterval = 0
    @Published var trimEnd: TimeInterval = 0

    @Published private(set) var telemetry: TelemetryTrack = .empty

    static let rateOptions: [Double] = [0.25, 0.5, 1, 1.5, 2, 4]

    private var masterCamera: CameraAngle?
    private var timeObserver: Any?
    private var driftTimer: Timer?
    private var endObserver: NSObjectProtocol?

    init(clip: Clip) {
        self.clip = clip
        self.focusedCamera = clip.event?.triggerCamera
            ?? CameraAngle.preferredFocusOrder.first { clip.cameras.contains($0) }
            ?? .front
        if let stored = UserDefaults.standard.string(forKey: "defaultLayout"),
           let value = CameraLayout(rawValue: stored) {
            layout = value
        }
    }

    private var master: AVPlayer? {
        guard let masterCamera else { return nil }
        return players[masterCamera]
    }

    // MARK: - Loading

    func load() async {
        isLoading = true
        loadError = nil

        let cameras = clip.orderedCameras
        guard !cameras.isEmpty else {
            loadError = "This clip has no readable video files."
            isLoading = false
            return
        }

        var built: [CameraAngle: AVPlayer] = [:]
        var timelineLength: TimeInterval = 0

        for camera in cameras {
            do {
                let (composition, length) = try await Self.makeComposition(
                    for: camera, clip: clip
                )
                timelineLength = max(timelineLength, length)
                let item = AVPlayerItem(asset: composition)
                let player = AVPlayer(playerItem: item)
                // Required for `setRate(_:time:atHostTime:)` to keep the feeds locked.
                player.automaticallyWaitsToMinimizeStalling = false
                player.actionAtItemEnd = .pause
                player.isMuted = true
                built[camera] = player
            } catch {
                // A single unreadable camera shouldn't take the whole clip down.
                continue
            }
        }

        guard !built.isEmpty else {
            loadError = "None of this clip's video files could be opened."
            isLoading = false
            return
        }

        players = built
        availableCameras = CameraAngle.sixUpOrder.filter { built[$0] != nil }
        if !availableCameras.contains(focusedCamera), let first = availableCameras.first {
            focusedCamera = first
        }
        masterCamera = CameraAngle.preferredFocusOrder.first { built[$0] != nil }
            ?? availableCameras.first

        duration = timelineLength
        trimStart = 0
        trimEnd = timelineLength
        isLoading = false

        attachObservers()

        let loaded = await TelemetryLoader.load(for: clip)
        telemetry = loaded
    }

    /// Stitches one camera's segments into a single continuous track.
    private nonisolated static func makeComposition(
        for camera: CameraAngle, clip: Clip
    ) async throws -> (AVMutableComposition, TimeInterval) {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw PlaybackError("Could not create a video track.")
        }

        var cursor = CMTime.zero
        for segment in clip.segments {
            let slot = CMTime(seconds: segment.duration, preferredTimescale: 600)
            guard let url = segment.files[camera] else {
                composition.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: slot))
                cursor = cursor + slot
                continue
            }

            let asset = AVURLAsset(url: url)
            guard let source = try? await asset.loadTracks(withMediaType: .video).first else {
                composition.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: slot))
                cursor = cursor + slot
                continue
            }

            let assetDuration = (try? await asset.load(.duration)) ?? slot
            let usable = CMTimeMinimum(assetDuration, slot)
            try track.insertTimeRange(
                CMTimeRange(start: .zero, duration: usable), of: source, at: cursor
            )
            if let transform = try? await source.load(.preferredTransform) {
                track.preferredTransform = transform
            }

            // Pad the remainder so the next segment starts on the timeline grid.
            let padding = slot - usable
            if padding.seconds > 0.001 {
                composition.insertEmptyTimeRange(
                    CMTimeRange(start: cursor + usable, duration: padding)
                )
            }
            cursor = cursor + slot
        }

        return (composition, CMTimeGetSeconds(cursor))
    }

    // MARK: - Observers

    private func attachObservers() {
        guard let master else { return }

        let interval = CMTime(seconds: 0.05, preferredTimescale: 600)
        timeObserver = master.addPeriodicTimeObserver(
            forInterval: interval, queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let seconds = CMTimeGetSeconds(time)
                guard seconds.isFinite else { return }
                self.currentTime = seconds
                if self.isPlaying, self.trimEnd > self.trimStart, seconds >= self.trimEnd - 0.02 {
                    self.pause()
                    self.seek(to: self.trimEnd)
                }
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: master.currentItem,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isPlaying = false
            }
        }

        driftTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.correctDrift()
            }
        }
    }

    func teardown() {
        if let timeObserver, let master {
            master.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        driftTimer?.invalidate()
        driftTimer = nil
        for player in players.values {
            player.pause()
            player.replaceCurrentItem(with: nil)
        }
        players = [:]
        isPlaying = false
    }

    // MARK: - Transport

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard !players.isEmpty else { return }
        // Restart from the trim start once the head is parked at the end.
        if currentTime >= trimEnd - 0.05 {
            seek(to: trimStart)
        }

        let start = CMTime(seconds: currentTime, preferredTimescale: 600)
        // A small lead time gives every player the same start instant.
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            + CMTime(seconds: 0.15, preferredTimescale: 600)
        for player in players.values {
            player.setRate(Float(playbackRate), time: start, atHostTime: hostTime)
        }
        isPlaying = true
    }

    func pause() {
        for player in players.values {
            player.rate = 0
        }
        isPlaying = false
        if let master {
            let seconds = CMTimeGetSeconds(master.currentTime())
            if seconds.isFinite { currentTime = seconds }
        }
    }

    func seek(to seconds: TimeInterval) {
        let clamped = min(max(seconds, 0), max(duration, 0))
        let time = CMTime(seconds: clamped, preferredTimescale: 600)
        currentTime = clamped
        for player in players.values {
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isPlaying {
            // Re-arm the shared start instant so the feeds don't drift apart.
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: 0.15, preferredTimescale: 600)
            for player in players.values {
                player.setRate(Float(playbackRate), time: time, atHostTime: hostTime)
            }
        }
    }

    func step(by seconds: TimeInterval) {
        seek(to: currentTime + seconds)
    }

    func setRate(_ rate: Double) {
        playbackRate = rate
        guard isPlaying else { return }
        play()
    }

    /// Nudges any feed that has slipped more than ~100 ms from the master.
    private func correctDrift() {
        guard isPlaying, let masterCamera, let master else { return }
        let reference = master.currentTime()
        guard CMTimeGetSeconds(reference).isFinite else { return }
        for (camera, player) in players where camera != masterCamera {
            let delta = abs(CMTimeGetSeconds(player.currentTime()) - CMTimeGetSeconds(reference))
            if delta.isFinite, delta > 0.1 {
                player.seek(to: reference, toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    // MARK: - Trimming

    var hasTrim: Bool {
        trimStart > 0.01 || trimEnd < duration - 0.01
    }

    var trimDuration: TimeInterval {
        max(0, trimEnd - trimStart)
    }

    func markIn() {
        trimStart = min(currentTime, max(0, trimEnd - 0.5))
    }

    func markOut() {
        trimEnd = max(currentTime, trimStart + 0.5)
    }

    func clearTrim() {
        trimStart = 0
        trimEnd = duration
    }

    // MARK: - Telemetry

    /// Telemetry at the play head, or `nil` when the clip has none.
    var currentSample: TelemetrySample? {
        telemetry.sample(at: currentTime)
    }

    /// Wall-clock instant currently on screen — always available, because it
    /// comes from the clip's own start time rather than from telemetry.
    var wallClock: Date {
        clip.startDate.addingTimeInterval(currentTime)
    }

    func cycleFocus(forward: Bool) {
        guard !availableCameras.isEmpty else { return }
        let index = availableCameras.firstIndex(of: focusedCamera) ?? 0
        let next = forward
            ? (index + 1) % availableCameras.count
            : (index - 1 + availableCameras.count) % availableCameras.count
        focusedCamera = availableCameras[next]
    }
}

struct PlaybackError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
