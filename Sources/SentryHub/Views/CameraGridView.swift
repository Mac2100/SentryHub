import AVFoundation
import AppKit
import SwiftUI

/// Hosts an `AVPlayerLayer` — SwiftUI's `VideoPlayer` brings its own transport
/// chrome, which would fight the shared controls.
struct PlayerLayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerHostView {
        let view = PlayerHostView(frame: .zero)
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ nsView: PlayerHostView, context: Context) {
        if nsView.playerLayer.player !== player {
            nsView.playerLayer.player = player
        }
    }

    final class PlayerHostView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            let host = CALayer()
            host.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            host.addSublayer(playerLayer)
            layer = host
            wantsLayer = true
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not used")
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Traces a highlight around a tile: a segment of stroke travelling the
/// perimeter plus a breathing glow. Used to point at the camera that saw the
/// event, which a static border never communicated.
struct TileTrace: View {
    let tint: Color
    /// Speeds up and brightens near the event.
    var urgency: Double = 0

    @State private var phase: CGFloat = 0
    @State private var breathe = false

    var body: some View {
        let period = 3.2 - 1.8 * min(max(urgency, 0), 1)
        ZStack {
            Rectangle()
                .strokeBorder(tint.opacity(0.35 + 0.35 * urgency), lineWidth: 1.5)

            Rectangle()
                .inset(by: 1)
                .trim(from: phase, to: phase + 0.16)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                )
                .shadow(color: tint.opacity(0.9), radius: 6)

            Rectangle()
                .strokeBorder(tint.opacity(breathe ? 0.55 : 0.12), lineWidth: 5)
                .blur(radius: 6)
                .animation(
                    .easeInOut(duration: 1.1).repeatForever(autoreverses: true),
                    value: breathe
                )
        }
        .allowsHitTesting(false)
        .onAppear {
            breathe = true
            withAnimation(.linear(duration: period).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
    }
}

/// One camera tile: the feed, its label, and the watermark badge — or a
/// placeholder when the car didn't record that angle.
struct CameraTile: View {
    let camera: CameraAngle?
    let player: AVPlayer?
    let isFocused: Bool
    /// The camera the car says triggered the event — and only while the trace
    /// is warranted and the play head is near the moment it marks.
    let isEventCamera: Bool
    /// 0…1, rising as the play head approaches the event.
    let eventUrgency: Double
    let showWatermark: Bool
    let onSelect: () -> Void

    var body: some View {
        ZStack {
            Color.black

            if let player {
                PlayerLayerView(player: player)
            } else if let camera {
                Text("\(placeholderName(camera)) - No video")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.28))
            }

            if let camera {
                VStack {
                    if showWatermark, player != nil {
                        HStack {
                            Spacer()
                            Text("SentryHub")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.55))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                                        .fill(Color.black.opacity(0.35))
                                )
                        }
                    }
                    Spacer()
                    if player != nil {
                        Text(camera.shortLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(Color.black.opacity(0.42))
                            )
                    }
                }
                .padding(8)
            }
        }
        .overlay {
            if isEventCamera, player != nil {
                TileTrace(
                    tint: Color(red: 1.0, green: 0.42, blue: 0.30),
                    urgency: eventUrgency
                )
            } else {
                Rectangle()
                    .strokeBorder(
                        // A thin tint for the selected tile; the loud highlight
                        // is reserved for the camera that saw the event.
                        isFocused ? Color.accentColor.opacity(0.55) : Color.white.opacity(0.06),
                        lineWidth: isFocused ? 1.5 : 1
                    )
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onSelect() }
    }

    /// `L-Pillar`, `R-Pillar`, … as written in the placeholder text.
    private func placeholderName(_ camera: CameraAngle) -> String {
        switch camera {
        case .leftPillar: return "L-Pillar"
        case .rightPillar: return "R-Pillar"
        case .leftRepeater: return "L-Repeater"
        case .rightRepeater: return "R-Repeater"
        case .front: return "Front"
        case .back: return "Rear"
        }
    }
}

/// Lays the tiles out for the selected layout and overlays the HUD.
struct CameraGridView: View {
    @ObservedObject var model: PlayerModel
    let config: HUDConfiguration

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black

                let tiles = TileLayoutEngine.tiles(
                    layout: model.layout,
                    focused: model.focusedCamera,
                    available: Set(model.availableCameras),
                    in: geometry.size
                )

                ForEach(tiles) { tile in
                    CameraTile(
                        camera: tile.camera,
                        player: tile.camera.flatMap { model.players[$0] },
                        isFocused: tile.camera == model.focusedCamera && model.layout != .single,
                        isEventCamera: model.showsEventTrace
                            && tile.camera != nil
                            && tile.camera == model.clip.event?.triggerCamera,
                        eventUrgency: model.eventUrgency,
                        showWatermark: config.watermark
                    ) {
                        if let camera = tile.camera { model.focusedCamera = camera }
                    }
                    .frame(width: tile.rect.width, height: tile.rect.height)
                    .position(x: tile.rect.midX, y: tile.rect.midY)
                }

                HUDCanvas(
                    size: geometry.size,
                    config: config,
                    sample: model.currentSample,
                    wallClock: model.wallClock,
                    city: model.clip.city,
                    route: model.telemetry.route,
                    progress: model.duration > 0 ? model.currentTime / model.duration : 0,
                    availability: model.availability,
                    mapBackdrop: model.mapBackdrop,
                    context: .live
                )
            }
        }
    }
}
