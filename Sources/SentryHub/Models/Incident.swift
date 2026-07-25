import Foundation

/// Where an incident stands. A dashcam clip usually gets kept because something
/// has to *happen* next — a claim, a report, a conversation with a neighbour —
/// so the library tracks that rather than pretending every clip is just a video.
enum IncidentStatus: String, CaseIterable, Codable, Identifiable, Hashable {
    case open
    case submitted
    case closed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .open: return "Open"
        case .submitted: return "Submitted"
        case .closed: return "Closed"
        }
    }

    var symbolName: String {
        switch self {
        case .open: return "circle.dashed"
        case .submitted: return "paperplane.fill"
        case .closed: return "checkmark.circle.fill"
        }
    }
}

/// A named group of clips: one event, from every angle and every camera that
/// caught part of it, plus the notes that make it useful six months later.
struct Incident: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    /// Claim number, police report number — whatever the outside world calls it.
    var reference: String = ""
    var notes: String = ""
    var status: IncidentStatus = .open
    var createdAt: Date = Date()
    /// `Clip.ID` values. Deliberately not paths: a clip keeps its identity when
    /// it's copied to this Mac or when the drive is remounted somewhere else.
    var clipIDs: [String] = []

    var isEmpty: Bool { clipIDs.isEmpty }
}
