import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Trim + export settings, laid out like the reference dialog: resolution,
/// frame rate, quality, and format, with the HUD burned in on request.
struct ExportSheet: View {
    @ObservedObject var model: PlayerModel
    let config: HUDConfiguration

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @StateObject private var exporter = ExportService()

    @State private var includeHUD = true
    @State private var resolution = ExportService.Options.Resolution.p1080
    @State private var frameRate = ExportService.Options.FrameRate.fps30
    @State private var bitrate = ExportService.Options.Bitrate.mbps8
    @State private var codec = ExportService.Options.Codec.h264
    @State private var hudFrameRate: Double = 5
    @State private var useTrim = true
    @State private var exportLayout: CameraLayout = .six

    private var range: ClosedRange<TimeInterval> {
        useTrim && model.trimEnd > model.trimStart
            ? model.trimStart...model.trimEnd
            : 0...max(model.duration, 0.5)
    }

    private var outputDuration: TimeInterval {
        range.upperBound - range.lowerBound
    }

    private var options: ExportService.Options {
        .init(
            includeHUD: includeHUD,
            resolution: resolution,
            frameRate: frameRate,
            bitrate: bitrate,
            codec: codec,
            hudFrameRate: hudFrameRate,
            layout: exportLayout,
            focused: model.focusedCamera
        )
    }

    private var renderSize: CGSize {
        ExportService.renderSize(for: options, available: Set(model.clip.cameras))
    }

    /// Rough finished-file size from the chosen bitrate.
    private var estimatedBytes: Int64 {
        Int64(Double(bitrate.bitsPerSecond) / 8 * outputDuration)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    modeCard
                    durationRow

                    HStack(alignment: .top, spacing: 22) {
                        optionGroup(symbol: "display", title: "Resolution") {
                            PillPicker(
                                options: ExportService.Options.Resolution.allCases
                                    .map { ($0, $0.label) },
                                selection: $resolution,
                                tint: theme.primary
                            )
                        }
                        optionGroup(symbol: "gauge.with.dots.needle.bottom.50percent",
                                    title: "Frame Rate") {
                            PillPicker(
                                options: ExportService.Options.FrameRate.allCases
                                    .map { ($0, $0.label) },
                                selection: $frameRate,
                                tint: theme.primary
                            )
                        }
                    }

                    HStack(alignment: .top, spacing: 22) {
                        optionGroup(symbol: "sparkles", title: "Quality") {
                            PillPicker(
                                options: ExportService.Options.Bitrate.allCases
                                    .map { ($0, $0.label) },
                                selection: $bitrate,
                                tint: theme.primary
                            )
                        }
                        optionGroup(symbol: "film", title: "Format") {
                            PillPicker(
                                options: ExportService.Options.Codec.allCases
                                    .map { ($0, $0.label) },
                                selection: $codec,
                                tint: theme.primary,
                                badge: "mp4"
                            )
                        }
                    }

                    Divider()

                    optionGroup(symbol: "square.grid.3x2", title: "Layout") {
                        Picker("", selection: $exportLayout) {
                            ForEach(CameraLayout.allCases) { layout in
                                Text(layout.label).tag(layout)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width: 190)
                    }

                    overlaySection

                    if exporter.isBusy || isFinished {
                        Divider()
                        progressRow
                    }
                }
                .padding(20)
            }

            Divider()
            footer
        }
        .frame(width: 560, height: 660)
        .onAppear { exportLayout = model.layout }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(theme.primary)
                .frame(width: 34, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(theme.primary.opacity(0.16))
                )
            VStack(alignment: .leading, spacing: 1) {
                Text("Export Settings")
                    .font(.system(size: 17, weight: .semibold))
                Text("Duration: \(Format.duration(outputDuration))")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .disabled(exporter.isBusy)
        }
        .padding(18)
    }

    /// The counterpart to the reference's "Browser capture" notice — worth
    /// stating plainly, because this export is the opposite of a screen grab.
    private var modeCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cpu")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.green)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Color.green.opacity(0.15)))

            VStack(alignment: .leading, spacing: 6) {
                Text("CURRENT MODE")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.green)
                Text("Direct re-encode")
                    .font(.system(size: 14, weight: .semibold))
                Text("Frames are composed and encoded straight from the source files, so the result doesn't depend on playback keeping up or on this window staying in front. You can keep using the Mac while it runs.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.green.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.green.opacity(0.28), lineWidth: 1)
        )
    }

    private var durationRow: some View {
        VStack(spacing: 0) {
            row("Duration", Format.duration(outputDuration))
            Divider().padding(.leading, 14)
            row("Range", "\(Format.timecode(range.lowerBound)) – \(Format.timecode(range.upperBound))")
            Divider().padding(.leading, 14)
            row("Output size", "\(Int(renderSize.width)) × \(Int(renderSize.height))")
            Divider().padding(.leading, 14)
            row("Estimated file", Format.bytes(estimatedBytes))
        }
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            if model.hasTrim {
                Toggle("Use trim range", isOn: $useTrim)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .labelsHidden()
                    .padding(12)
                    .help("Export only the range between the IN and OUT points")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func optionGroup<Content: View>(
        symbol: String, title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var overlaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Burn in the HUD", isOn: $includeHUD)
                .toggleStyle(.switch)
                .controlSize(.small)

            if includeHUD {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("HUD refresh")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("\(Int(hudFrameRate)) Hz")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $hudFrameRate, in: 1...15, step: 1)
                        .controlSize(.small)
                    Text("Telemetry usually samples at 1–4 Hz, so a low value keeps exports fast without losing detail.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if !config.mapIncludeInExport {
                    Label("The mini map is excluded (Map → Include In Export).",
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.telemetry.isEmpty {
                    Label("This clip has no telemetry — the HUD will show the clock only.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - Progress / footer

    private var isFinished: Bool {
        if case .finished = exporter.phase { return true }
        if case .failed = exporter.phase { return true }
        return false
    }

    @ViewBuilder
    private var progressRow: some View {
        switch exporter.phase {
        case .preparing:
            Label {
                Text("Preparing composition…")
            } icon: {
                ProgressView().controlSize(.small)
            }
        case .renderingOverlay(let value):
            labelledProgress("Rendering HUD frames…", value)
        case .exporting(let value):
            labelledProgress("Encoding video…", value)
        case .finished(let url):
            HStack {
                Label("Saved \(url.lastPathComponent)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                .controlSize(.small)
            }
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
        case .cancelled:
            Label("Export cancelled", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    private func labelledProgress(_ title: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: value)
                .tint(theme.primary)
            Text("\(title) \(Int(value * 100))%")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("Export Still Frame…") {
                Task { await exportStill() }
            }
            .disabled(exporter.isBusy)

            Spacer()

            if exporter.isBusy {
                Button("Cancel Export", role: .destructive) { exporter.cancel() }
            } else {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }

            Button {
                Task { await startExport() }
            } label: {
                Label("Start Export", systemImage: "square.and.arrow.down")
                    .padding(.horizontal, 4)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)
            .keyboardShortcut(.defaultAction)
            .disabled(exporter.isBusy)
        }
        .padding(18)
    }

    // MARK: - Actions

    private func startExport() async {
        guard let destination = savePanel(
            suggestedName: "\(model.clip.name)-\(exportLayout.rawValue).\(codec.fileExtension)",
            type: .mpeg4Movie
        ) else { return }

        await exporter.export(
            clip: model.clip,
            telemetry: model.telemetry,
            config: config,
            availability: model.availability,
            options: options,
            range: range,
            to: destination
        )
    }

    private func exportStill() async {
        guard let destination = savePanel(
            suggestedName: "\(model.clip.name)-\(Int(model.currentTime)).png",
            type: .png
        ) else { return }
        do {
            try await ExportService.exportStill(
                clip: model.clip,
                telemetry: model.telemetry,
                config: config,
                availability: model.availability,
                layout: exportLayout,
                focused: model.focusedCamera,
                time: model.currentTime,
                to: destination
            )
            ToastCenter.shared.show("Frame saved", detail: destination.lastPathComponent)
        } catch {
            ToastCenter.shared.show(
                "Couldn't save the frame", detail: error.localizedDescription, style: .error
            )
        }
    }

    private func savePanel(suggestedName: String, type: UTType) -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedName
        panel.allowedContentTypes = [type]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(
            for: .moviesDirectory, in: .userDomainMask
        ).first
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }
}

/// The reference dialog's paired option pills.
struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value
    let tint: Color
    var badge: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.value) { option in
                let isSelected = selection == option.value
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 6) {
                        Text(option.label)
                            .font(.system(size: 13, weight: .medium))
                        if isSelected, let badge {
                            Text(".\(badge)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.primary.opacity(0.10))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isSelected ? tint.opacity(0.18) : Color.primary.opacity(0.04))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .strokeBorder(
                                isSelected ? tint.opacity(0.65) : Color.primary.opacity(0.09),
                                lineWidth: 1
                            )
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            }
        }
    }
}
