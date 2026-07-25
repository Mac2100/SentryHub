import SwiftUI

// MARK: - Anchors

/// Collects the on-screen rectangle of every view tagged with `.tourAnchor`.
///
/// Anchors rather than hard-coded coordinates: the highlight then tracks the
/// real control through window resizes, theme changes, and chips appearing and
/// disappearing as a library gains new kinds of clip.
struct TourAnchorKey: PreferenceKey {
    static var defaultValue: [TourStop: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [TourStop: Anchor<CGRect>],
        nextValue: () -> [TourStop: Anchor<CGRect>]
    ) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Marks this view as the thing the walkthrough points at for `stop`.
    func tourAnchor(_ stop: TourStop) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [stop: $0] }
    }
}

// MARK: - Overlay

/// Dims everything, cuts a hole around the feature being described, and puts a
/// short note beside it.
struct TourOverlay: View {
    let anchors: [TourStop: Anchor<CGRect>]

    @ObservedObject private var tour = TourController.shared
    @Environment(\.appTheme) private var theme

    private static let calloutWidth: CGFloat = 330
    private static let gap: CGFloat = 16

    var body: some View {
        GeometryReader { proxy in
            if let stop = tour.currentStop {
                let target = anchors[stop].map { spotlight(for: proxy[$0], in: proxy.size) }

                ZStack(alignment: .topLeading) {
                    scrim(around: target, in: proxy.size)
                    if let target { ring(target) }
                    callout(stop, target: target, in: proxy.size)
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.25), value: tour.index)
    }

    /// The rectangle to cut out, padded a little and never taller than a
    /// screenful of gallery — a spotlight the size of the whole clip list
    /// darkens nothing and leaves the note nowhere to sit.
    private func spotlight(for rect: CGRect, in size: CGSize) -> CGRect {
        let padded = rect.insetBy(dx: -10, dy: -10)
        let maxHeight = min(size.height * 0.45, 320)
        guard padded.height > maxHeight else { return padded }
        return CGRect(x: padded.minX, y: padded.minY, width: padded.width, height: maxHeight)
    }

    // MARK: Scrim

    /// One even-odd filled path: the whole window minus the spotlight. Cheaper
    /// and more predictable than masking with blend modes, and it leaves the
    /// highlighted control at full brightness rather than tinted.
    private func scrim(around target: CGRect?, in size: CGSize) -> some View {
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            if let target {
                path.addRoundedRect(
                    in: target,
                    cornerSize: CGSize(width: radius(for: target), height: radius(for: target)),
                    style: .continuous
                )
            }
        }
        .fill(Color.black.opacity(0.66), style: FillStyle(eoFill: true))
        .contentShape(Rectangle())
        // Clicking anywhere in the dark moves on, and nothing underneath is
        // reachable while the tour is up.
        .onTapGesture { tour.next() }
    }

    /// A capsule for wide controls, a circle for square ones — the shape follows
    /// what's being pointed at rather than forcing everything into a ring.
    private func radius(for rect: CGRect) -> CGFloat {
        min(rect.height / 2, 22)
    }

    private func ring(_ target: CGRect) -> some View {
        RoundedRectangle(cornerRadius: radius(for: target), style: .continuous)
            .strokeBorder(theme.primary, lineWidth: 2.5)
            .shadow(color: theme.primary.opacity(0.8), radius: 12)
            .frame(width: target.width, height: target.height)
            .offset(x: target.minX, y: target.minY)
            .allowsHitTesting(false)
    }

    // MARK: Callout

    private func callout(_ stop: TourStop, target: CGRect?, in size: CGSize) -> some View {
        let position = calloutOrigin(for: target, in: size)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(stop.title)
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                Text("\((tour.index ?? 0) + 1) of \(tour.stepCount)")
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            Text(stop.note)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Skip") { tour.finish() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)

                Spacer()

                if !tour.isFirstStep {
                    Button("Back") { tour.back() }
                        .controlSize(.small)
                }
                Button(tour.isLastStep ? "Done" : "Next") { tour.next() }
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: Self.calloutWidth, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(theme.primary.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.35), radius: 20, y: 8)
        .offset(x: position.x, y: position.y)
    }

    /// Below the highlight when there's room, above it when there isn't, and
    /// always far enough inside the window to be fully readable.
    private func calloutOrigin(for target: CGRect?, in size: CGSize) -> CGPoint {
        let estimatedHeight: CGFloat = 168
        guard let target else {
            return CGPoint(
                x: (size.width - Self.calloutWidth) / 2,
                y: (size.height - estimatedHeight) / 2
            )
        }

        let below = target.maxY + Self.gap
        let above = target.minY - Self.gap - estimatedHeight
        let y = below + estimatedHeight < size.height ? below : max(Self.gap, above)

        let preferredX = target.midX - Self.calloutWidth / 2
        let x = min(max(Self.gap, preferredX), size.width - Self.calloutWidth - Self.gap)

        return CGPoint(x: x, y: y)
    }
}
