import SwiftUI

// MARK: - Shared row chrome

/// One `icon — label — control` row, as used by both settings popovers.
struct SettingRow<Control: View>: View {
    let symbol: String
    let label: String
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13))
                .lineLimit(1)
            Spacer(minLength: 12)
            control()
        }
        .padding(.vertical, 5)
    }
}

struct SettingToggleRow: View {
    let symbol: String
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        SettingRow(symbol: symbol, label: label) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.green)
        }
    }
}

/// Compact segmented picker used for Speed Decimals / Date Format / Map Style.
struct MiniSegments<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.4)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(
                                    selection == option.value
                                        ? Color.green.opacity(0.30)
                                        : Color.primary.opacity(0.06)
                                )
                        )
                        .foregroundStyle(selection == option.value ? Color.primary : Color.secondary)
                        .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct SliderRow: View {
    let caption: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(format(value))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
                .controlSize(.mini)
        }
        .padding(.vertical, 4)
    }
}

private struct PanelCaption: View {
    let text: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        HStack {
            Text(text)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.tertiary)
            Spacer()
            if let action {
                Button(action.label, action: action.run)
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - HUD panel

/// The **HUD** popover — every element toggle, the unit selection, and the
/// interface opacity / size sliders.
struct HUDSettingsPanel: View {
    @Binding var config: HUDConfiguration

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelCaption(text: "HUD ELEMENTS", action: (label: "Show All", run: {
                    withAnimation(.snappy(duration: 0.15)) { config.showAllElements() }
                }))
                .padding(.bottom, 6)

                ForEach(HUDConfiguration.elementOrder) { element in
                    SettingToggleRow(
                        symbol: element.symbol,
                        label: element.label,
                        isOn: binding(for: element.keyPath)
                    )
                }

                Divider().padding(.vertical, 8)

                ForEach(HUDConfiguration.unitOrder) { element in
                    SettingToggleRow(
                        symbol: element.symbol,
                        label: element.label,
                        isOn: binding(for: element.keyPath)
                    )
                }

                SettingRow(
                    symbol: "gauge.with.dots.needle.bottom.50percent",
                    label: "Speed Decimals"
                ) {
                    MiniSegments(
                        options: [(0, "0"), (1, "1"), (2, "2")],
                        selection: $config.speedDecimals
                    )
                }

                SettingRow(symbol: "calendar", label: "Date Format") {
                    MiniSegments(
                        options: HUDDateFormat.allCases.map { ($0, $0.label) },
                        selection: $config.dateFormat
                    )
                }

                Divider().padding(.vertical, 8)

                SliderRow(
                    caption: "INTERFACE OPACITY",
                    value: $config.opacity,
                    range: 0.2...1.0
                ) { "\(Int(($0 * 100).rounded()))%" }

                SliderRow(
                    caption: "SIZE",
                    value: $config.scale,
                    range: 0.6...1.6
                ) { "\(Int(($0 * 100).rounded()))%" }

                Divider().padding(.vertical, 8)

                SettingToggleRow(
                    symbol: "signature", label: "Watermark", isOn: $config.watermark
                )

                if !config.anySpeedUnit {
                    Label("Turn on at least one speed unit to see the readout.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(.top, 6)
                }
            }
            .padding(14)
        }
        .frame(width: 300, height: 520)
    }

    private func binding(for keyPath: WritableKeyPath<HUDConfiguration, Bool>) -> Binding<Bool> {
        Binding(
            get: { config[keyPath: keyPath] },
            set: { config[keyPath: keyPath] = $0 }
        )
    }
}

// MARK: - Map panel

/// Status dot used by the Map popover's boolean rows — green when on, dim when
/// off — matching the reference design rather than a switch.
struct DotToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Circle()
                .fill(isOn ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
                .padding(5)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// Value chip that advances to the next case when clicked (Theme, Rotation).
struct CycleChip<Value>: View where Value: CaseIterable & Equatable,
                                    Value.AllCases: RandomAccessCollection {
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        Button {
            let all = Array(Value.allCases)
            guard let index = all.firstIndex(of: selection), !all.isEmpty else { return }
            selection = all[(index + 1) % all.count]
        } label: {
            Text(label(selection))
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.09))
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }
}

/// The **Map** popover: Visible, Theme, Rotation, Zoom, Size, Route Overview.
/// The less-used options live in Settings → HUD so this stays as compact as the
/// reference design.
struct MapSettingsPanel: View {
    @Binding var config: HUDConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelCaption(text: "MAP SETTINGS")
                .padding(.bottom, 8)

            SettingRow(symbol: "eye", label: "Visible") {
                DotToggle(isOn: $config.mapEnabled)
            }

            SettingRow(symbol: "map", label: "Theme") {
                CycleChip(selection: $config.mapTheme) { $0.chipLabel }
            }

            SettingRow(symbol: "location.circle", label: "Rotation") {
                CycleChip(selection: $config.mapRotation) { $0.chipLabel }
            }

            SliderRow(caption: "ZOOM", value: $config.mapZoomLevel, range: 8...20) {
                "\(Int($0.rounded()))"
            }

            SettingRow(symbol: "arrow.up.left.and.arrow.down.right", label: "Size") {
                MiniSegments(
                    options: MapSize.allCases.map { ($0, $0.chipLabel) },
                    selection: $config.mapSize
                )
            }

            SettingRow(
                symbol: "point.topleft.down.curvedto.point.bottomright.up",
                label: "Route Overview"
            ) {
                DotToggle(isOn: $config.mapRouteOverview)
            }
        }
        .padding(14)
    }
}

/// The map options that don't fit the compact popover, shown in Settings → HUD.
struct MapAdvancedSettingsPanel: View {
    @Binding var config: HUDConfiguration

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PanelCaption(text: "MAP — MORE", action: (label: "Reset", run: {
                    let defaults = HUDConfiguration.default
                    config.mapEnabled = defaults.mapEnabled
                    config.mapTheme = defaults.mapTheme
                    config.mapRotation = defaults.mapRotation
                    config.mapZoomLevel = defaults.mapZoomLevel
                    config.mapSize = defaults.mapSize
                    config.mapRouteOverview = defaults.mapRouteOverview
                    config.mapCorner = defaults.mapCorner
                    config.mapTrackStyle = defaults.mapTrackStyle
                    config.mapShowEndpoints = defaults.mapShowEndpoints
                    config.mapOpacity = defaults.mapOpacity
                    config.mapShowLabel = defaults.mapShowLabel
                    config.mapIncludeInExport = defaults.mapIncludeInExport
                }))
                .padding(.bottom, 6)

                SettingRow(symbol: "square.on.square", label: "Position") {
                    HStack(spacing: 3) {
                        ForEach(HUDCorner.allCases) { corner in
                            Button {
                                config.mapCorner = corner
                            } label: {
                                Image(systemName: corner.symbolName)
                                    .font(.system(size: 12, weight: .medium))
                                    .padding(3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(
                                                config.mapCorner == corner
                                                    ? Color.green.opacity(0.30)
                                                    : Color.primary.opacity(0.06)
                                            )
                                    )
                                    .contentShape(RoundedRectangle(cornerRadius: 5))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(
                                config.mapCorner == corner ? Color.primary : Color.secondary
                            )
                            .help(corner.label)
                        }
                    }
                }

                SettingRow(
                    symbol: "point.topleft.down.curvedto.point.bottomright.up",
                    label: "Route Line"
                ) {
                    MiniSegments(
                        options: [
                            (MapTrackStyle.full, "ALL"),
                            (MapTrackStyle.traveled, "DRIVEN"),
                            (MapTrackStyle.hidden, "OFF")
                        ],
                        selection: $config.mapTrackStyle
                    )
                }

                SettingToggleRow(
                    symbol: "mappin.and.ellipse",
                    label: "Start & End Markers",
                    isOn: $config.mapShowEndpoints
                )
                SettingToggleRow(
                    symbol: "textformat.size.smaller",
                    label: "Show \u{201C}MAP\u{201D} Label",
                    isOn: $config.mapShowLabel
                )
                SettingToggleRow(
                    symbol: "square.and.arrow.up",
                    label: "Include In Export",
                    isOn: $config.mapIncludeInExport
                )

                Divider().padding(.vertical, 8)

                SliderRow(caption: "OPACITY", value: $config.mapOpacity, range: 0.2...1.0) {
                    "\(Int(($0 * 100).rounded()))%"
                }
            }
            .padding(14)
        }
    }
}
