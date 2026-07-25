import Foundation
import SwiftUI

/// Incidents, saved as one JSON file next to the local library.
///
/// Small enough to rewrite whole on every change — there are tens of these, not
/// thousands, and the alternative is a database for no reason.
@MainActor
final class IncidentStore: ObservableObject {
    static let shared = IncidentStore()

    @Published private(set) var incidents: [Incident] = []

    private let fileURL: URL

    private init() {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        fileURL = base
            .appendingPathComponent("SentryHub", isDirectory: true)
            .appendingPathComponent("incidents.json")
        load()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        incidents = (try? decoder.decode([Incident].self, from: data)) ?? []
        sort()
    }

    private func persist() {
        sort()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try encoder.encode(incidents).write(to: fileURL, options: .atomic)
        } catch {
            ToastCenter.shared.show(
                "Couldn't save incidents", detail: error.localizedDescription, style: .error
            )
        }
    }

    /// Open work first, then newest.
    private func sort() {
        incidents.sort { a, b in
            if (a.status == .closed) != (b.status == .closed) { return b.status == .closed }
            return a.createdAt > b.createdAt
        }
    }

    // MARK: - Editing

    @discardableResult
    func create(title: String, clipIDs: [Clip.ID] = []) -> Incident {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let incident = Incident(
            title: trimmed.isEmpty ? "Untitled Incident" : trimmed,
            clipIDs: clipIDs
        )
        incidents.append(incident)
        persist()
        return incident
    }

    func update(_ incident: Incident) {
        guard let index = incidents.firstIndex(where: { $0.id == incident.id }) else { return }
        incidents[index] = incident
        persist()
    }

    func delete(_ id: Incident.ID) {
        incidents.removeAll { $0.id == id }
        persist()
    }

    /// Adds clips, skipping any already in the incident and keeping the order
    /// they were added in.
    func add(_ clipIDs: [Clip.ID], to id: Incident.ID) -> Int {
        guard let index = incidents.firstIndex(where: { $0.id == id }) else { return 0 }
        let existing = Set(incidents[index].clipIDs)
        let fresh = clipIDs.filter { !existing.contains($0) }
        guard !fresh.isEmpty else { return 0 }
        incidents[index].clipIDs.append(contentsOf: fresh)
        persist()
        return fresh.count
    }

    func removeClip(_ clipID: Clip.ID, from id: Incident.ID) {
        guard let index = incidents.firstIndex(where: { $0.id == id }) else { return }
        incidents[index].clipIDs.removeAll { $0 == clipID }
        persist()
    }

    // MARK: - Lookups

    func incident(_ id: Incident.ID) -> Incident? {
        incidents.first { $0.id == id }
    }

    /// Incidents a clip belongs to — shown as a chip on the clip's card.
    func incidents(containing clipID: Clip.ID) -> [Incident] {
        incidents.filter { $0.clipIDs.contains(clipID) }
    }

    var openCount: Int {
        incidents.filter { $0.status != .closed }.count
    }
}
