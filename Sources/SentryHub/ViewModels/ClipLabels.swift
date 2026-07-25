import Foundation
import SwiftUI

/// User-supplied names for clips.
///
/// Renaming deliberately never touches the drive. Tesla's folder name is a
/// timestamp the scanner parses for the clock, the timeline zero point, and the
/// telemetry sidecar lookup, so it has to stay exactly as the car wrote it —
/// and Recent clips aren't in a folder of their own to rename anyway. The label
/// lives here instead, keyed by category and original name so it survives the
/// drive being remounted at a different path.
@MainActor
final class ClipLabels: ObservableObject {
    static let shared = ClipLabels()

    private static let defaultsKey = "clipLabels"

    @Published private var labels: [String: String]

    private init() {
        labels = UserDefaults.standard.dictionary(forKey: Self.defaultsKey)
            as? [String: String] ?? [:]
    }

    private static func key(for clip: Clip) -> String {
        "\(clip.category.rawValue)/\(clip.name)"
    }

    /// The custom name, when one was set.
    func label(for clip: Clip) -> String? {
        let value = labels[Self.key(for: clip)]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// What to show: the custom name when there is one, otherwise the car's.
    func title(for clip: Clip) -> String {
        label(for: clip) ?? clip.name
    }

    /// Passing nil, an empty string, or the original name clears the label.
    func set(_ label: String?, for clip: Clip) {
        let key = Self.key(for: clip)
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed == clip.name {
            labels.removeValue(forKey: key)
        } else {
            labels[key] = trimmed
        }
        UserDefaults.standard.set(labels, forKey: Self.defaultsKey)
    }
}
