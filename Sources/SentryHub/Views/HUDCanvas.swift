import CoreLocation
import SwiftUI

/// The instrument overlay drawn on top of the camera grid.
///
/// One view serves both the live player and the exporter: the live overlay
/// renders it in a `ZStack`, and `ExportService` renders the very same view
/// through `ImageRenderer` at the export resolution. That is what makes the
/// export WYSIWYG — there is no second implementation to drift out of sync.
///
/// Every readout is fed from `TelemetrySample`, and every field is optional:
/// when a clip carries no telemetry the numbers render as `—` rather than being
/// invented.
struct HUDCanvas: View {
    enum Context {
        case live
        case export
    }

    let size: CGSize
    let config: HUDConfiguration
    let sample: TelemetrySample?
    let wallClock: Date
    let city: String?
    let route: [CLLocationCoordinate2D]
    let progress: Double
    /// What this clip can actually feed. Elements with no data are hidden when
    /// `config.autoHideUnavailable` is on, rather than drawn as em dashes.
    var availability: TelemetryAvailability = TelemetryAvailability()
    /// Map tiles for the mini map, when a snapshot could be produced.
    var mapBackdrop: MapBackdrop?
    /// The moment the car flagged, and why — drives the event flash.
    var event: (offset: TimeInterval, trigger: ClipTrigger?)?
    /// Play head, used to decide when the event flash is showing.
    var currentTime: TimeInterval = 0
    var context: Context = .live

    /// An element draws when it's switched on and either has data or auto-hide
    /// is off.
    private func shows(_ isOn: Bool, _ elementID: String) -> Bool {
        guard isOn else { return false }
        guard config.autoHideUnavailable else { return true }
        return availability.supports(elementID: elementID)
    }

    private var showsSpeedometer: Bool { shows(config.speedometer, "speedometer") }
    private var showsPedals: Bool { shows(config.pedals, "pedals") }
    private var showsSteering: Bool { shows(config.steeringWheel, "steeringWheel") }
    private var showsGear: Bool { shows(config.gearSelector, "gearSelector") }
    private var showsAutopilot: Bool { shows(config.autopilot, "autopilot") }
    private var showsGForce: Bool { shows(config.gForceIndicator, "gForce") }
    private var showsLocation: Bool { shows(config.location, "location") }
    private var showsTurnSignals: Bool { shows(config.turnSignals, "turnSignals") }
    private var showsCompass: Bool { shows(config.compassCoords, "compass") }

    /// The flash is only on screen for a couple of seconds either side of the
    /// moment the car flagged.
    private var eventFlashIntensity: Double {
        guard shows(config.eventFlash, "eventFlash"), let event else { return 0 }
        let distance = abs(currentTime - event.offset)
        guard distance < 2.0 else { return 0 }
        return 1 - (distance / 2.0)
    }

    /// Everything scales off a 1600×900 reference so the HUD looks the same at
    /// any window size or export resolution.
    private var unit: CGFloat {
        let base = min(size.width / 1600, size.height / 900)
        return max(0.45, base) * CGFloat(config.scale)
    }

    private var inset: CGFloat { 26 * unit }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            leftCluster
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(inset)

            topCentre
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, inset)

            if config.mapEnabled {
                miniMap
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: config.mapCorner.alignment)
                    .padding(inset)
            }

            eventFlash
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, inset + 62 * unit)

            timestampBlock
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(inset)

            bottomLeftReadouts
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(inset)

            if context == .export, config.watermark {
                Text("SentryHub")
                    .font(.system(size: 11 * unit, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 7 * unit)
                    .padding(.vertical, 3 * unit)
                    .background(
                        RoundedRectangle(cornerRadius: 5 * unit, style: .continuous)
                            .fill(Color.black.opacity(0.35))
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(inset)
                    .padding(.bottom, showsCompass || showsLocation ? 40 * unit : 0)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(config.enabled ? config.opacity : 0)
        .allowsHitTesting(false)
    }

    // MARK: - Left cluster

    @ViewBuilder
    private var leftCluster: some View {
        VStack(alignment: .leading, spacing: 14 * unit) {
            if showsGear || showsAutopilot {
                HStack(spacing: 10 * unit) {
                    if showsGear { gearSelector }
                    if showsAutopilot { autopilotPill }
                }
            }

            if showsSpeedometer || showsPedals || showsGForce {
                HStack(alignment: .top, spacing: 20 * unit) {
                    if showsPedals || showsGForce {
                        VStack(spacing: 10 * unit) {
                            if showsPedals { pedalMeter }
                            if showsGForce { gForceCluster }
                        }
                    }
                    if showsSpeedometer { speedReadout }
                }
            }

            if showsLocation, let city {
                Label(city, systemImage: "mappin.and.ellipse")
                    .font(.system(size: 13 * unit, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .shadow(color: .black.opacity(0.6), radius: 3 * unit)
            }
        }
    }

    private var gearSelector: some View {
        HStack(spacing: 4 * unit) {
            ForEach(TelemetrySample.Gear.allCases, id: \.self) { gear in
                let active = sample?.gear == gear
                Text(gear.rawValue)
                    .font(.system(size: 14 * unit, weight: active ? .bold : .medium,
                                  design: .rounded))
                    .foregroundStyle(active ? .white : .white.opacity(0.35))
                    .frame(width: 20 * unit)
            }
        }
        .padding(.horizontal, 8 * unit)
        .padding(.vertical, 5 * unit)
        .background(
            Capsule().fill(Color.black.opacity(0.42))
        )
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1 * unit))
    }

    private var autopilotPill: some View {
        let state = sample?.autopilotState ?? .off
        return Text(state.label)
            .font(.system(size: 12 * unit, weight: .semibold, design: .rounded))
            .tracking(1.4 * unit)
            .foregroundStyle(state.isEngaged ? Color(red: 0.35, green: 0.8, blue: 1.0) : .white.opacity(0.55))
            .padding(.horizontal, 12 * unit)
            .padding(.vertical, 5 * unit)
            .background(
                Capsule().fill(
                    state.isEngaged
                        ? Color(red: 0.10, green: 0.35, blue: 0.62).opacity(0.55)
                        : Color.black.opacity(0.42)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    state.isEngaged
                        ? Color(red: 0.35, green: 0.8, blue: 1.0).opacity(0.6)
                        : Color.white.opacity(0.12),
                    lineWidth: 1 * unit
                )
            )
    }

    /// Accelerator fills the upper half, brake the lower half — a single column
    /// split by a gap, matching the reference instrument cluster.
    private var pedalMeter: some View {
        let accelerator = sample?.accelerator
        let brake = sample?.brake
        let barHeight = 62 * unit
        let barWidth = 9 * unit

        return VStack(spacing: 5 * unit) {
            ZStack(alignment: .bottom) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(height: barHeight * CGFloat(min(max(accelerator ?? 0, 0), 1)))
            }
            .frame(width: barWidth, height: barHeight)

            ZStack(alignment: .top) {
                Capsule().fill(Color.white.opacity(0.16))
                Capsule()
                    .fill(Color(red: 1.0, green: 0.35, blue: 0.32))
                    .frame(height: barHeight * CGFloat(min(max(brake ?? 0, 0), 1)))
            }
            .frame(width: barWidth, height: barHeight)
        }
        .shadow(color: .black.opacity(0.5), radius: 3 * unit)
    }

    private var gForceCluster: some View {
        let longitudinal = sample?.accelerationLongitudinal
        let lateral = sample?.accelerationLateral
        let ring = 34 * unit
        let limit = 0.6

        return VStack(spacing: 4 * unit) {
            VStack(spacing: 1 * unit) {
                Text("ACC")
                    .font(.system(size: 8 * unit, weight: .semibold))
                    .tracking(1 * unit)
                    .foregroundStyle(.white.opacity(0.55))
                Text(longitudinal.map { Format.gForce(abs($0)) } ?? "—")
                    .font(.system(size: 11 * unit, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }

            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.22), lineWidth: 1 * unit)
                Circle()
                    .strokeBorder(Color.white.opacity(0.10), lineWidth: 1 * unit)
                    .padding(ring * 0.25)
                Circle()
                    .fill(Color.white)
                    .frame(width: 6 * unit, height: 6 * unit)
                    .offset(
                        x: ring / 2 * CGFloat(min(max((lateral ?? 0) / limit, -1), 1)),
                        y: -ring / 2 * CGFloat(min(max((longitudinal ?? 0) / limit, -1), 1))
                    )
            }
            .frame(width: ring, height: ring)

            Text(lateral.map { Format.gForce(abs($0)) } ?? "—")
                .font(.system(size: 11 * unit, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.9))
        }
        .shadow(color: .black.opacity(0.5), radius: 3 * unit)
    }

    private var speedReadout: some View {
        let speed = sample?.speedMetersPerSecond
        let units: [SpeedUnit] = {
            var result: [SpeedUnit] = []
            if config.showKMH { result.append(.kmh) }
            if config.showMPH { result.append(.mph) }
            if config.showMS { result.append(.ms) }
            return result
        }()

        return HStack(alignment: .top, spacing: 20 * unit) {
            ForEach(units) { unitOption in
                VStack(alignment: .leading, spacing: 0) {
                    Text(speed.map {
                        Format.speed($0, unit: unitOption, decimals: config.speedDecimals)
                    } ?? "—")
                        .font(.system(size: 52 * unit, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(unitOption.label)
                        .font(.system(size: 11 * unit, weight: .semibold))
                        .tracking(2 * unit)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }
        }
        .shadow(color: .black.opacity(0.65), radius: 5 * unit)
    }

    // MARK: - Top centre

    @ViewBuilder
    private var topCentre: some View {
        if showsSteering || showsTurnSignals {
            HStack(spacing: 16 * unit) {
                if showsTurnSignals {
                    signalArrow(systemName: "arrow.left", lit: sample?.turnSignalLeft == true)
                }
                if showsSteering {
                    ZStack {
                        Circle()
                            .fill(Color.black.opacity(0.42))
                            .frame(width: 42 * unit, height: 42 * unit)
                        Circle()
                            .strokeBorder(Color.white.opacity(0.14), lineWidth: 1 * unit)
                            .frame(width: 42 * unit, height: 42 * unit)
                        Image(systemName: "steeringwheel")
                            .font(.system(size: 23 * unit, weight: .regular))
                            .foregroundStyle(.white.opacity(0.92))
                            .rotationEffect(.degrees(sample?.steeringAngle ?? 0))
                    }
                }
                if showsTurnSignals {
                    signalArrow(systemName: "arrow.right", lit: sample?.turnSignalRight == true)
                }
            }
            .shadow(color: .black.opacity(0.5), radius: 4 * unit)
        }
    }

    /// HORN / IMPACT / MOTION as the play head crosses the event.
    @ViewBuilder
    private var eventFlash: some View {
        let intensity = eventFlashIntensity
        if intensity > 0, let event {
            let tint = Color(red: 1.0, green: 0.42, blue: 0.30)
            HStack(spacing: 8 * unit) {
                Image(systemName: event.trigger?.symbolName ?? "diamond.fill")
                    .font(.system(size: 17 * unit, weight: .semibold))
                Text(event.trigger?.badgeLabel ?? "EVENT")
                    .font(.system(size: 16 * unit, weight: .bold, design: .rounded))
                    .tracking(2 * unit)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16 * unit)
            .padding(.vertical, 8 * unit)
            .background(
                Capsule().fill(tint.opacity(0.30 + 0.45 * intensity))
            )
            .overlay(
                Capsule().strokeBorder(tint.opacity(0.4 + 0.6 * intensity), lineWidth: 1.5 * unit)
            )
            .shadow(color: tint.opacity(0.6 * intensity), radius: 14 * unit)
            .scaleEffect(1 + 0.06 * intensity)
            .opacity(0.35 + 0.65 * intensity)
        }
    }

    private func signalArrow(systemName: String, lit: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15 * unit, weight: .semibold))
            .foregroundStyle(lit ? Color(red: 0.35, green: 0.95, blue: 0.45) : .white.opacity(0.25))
            .frame(width: 30 * unit, height: 30 * unit)
            .background(
                Circle().fill(
                    lit
                        ? Color(red: 0.10, green: 0.35, blue: 0.16).opacity(0.65)
                        : Color.black.opacity(0.35)
                )
            )
    }

    // MARK: - Map

    private var miniMap: some View {
        let width = 210 * unit * config.mapSize.scale
        return RouteMiniMap(
            route: route,
            position: sample?.coordinate,
            heading: sample?.heading,
            progress: progress,
            config: config,
            backdrop: mapBackdrop,
            unit: unit
        )
        .frame(width: width, height: width * 0.62)
        .shadow(color: .black.opacity(0.45), radius: 6 * unit, y: 2 * unit)
    }

    // MARK: - Bottom readouts

    @ViewBuilder
    private var timestampBlock: some View {
        if config.date || config.time {
            VStack(alignment: .trailing, spacing: 2 * unit) {
                if config.date {
                    Text("\(config.dateFormat.weekday(from: wallClock)), \(config.dateFormat.string(from: wallClock))")
                        .font(.system(size: 13 * unit, weight: .medium, design: .monospaced))
                        .tracking(1.2 * unit)
                }
                if config.time {
                    Text(Self.clockFormatter.string(from: wallClock))
                        .font(.system(size: 22 * unit, weight: .medium, design: .monospaced))
                        .tracking(1.6 * unit)
                }
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 10 * unit)
            .padding(.vertical, 6 * unit)
            .background(
                RoundedRectangle(cornerRadius: 7 * unit, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
            .shadow(color: .black.opacity(0.55), radius: 4 * unit)
        }
    }

    @ViewBuilder
    private var bottomLeftReadouts: some View {
        if showsCompass {
            HStack(spacing: 10 * unit) {
                if let heading = sample?.heading {
                    HStack(spacing: 4 * unit) {
                        Image(systemName: "location.north.line.fill")
                            .rotationEffect(.degrees(heading))
                        Text("\(Format.compassPoint(heading)) \(Int(heading.rounded()))°")
                            .monospacedDigit()
                    }
                }
                if let coordinate = sample?.coordinate {
                    Text(Format.coordinateWithHemisphere(
                        latitude: coordinate.latitude, longitude: coordinate.longitude
                    ))
                    .monospacedDigit()
                } else {
                    Text("NO GPS")
                }
            }
            .font(.system(size: 12 * unit, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10 * unit)
            .padding(.vertical, 5 * unit)
            .background(
                RoundedRectangle(cornerRadius: 7 * unit, style: .continuous)
                    .fill(Color.black.opacity(0.35))
            )
            .shadow(color: .black.opacity(0.55), radius: 4 * unit)
        }
    }

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
