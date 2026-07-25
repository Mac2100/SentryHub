import SwiftUI

/// The transport bar's timeline: filled progress, trim region, and a draggable
/// play head. Custom-drawn rather than a `Slider` so the trim range and the
/// segment boundaries can be shown on the same track.
struct TimelineScrubber: View {
    let duration: TimeInterval
    let currentTime: TimeInterval
    let trimStart: TimeInterval
    let trimEnd: TimeInterval
    /// Boundaries between the clip's ~60 s segments, in seconds.
    let segmentMarks: [TimeInterval]
    /// Where the triggering event happened, if it falls inside the footage.
    var eventMark: TimeInterval?
    let tint: Color
    let onScrub: (TimeInterval) -> Void
    let onScrubEnded: () -> Void

    @State private var isDragging = false

    private let trackHeight: CGFloat = 5
    private let knobSize: CGFloat = 13

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let progress = fraction(currentTime)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.16))
                    .frame(height: trackHeight)

                if hasTrim {
                    Capsule()
                        .fill(Color.white.opacity(0.10))
                        .frame(
                            width: max(0, width * (fraction(trimEnd) - fraction(trimStart))),
                            height: trackHeight
                        )
                        .offset(x: width * fraction(trimStart))
                }

                Capsule()
                    .fill(tint)
                    .frame(width: max(0, width * progress), height: trackHeight)

                ForEach(Array(segmentMarks.enumerated()), id: \.offset) { _, mark in
                    Rectangle()
                        .fill(Color.white.opacity(0.35))
                        .frame(width: 1, height: trackHeight + 4)
                        .offset(x: width * fraction(mark))
                }

                if hasTrim {
                    trimHandle.offset(x: width * fraction(trimStart) - 1)
                    trimHandle.offset(x: width * fraction(trimEnd) - 1)
                }

                if let eventMark {
                    Image(systemName: "diamond.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(Color(red: 1.0, green: 0.42, blue: 0.30))
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(x: width * fraction(eventMark) - 4)
                        .help("Event")
                }

                Circle()
                    .fill(Color.white)
                    .frame(width: isDragging ? knobSize + 3 : knobSize,
                           height: isDragging ? knobSize + 3 : knobSize)
                    .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                    .offset(x: max(0, width * progress - knobSize / 2))
            }
            .frame(height: max(knobSize, trackHeight) + 6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        let ratio = min(max(value.location.x / max(width, 1), 0), 1)
                        onScrub(ratio * duration)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onScrubEnded()
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isDragging)
        }
        .frame(height: 20)
    }

    private var trimHandle: some View {
        Capsule()
            .fill(Color.yellow.opacity(0.9))
            .frame(width: 3, height: trackHeight + 8)
    }

    private var hasTrim: Bool {
        trimStart > 0.01 || trimEnd < duration - 0.01
    }

    private func fraction(_ time: TimeInterval) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(time / duration, 0), 1))
    }
}
