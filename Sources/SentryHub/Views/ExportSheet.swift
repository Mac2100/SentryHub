import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Trim + export: picks the range, the layout, the quality, and whether the HUD
/// is burned into the output.
struct ExportSheet: View {
    @ObservedObject var model: PlayerModel
    let config: HUDConfiguration

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @StateObject private var exporter = ExportService()

    @State private var includeHUD = true
    @State private var quality = ExportService.Options.Quality.high
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

    private var renderSize: CGSize {
        TileLayoutEngine.renderSize(
            layout: exportLayout,
            focused: model.focusedCamera,
            available: Set(model.clip.cameras),
            tileSize: quality.tileSize
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(theme.primary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Export Clip")
                        .font(.system(size: 16, weight: .semibold))
                    Text(model.clip.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(18)

            Divider()

            Form {
                Section("Range") {
                    Toggle("Use trim range", isOn: $useTrim)
                        .disabled(!model.hasTrim)
                    LabeledContent("From", value: Format.timecode(range.lowerBound))
                    LabeledContent("To", value: Format.timecode(range.upperBound))
                    LabeledContent("Length", value: Format.duration(outputDuration))
                    if !model.hasTrim {
                        Text("Set IN and OUT points on the timeline to export part of the clip.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Picture") {
                    Picker("Layout", selection: $exportLayout) {
                        ForEach(CameraLayout.allCases) { layout in
                            Text(layout.label).tag(layout)
                        }
                    }
                    Picker("Quality", selection: $quality) {
                        ForEach(ExportService.Options.Quality.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    LabeledContent(
                        "Output size",
                        value: "\(Int(renderSize.width)) × \(Int(renderSize.height))"
                    )
                }

                Section("Overlay") {
                    Toggle("Burn in the HUD", isOn: $includeHUD)
                    if includeHUD {
                        VStack(alignment: .leading, spacing: 3) {
                            Slider(value: $hudFrameRate, in: 1...15, step: 1) {
                                Text("HUD refresh")
                            }
                            Text("\(Int(hudFrameRate)) HUD updates per second — telemetry usually samples at 1–4 Hz, so a low value keeps exports fast.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                if exporter.isBusy || isFinished {
                    Section("Progress") {
                        progressRow
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            HStack(spacing: 10) {
                Button("Export Still Frame…") {
                    Task { await exportStill() }
                }
                .disabled(exporter.isBusy)

                Spacer()

                if exporter.isBusy {
                    Button("Cancel Export", role: .destructive) { exporter.cancel() }
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }

                Button("Export Video…") {
                    Task { await startExport() }
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .keyboardShortcut(.defaultAction)
                .disabled(exporter.isBusy)
            }
            .padding(18)
        }
        .frame(width: 520, height: 620)
        .onAppear { exportLayout = model.layout }
    }

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
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: value)
                    .tint(theme.primary)
                Text("Rendering HUD frames… \(Int(value * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .exporting(let value):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: value)
                    .tint(theme.primary)
                Text("Encoding video… \(Int(value * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
        case .cancelled:
            Label("Export cancelled", systemImage: "xmark.circle")
                .foregroundStyle(.secondary)
        case .idle:
            EmptyView()
        }
    }

    // MARK: - Actions

    private func startExport() async {
        guard let destination = savePanel(
            suggestedName: "\(model.clip.name)-\(exportLayout.rawValue).mp4",
            type: .mpeg4Movie
        ) else { return }

        await exporter.export(
            clip: model.clip,
            telemetry: model.telemetry,
            config: config,
            options: .init(
                includeHUD: includeHUD,
                quality: quality,
                hudFrameRate: hudFrameRate,
                layout: exportLayout,
                focused: model.focusedCamera
            ),
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
