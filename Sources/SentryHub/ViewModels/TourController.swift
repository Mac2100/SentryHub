import Foundation
import SwiftUI

/// One stop on the first-run walkthrough.
///
/// The order here is the order they're shown in — roughly the order you'd meet
/// them working down the screen.
enum TourStop: String, CaseIterable, Identifiable {
    case tabs
    case stats
    case filters
    case storage
    case presentation
    case gallery

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tabs: return "Clips and Incidents"
        case .stats: return "The library at a glance"
        case .filters: return "Where a clip sits, and why"
        case .storage: return "What survives unplugging"
        case .presentation: return "Three ways to look"
        case .gallery: return "Pick clips, then act on them"
        }
    }

    var note: String {
        switch self {
        case .tabs:
            return "Clips is everything the car recorded. Incidents is where you group the clips that belong to one event — under a name, a claim number, and notes."
        case .stats:
            return "How many clips there are, how many are safely on this Mac, what the car flagged, and how recent the newest one is."
        case .filters:
            return "A folder says where a clip sits; the chips beside it say why the car kept it. Sentry spots things by itself; Saved is what you asked it to keep."
        case .storage:
            return "The dashcam drive is a rolling buffer — the car overwrites it, and it all goes when you unplug. Clips you save to this Mac stay in the library either way."
        case .presentation:
            return "Grid to recognise footage by sight, List to scan hundreds of clips by their facts, Map to see where each one happened."
        case .gallery:
            return "Click a card to open every camera at once. Hover one and a checkbox appears — tick it to save a batch to this Mac, file it into an incident, rename it, or clear it off the drive."
        }
    }
}

/// Runs the walkthrough, and remembers that it has.
@MainActor
final class TourController: ObservableObject {
    static let shared = TourController()

    private static let seenKey = "walkthroughSeenVersion"

    /// Bump this when stops are added, so people who have already seen the tour
    /// are shown it again rather than never meeting the new parts.
    static let version = 1

    /// Index into `TourStop.allCases`; nil when the tour isn't running.
    @Published private(set) var index: Int?

    private init() {}

    var isRunning: Bool { index != nil }

    var currentStop: TourStop? {
        guard let index, TourStop.allCases.indices.contains(index) else { return nil }
        return TourStop.allCases[index]
    }

    var stepCount: Int { TourStop.allCases.count }
    var isFirstStep: Bool { index == 0 }
    var isLastStep: Bool { index == TourStop.allCases.count - 1 }

    /// Shown once, on the first launch that reaches the library.
    func startIfUnseen() {
        guard !isRunning,
              UserDefaults.standard.integer(forKey: Self.seenKey) < Self.version else { return }
        index = 0
    }

    func start() {
        index = 0
    }

    func next() {
        guard let current = index else { return }
        if current + 1 < TourStop.allCases.count {
            index = current + 1
        } else {
            finish()
        }
    }

    func back() {
        guard let current = index, current > 0 else { return }
        index = current - 1
    }

    /// Ends the tour and stops it coming back.
    func finish() {
        index = nil
        UserDefaults.standard.set(Self.version, forKey: Self.seenKey)
    }
}
