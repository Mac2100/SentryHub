import AVFoundation
import AppKit
import SwiftUI

/// Full playback view: every camera feed, the HUD, the transport bar, the route
/// map, and the export sheet.
struct PlayerView: View {
    let clip: Clip
    let onClose: () -> Void

    @StateObject private var model: PlayerModel
    @EnvironmentObject private var hudStore: HUDStore
    @ObservedObject private var labels = ClipLabels.shared
    @Environment(\.appTheme) private var theme

    @State private var showHUDPanel = false
    @State private var showMapPanel = false
    @State private var showExportSheet = false
    @State private var mapPanelTab = MapPanelTab.route
    @State private var wasPlayingBeforeScrub = false

    private enum MapPanelTab: String, CaseIterable, Identifiable {
        case route, settings
        var id: String { rawValue }
        var label: String { self == .route ? "Route" : "Settings" }
    }

    init(clip: Clip, onClose: @escaping () -> Void) {
        self.clip = clip
        self.onClose = onClose
        _model = StateObject(wrappedValue: PlayerModel(clip: clip))
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.isFullScreen {
                header
            }

            ZStack {
                Color.black
                if model.isLoading {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("Preparing camera feeds…")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else if let error = model.loadError {
                    VStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 30))
                            .foregroundStyle(.orange)
                        Text(error)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    CameraGridView(model: model, config: hudStore.config)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            transportBar
        }
        .background(playerBackdrop)
        .task {
            await model.load()
            await model.refreshMapBackdrop(config: hudStore.config)
        }
        .task(id: mapBackdropKey) {
            await model.refreshMapBackdrop(config: hudStore.config)
        }
        .onDisappear {
            model.teardown()
        }
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(model: model, config: hudStore.config)
        }
        .background(shortcuts)
    }

    /// Only re-snapshot the map when something that changes the tiles changes.
    private var mapBackdropKey: String {
        "\(hudStore.config.mapEnabled)-\(hudStore.config.mapTheme.rawValue)-\(Int(hudStore.config.mapZoomLevel))-\(model.telemetry.samples.count)"
    }

    private var playerBackdrop: some View {
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.06, blue: 0.11),
                Color(red: 0.02, green: 0.03, blue: 0.06)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            Button(action: onClose) {
                Label("Back to Videos", systemImage: "chevron.left")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 3) {
                Text(labels.title(for: clip))
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 14) {
                    headerFact(symbol: "clock", text: clip.startDate.briefFormatted)
                    headerFact(symbol: "video", text: "\(model.availableCameras.count)")
                    headerFact(symbol: "timer", text: Format.duration(model.duration))
                    if let place = clip.placeLabel {
                        headerFact(symbol: "building.2", text: place)
                    }
                    if !model.telemetry.isEmpty {
                        headerFact(
                            symbol: model.telemetry.source.symbolName,
                            text: model.telemetry.source.label
                        )
                    }
                }
            }

            Spacer()

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([clip.directory])
            } label: {
                Label("Reveal", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private func headerFact(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
            Text(text)
                .font(.system(size: 11))
        }
        .foregroundStyle(.secondary)
    }

    // MARK: - Transport bar

    private var transportBar: some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .disabled(model.isLoading)

                Text(Format.timecode(model.currentTime))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 46, alignment: .leading)

                TimelineScrubber(
                    duration: model.duration,
                    currentTime: model.currentTime,
                    trimStart: model.trimStart,
                    trimEnd: model.trimEnd,
                    segmentMarks: segmentMarks,
                    eventMark: model.eventOffset,
                    tint: theme.primary,
                    onScrub: { time in
                        if model.isPlaying {
                            wasPlayingBeforeScrub = true
                            model.pause()
                        }
                        model.seek(to: time)
                    },
                    onScrubEnded: {
                        if wasPlayingBeforeScrub {
                            wasPlayingBeforeScrub = false
                            model.play()
                        }
                    }
                )

                Text(Format.timecode(model.duration))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 46, alignment: .trailing)

                rateMenu
            }

            HStack(spacing: 10) {
                cameraPicker
                Divider().frame(height: 20).overlay(Color.white.opacity(0.12))
                layoutPicker
                Divider().frame(height: 20).overlay(Color.white.opacity(0.12))
                trimControls
                eventJumpButton
                Spacer(minLength: 12)
                mapButton
                hudButton
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        .padding(.horizontal, 14)
        .padding(.bottom, 14)
        .padding(.top, 6)
    }

    private var segmentMarks: [TimeInterval] {
        guard clip.segments.count > 1 else { return [] }
        var marks: [TimeInterval] = []
        var elapsed: TimeInterval = 0
        for segment in clip.segments.dropLast() {
            elapsed += segment.duration
            marks.append(elapsed)
        }
        return marks
    }

    private var rateMenu: some View {
        Menu {
            ForEach(PlayerModel.rateOptions, id: \.self) { rate in
                Button {
                    model.setRate(rate)
                } label: {
                    if model.playbackRate == rate {
                        Label(rateLabel(rate), systemImage: "checkmark")
                    } else {
                        Text(rateLabel(rate))
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                    .font(.system(size: 11))
                Text(rateLabel(model.playbackRate))
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.85))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(width: 64)
    }

    private func rateLabel(_ rate: Double) -> String {
        rate == rate.rounded() ? "\(Int(rate))x" : String(format: "%.2gx", rate)
    }

    /// Six positional buttons matching where the cameras sit on the car.
    private var cameraPicker: some View {
        HStack(spacing: 4) {
            ForEach(CameraAngle.sixUpOrder) { camera in
                let enabled = model.availableCameras.contains(camera)
                Button {
                    model.focusedCamera = camera
                    if model.layout == .six || model.layout == .quad {
                        model.layout = .single
                    }
                } label: {
                    Image(systemName: camera.directionSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    model.focusedCamera == camera && enabled
                                        ? theme.primary.opacity(0.45)
                                        : Color.white.opacity(0.07)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(enabled ? .white : Color.white.opacity(0.22))
                .disabled(!enabled)
                .help(enabled ? camera.displayName : "\(camera.displayName) — not recorded")
            }
        }
    }

    private var layoutPicker: some View {
        HStack(spacing: 4) {
            ForEach(CameraLayout.allCases) { layout in
                Button {
                    model.layout = layout
                    UserDefaults.standard.set(layout.rawValue, forKey: "defaultLayout")
                } label: {
                    Image(systemName: layout.symbolName)
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    model.layout == layout
                                        ? theme.primary.opacity(0.45)
                                        : Color.white.opacity(0.07)
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .help(layout.label)
            }

            Button {
                model.isFullScreen.toggle()
            } label: {
                Image(systemName: model.isFullScreen
                      ? "arrow.down.right.and.arrow.up.left"
                      : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 28, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Hide the header for a bigger picture")
        }
    }

    /// Jumps to the moment the car flagged — the Sentry trigger, horn press, or
    /// manual save recorded in `event.json`.
    @ViewBuilder
    private var eventJumpButton: some View {
        if let offset = model.eventOffset {
            Button {
                model.jumpToEvent()
            } label: {
                Label(
                    model.clip.trigger?.badgeLabel ?? "EVENT",
                    systemImage: model.clip.trigger?.symbolName ?? "diamond.fill"
                )
                .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(TransportButtonStyle(
                tint: Color(red: 1.0, green: 0.42, blue: 0.30),
                isActive: abs(model.currentTime - offset) < 0.4
            ))
            .help("Jump to \(Int(PlayerModel.eventPreRoll)) s before the event at \(Format.timecode(offset))")
        }
    }

    private var trimControls: some View {
        HStack(spacing: 6) {
            Button("IN") { model.markIn() }
                .buttonStyle(TransportButtonStyle(tint: theme.primary, isActive: model.trimStart > 0.01))
                .help("Set the trim start at the play head")
            Button("OUT") { model.markOut() }
                .buttonStyle(TransportButtonStyle(
                    tint: theme.primary, isActive: model.trimEnd < model.duration - 0.01
                ))
                .help("Set the trim end at the play head")
            if model.hasTrim {
                Button {
                    model.clearTrim()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                }
                .buttonStyle(TransportButtonStyle(tint: theme.primary, isActive: false))
                .help("Clear the trim range")
            }

            Button {
                showExportSheet = true
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(TransportButtonStyle(tint: theme.primary, isActive: false))
            .disabled(model.isLoading)
        }
    }

    private var mapButton: some View {
        Button {
            showMapPanel.toggle()
        } label: {
            Label("Map", systemImage: "map")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(TransportButtonStyle(tint: theme.primary, isActive: showMapPanel))
        .popover(isPresented: $showMapPanel, arrowEdge: .top) {
            VStack(spacing: 0) {
                Picker("", selection: $mapPanelTab) {
                    ForEach(MapPanelTab.allCases) { tab in
                        Text(tab.label).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(10)

                Divider()

                switch mapPanelTab {
                case .route:
                    RouteMapView(
                        route: model.telemetry.route,
                        current: model.currentSample?.coordinate,
                        heading: model.currentSample?.heading,
                        config: hudStore.config
                    )
                    .frame(width: 460, height: 380)
                case .settings:
                    MapSettingsPanel(config: $hudStore.config)
                        .frame(width: 260)
                }
            }
            .frame(width: mapPanelTab == .route ? 460 : 260)
        }
    }

    private var hudButton: some View {
        Button {
            showHUDPanel.toggle()
        } label: {
            Label("HUD", systemImage: "waveform.path.ecg")
                .font(.system(size: 11, weight: .semibold))
        }
        .buttonStyle(TransportButtonStyle(
            tint: theme.primary, isActive: hudStore.config.enabled
        ))
        .popover(isPresented: $showHUDPanel, arrowEdge: .top) {
            HUDSettingsPanel(config: $hudStore.config, availability: model.availability)
        }
        .contextMenu {
            Toggle("Show HUD", isOn: $hudStore.config.enabled)
            Button("Reset HUD Settings") { hudStore.reset() }
        }
    }

    // MARK: - Keyboard

    /// Hidden buttons that carry the player's keyboard shortcuts.
    private var shortcuts: some View {
        ZStack {
            Button("") { model.togglePlayback() }
                .keyboardShortcut(.space, modifiers: [])
            Button("") { model.step(by: -1.0 / 30.0) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("") { model.step(by: 1.0 / 30.0) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("") { model.step(by: -5) }
                .keyboardShortcut(.leftArrow, modifiers: [.shift])
            Button("") { model.step(by: 5) }
                .keyboardShortcut(.rightArrow, modifiers: [.shift])
            Button("") { model.markIn() }
                .keyboardShortcut("[", modifiers: [])
            Button("") { model.markOut() }
                .keyboardShortcut("]", modifiers: [])
            Button("") { model.cycleFocus(forward: true) }
                .keyboardShortcut("c", modifiers: [])
            Button("") { model.isFullScreen.toggle() }
                .keyboardShortcut("f", modifiers: [])
            Button("") { model.jumpToEvent() }
                .keyboardShortcut("e", modifiers: [])
            Button("") { onClose() }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }
}

/// Pill button used across the transport bar.
struct TransportButtonStyle: ButtonStyle {
    let tint: Color
    let isActive: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(
                        configuration.isPressed
                            ? tint.opacity(0.55)
                            : (isActive ? tint.opacity(0.38) : Color.white.opacity(0.08))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(
                        isActive ? tint.opacity(0.7) : Color.white.opacity(0.10),
                        lineWidth: 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }
}
