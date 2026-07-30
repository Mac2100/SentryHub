import AppKit
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
            PlaybackSettingsView()
                .tabItem { Label("Playback", systemImage: "play.rectangle") }
            HUDSettingsTab()
                .tabItem { Label("HUD", systemImage: "waveform.path.ecg") }
            UpdatesSettingsView()
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
            AboutSettingsView()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 640, height: 500)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var local = LocalLibrary.shared
    @AppStorage("showToasts") private var showToasts = true
    @AppStorage("rescanOnActivate") private var rescanOnActivate = false
    @State private var confirmEmptyVault = false

    var body: some View {
        Form {
            Section("Dashcam Drive") {
                if let root = appState.library.rootURL {
                    LabeledContent("Folder") {
                        Text(root.path)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                    LabeledContent("Clips on the drive", value: "\(appState.library.deviceClips.count)")
                } else {
                    Text("No folder selected yet.")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Button("Choose Folder…") {
                        Task { await appState.library.chooseFolder() }
                    }
                    Button("Rescan") {
                        Task { await appState.library.rescan() }
                    }
                    .disabled(appState.library.rootURL == nil)
                    Spacer()
                    Button("Forget Folder", role: .destructive) {
                        appState.library.forgetFolder()
                    }
                    .disabled(appState.library.rootURL == nil)
                }
            }

            Section("On This Mac") {
                LabeledContent("Saved clips", value: "\(local.clips.count)")
                LabeledContent("Size", value: Format.bytes(local.totalBytes))
                LabeledContent("Location") {
                    Text(local.root.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Reveal in Finder") { local.revealInFinder() }
                    Spacer()
                    Button("Remove All…", role: .destructive) {
                        confirmEmptyVault = true
                    }
                    .disabled(local.clips.isEmpty || local.transfer != nil)
                }
            }
            .alert("Remove every saved clip?", isPresented: $confirmEmptyVault) {
                Button("Remove All", role: .destructive) {
                    Task { await local.removeEverything() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("\(local.clips.count) clips (\(Format.bytes(local.totalBytes))) are moved to the Trash. Anything still on the dashcam drive stays there.")
            }

            Section {
                Toggle("Rescan when the app becomes active", isOn: $rescanOnActivate)
                Toggle("Show in-app notifications", isOn: $showToasts)
                HStack {
                    Text("Walkthrough")
                    Spacer()
                    Button("Show Again") { TourController.shared.start() }
                }
            } footer: {
                Text("SentryHub never uploads footage. Everything is read straight from the folder you pick; the only network request is the optional update check.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        }
        .formStyle(.grouped)
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @EnvironmentObject private var themeStore: ThemeStore

    private let swatchColumns = [GridItem(.adaptive(minimum: 108, maximum: 150), spacing: 12)]

    var body: some View {
        Form {
            Picker("Appearance", selection: $themeStore.appearance) {
                ForEach(AppearanceMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Section("Theme") {
                LazyVGrid(columns: swatchColumns, spacing: 12) {
                    ForEach(Themes.all) { theme in
                        themeSwatch(theme)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
    }

    private func themeSwatch(_ theme: AppTheme) -> some View {
        let isSelected = themeStore.themeID == theme.id
        return Button {
            withAnimation(.snappy(duration: 0.15)) {
                themeStore.themeID = theme.id
            }
        } label: {
            VStack(spacing: 8) {
                Circle()
                    .fill(theme.gradient)
                    .frame(width: 38, height: 38)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                Text(theme.name)
                    .font(.callout)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? theme.primary.opacity(0.1) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.primary.opacity(0.7) : Color.primary.opacity(0.07),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Playback

struct PlaybackSettingsView: View {
    @AppStorage("defaultLayout") private var defaultLayout = CameraLayout.six.rawValue
    @AppStorage("galleryDensity") private var galleryDensity = GalleryDensity.regular.rawValue
    @AppStorage("eventPreRoll") private var eventPreRoll = 10.0
    @AppStorage("openingLeadIn") private var openingLeadIn = 60.0
    @AppStorage("galleryGrouping") private var galleryGrouping = ClipGrouping.day.rawValue
    @AppStorage("autoPlayOnOpen") private var autoPlayOnOpen = true

    var body: some View {
        Form {
            Picker("Default layout", selection: $defaultLayout) {
                ForEach(CameraLayout.allCases) { layout in
                    Text(layout.label).tag(layout.rawValue)
                }
            }
            Picker("Gallery card size", selection: $galleryDensity) {
                ForEach(GalleryDensity.allCases) { density in
                    Text(density.label).tag(density.rawValue)
                }
            }
            Picker("Group the gallery by", selection: $galleryGrouping) {
                ForEach(ClipGrouping.allCases) { option in
                    Text(option.label).tag(option.rawValue)
                }
            }

            Section {
                Toggle("Start playing when a clip opens", isOn: $autoPlayOnOpen)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Open clips before the event")
                        Spacer()
                        Text(openingLeadIn < 1
                             ? "At the start"
                             : "\(Int(openingLeadIn))s before")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $openingLeadIn, in: 0...300, step: 15)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Event jump run-up")
                        Spacer()
                        Text(eventPreRoll < 1
                             ? "None"
                             : "\(Int(eventPreRoll))s before")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(value: $eventPreRoll, in: 0...120, step: 1)
                }
            } footer: {
                Text("Tesla keeps around ten minutes of buffer either side of a Sentry trigger, so the moment you opened the clip for is usually minutes in. Clips with a flagged moment open just before it instead of at 0:00, and the event jump lands with enough run-up to see what led up to it. Clips with no event always open at the start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Keyboard") {
                shortcutRow("Space", "Play / pause")
                shortcutRow("← →", "Step one frame")
                shortcutRow("⇧ ← →", "Jump five seconds")
                shortcutRow("[ / ]", "Set the trim in / out point")
                shortcutRow("C", "Cycle the focused camera")
                shortcutRow("E", "Jump to just before the event")
                shortcutRow("F", "Full screen — hides everything but the picture")
                shortcutRow("Esc", "Leave full screen, or the clip if you're not in it")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ keys: String, _ description: String) -> some View {
        LabeledContent {
            Text(description)
                .foregroundStyle(.secondary)
        } label: {
            Text(keys)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
    }
}

// MARK: - HUD

struct HUDSettingsTab: View {
    @EnvironmentObject private var hudStore: HUDStore

    var body: some View {
        HStack(spacing: 0) {
            HUDSettingsPanel(config: $hudStore.config)
                .frame(width: 300)
            Divider()
            VStack(spacing: 0) {
                MapSettingsPanel(config: $hudStore.config)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                MapAdvancedSettingsPanel(config: $hudStore.config)
                Divider()
                Button("Reset All HUD Settings") { hudStore.reset() }
                    .controlSize(.small)
                    .padding(8)
            }
            .frame(width: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Updates

struct UpdatesSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @AppStorage("autoCheckUpdates") private var autoCheckUpdates = true

    var body: some View {
        Form {
            LabeledContent("Current version", value: AppVersion.current)
            Toggle("Check for updates at launch", isOn: $autoCheckUpdates)

            UpdateStatusView(updates: appState.updates)

            Link("View releases on GitHub", destination: UpdateChecker.releasesPage)
                .font(.callout)
        }
        .formStyle(.grouped)
    }
}

struct UpdateStatusView: View {
    @ObservedObject var updates: UpdateChecker
    @ObservedObject private var updater = SelfUpdater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button {
                    Task { await updates.check(userInitiated: true) }
                } label: {
                    if updates.status == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check Now")
                    }
                }
                .disabled(updates.status == .checking || updater.isBusy)

                switch updates.status {
                case .idle, .checking:
                    EmptyView()
                case .upToDate:
                    Label("You're up to date", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                case .noReleasesVisible:
                    Label(
                        "No releases visible — private repositories can't be checked anonymously",
                        systemImage: "eye.slash"
                    )
                    .foregroundStyle(.orange)
                case .updateAvailable(let version, let url):
                    Label("Version \(version) is available", systemImage: "arrow.down.circle.fill")
                        .foregroundStyle(.blue)
                    Button("Install & Relaunch") {
                        SelfUpdater.shared.install(from: url)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(updater.isBusy)
                case .failed(let message):
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                if let lastChecked = updates.lastChecked {
                    Text("Last checked \(lastChecked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            switch updater.phase {
            case .idle:
                EmptyView()
            case .downloading:
                Label {
                    Text("Downloading update…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
            case .installing:
                Label {
                    Text("Installing…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .foregroundStyle(.secondary)
            case .relaunching:
                Label("Relaunching…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Label(message, systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - About

struct AboutSettingsView: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            theme.glyph(size: 64)
            Text("SentryHub")
                .font(.title.weight(.bold))
            Text("Version \(AppVersion.current)")
                .foregroundStyle(.secondary)
            Text("An open-source, native macOS viewer for Tesla\nSentry, Saved, and Recent dashcam footage.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("GitHub", destination: URL(string: "https://github.com/\(UpdateChecker.repo)")!)
                Link("Releases", destination: UpdateChecker.releasesPage)
                Link(
                    "MIT License",
                    destination: URL(string: "https://github.com/\(UpdateChecker.repo)/blob/main/LICENSE")!
                )
            }
            .padding(.top, 6)
            SupportButtons()
                .padding(.top, 10)
            Text("Not affiliated with, endorsed by, or sponsored by Tesla, Inc.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 10)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}
