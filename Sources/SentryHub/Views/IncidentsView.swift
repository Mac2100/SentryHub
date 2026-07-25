import SwiftUI

/// The Incidents tab: clips grouped into the thing that actually happened.
///
/// A dashcam library is only half the job — the other half is "the person who
/// hit my mirror on the 3rd", which is four clips from three cameras plus a
/// claim number. That's what an incident is.
struct IncidentsView: View {
    @ObservedObject var library: LibraryStore
    @ObservedObject private var incidents = IncidentStore.shared
    @Environment(\.appTheme) private var theme

    @State private var selectedID: Incident.ID?
    @State private var pendingDeletion: Incident?

    private var selected: Incident? {
        guard let selectedID else { return incidents.incidents.first }
        return incidents.incident(selectedID) ?? incidents.incidents.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionCaption(text: "INCIDENTS")

            if incidents.incidents.isEmpty {
                emptyState
            } else {
                HStack(alignment: .top, spacing: 16) {
                    incidentList
                        .frame(width: 260)
                    if let incident = selected {
                        IncidentDetailView(
                            incident: incident,
                            library: library,
                            onDelete: { pendingDeletion = incident }
                        )
                        // A fresh view per incident, so switching selection
                        // flushes the edits in progress and reloads the drafts.
                        .id(incident.id)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
        }
        .alert(
            pendingDeletion.map { "Delete “\($0.title)”?" } ?? "",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { incident in
            Button("Delete", role: .destructive) {
                incidents.delete(incident.id)
                selectedID = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: { incident in
            Text(
                "The incident and its notes are deleted. The "
                + "\(incident.clipIDs.count) clip\(incident.clipIDs.count == 1 ? "" : "s") "
                + "in it are left exactly where they are."
            )
        }
    }

    // MARK: - List

    private var incidentList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                let incident = incidents.create(title: "New Incident")
                selectedID = incident.id
            } label: {
                Label("New Incident", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(theme.primary)

            VStack(spacing: 4) {
                ForEach(incidents.incidents) { incident in
                    row(incident)
                }
            }
        }
    }

    private func row(_ incident: Incident) -> some View {
        let isSelected = selected?.id == incident.id
        let saved = incident.clipIDs.filter { LocalLibrary.shared.contains($0) }.count

        return Button {
            selectedID = incident.id
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Image(systemName: incident.status.symbolName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(isSelected ? theme.primary : .secondary)
                    Text(incident.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Spacer()
                }
                HStack(spacing: 6) {
                    Text("\(incident.clipIDs.count) clip\(incident.clipIDs.count == 1 ? "" : "s")")
                    Text("·")
                    Text(saved == incident.clipIDs.count && !incident.isEmpty
                         ? "all on this Mac"
                         : "\(saved) on this Mac")
                        .foregroundStyle(
                            saved == incident.clipIDs.count ? Color.secondary : Color.orange
                        )
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? theme.primary.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(
                        isSelected ? theme.primary.opacity(0.5) : Color.primary.opacity(0.07),
                        lineWidth: 1
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "folder.badge.person.crop")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No incidents yet.")
                .font(.callout.weight(.medium))
            Text("Select clips in the Clips tab and choose **Add to Incident** to group everything\nthat belongs to one event — every angle, every camera — under a name you'll recognise later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("New Incident") {
                let incident = incidents.create(title: "New Incident")
                selectedID = incident.id
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - Detail

struct IncidentDetailView: View {
    let incident: Incident
    @ObservedObject var library: LibraryStore
    let onDelete: () -> Void

    @ObservedObject private var incidents = IncidentStore.shared
    @ObservedObject private var local = LocalLibrary.shared
    @EnvironmentObject private var appState: AppState
    @Environment(\.appTheme) private var theme

    // The text fields edit local drafts rather than writing through to the
    // store. Write-through would persist the whole file on every keystroke, and
    // republish the list underneath the cursor while it's being typed in.
    @State private var draftTitle = ""
    @State private var draftReference = ""
    @State private var draftNotes = ""
    @FocusState private var focusedField: Field?

    private enum Field: Hashable { case title, reference, notes }

    /// The clips this incident points at, in the order they were filed. Ones the
    /// library can't currently see are reported rather than silently dropped.
    private var clips: [Clip] {
        incident.clipIDs.compactMap { id in library.clips.first { $0.id == id } }
    }

    private var missingIDs: [Clip.ID] {
        let present = Set(library.clips.map(\.id))
        return incident.clipIDs.filter { !present.contains($0) }
    }

    private var unsaved: [Clip] {
        clips.filter { !$0.storage.isSavedLocally }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            fields
            summary
            clipStrip
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        )
        .onAppear(perform: loadDrafts)
        // Fires when the selection changes, because the caller gives this view
        // an identity of its own — so the edits in progress are saved first.
        .onDisappear(perform: commitDrafts)
        .onChange(of: focusedField) { previous, _ in
            if previous != nil { commitDrafts() }
        }
    }

    private func loadDrafts() {
        draftTitle = incident.title
        draftReference = incident.reference
        draftNotes = incident.notes
    }

    private func commitDrafts() {
        let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        var updated = incident
        updated.title = title.isEmpty ? "Untitled Incident" : title
        updated.reference = draftReference
        updated.notes = draftNotes
        guard updated != incident else { return }
        incidents.update(updated)
    }

    // MARK: Fields

    private var fields: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Incident name", text: $draftTitle)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .bold))
                    .focused($focusedField, equals: .title)
                    .onSubmit(commitDrafts)

                Picker("", selection: binding(\.status)) {
                    ForEach(IncidentStatus.allCases) { status in
                        Label(status.label, systemImage: status.symbolName).tag(status)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 140)

                Menu {
                    Button("Delete Incident…", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }

            HStack(spacing: 10) {
                Image(systemName: "number")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                TextField("Claim or report number", text: $draftReference)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focusedField, equals: .reference)
                    .onSubmit(commitDrafts)
                Text(incident.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }

            TextEditor(text: $draftNotes)
                .font(.system(size: 12))
                .frame(height: 70)
                .focused($focusedField, equals: .notes)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(0.05))
                )
                .overlay(alignment: .topLeading) {
                    if draftNotes.isEmpty {
                        Text("What happened, who was involved, what you've sent and to whom…")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 12)
                            .allowsHitTesting(false)
                    }
                }
        }
    }

    // MARK: Summary

    private var summary: some View {
        HStack(spacing: 10) {
            factChip(
                symbol: "video",
                text: "\(incident.clipIDs.count) clip\(incident.clipIDs.count == 1 ? "" : "s")"
            )
            if !clips.isEmpty {
                factChip(symbol: "clock", text: Format.duration(clips.reduce(0) { $0 + $1.duration }))
                factChip(symbol: "externaldrive", text: Format.bytes(clips.reduce(0) { $0 + $1.byteCount }))
            }
            if let span = dateSpan {
                factChip(symbol: "calendar", text: span)
            }

            Spacer()

            if !unsaved.isEmpty {
                // The whole point of an incident is that it's still there in six
                // months. Clips left on the drive are not.
                Button {
                    Task {
                        let drive = unsaved.compactMap { library.driveCopy(of: $0.id) }
                        await local.save(drive)
                    }
                } label: {
                    Label("Save \(unsaved.count) to This Mac", systemImage: "arrow.down.circle")
                        .font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.primary)
                .disabled(local.transfer != nil)
                .help("These clips only exist on the drive — they'll go when it's unplugged or the car overwrites them.")
            } else if !clips.isEmpty {
                Label("Every clip is on this Mac", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.green)
            }
        }
    }

    private var dateSpan: String? {
        let dates = clips.map(\.startDate).sorted()
        guard let first = dates.first else { return nil }
        guard let last = dates.last, !Calendar.current.isDate(first, inSameDayAs: last) else {
            return first.formatted(date: .abbreviated, time: .omitted)
        }
        return "\(first.formatted(.dateTime.month(.abbreviated).day())) – "
            + last.formatted(date: .abbreviated, time: .omitted)
    }

    private func factChip(symbol: String, text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
    }

    // MARK: Clips

    private var clipStrip: some View {
        VStack(alignment: .leading, spacing: 10) {
            if clips.isEmpty && missingIDs.isEmpty {
                Text("No clips filed here yet. Select some in the Clips tab and choose Add to Incident.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 240), spacing: 14)],
                    spacing: 14
                ) {
                    ForEach(clips) { clip in
                        ClipCard(clip: clip, density: .compact) {
                            appState.open(clip)
                        }
                        .contextMenu {
                            Button("Remove from Incident") {
                                incidents.removeClip(clip.id, from: incident.id)
                            }
                        }
                    }
                }

                ForEach(missingIDs, id: \.self) { id in
                    missingRow(id)
                }
            }
        }
    }

    /// A clip the incident remembers but the library can't currently see —
    /// the drive is unplugged, or it was deleted from both places.
    private func missingRow(_ id: Clip.ID) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(id.split(separator: "/").last.map(String.init) ?? id)
                    .font(.system(size: 12, weight: .medium))
                Text("Not in the library right now — connect the drive it came from, or it's been deleted.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Forget") {
                incidents.removeClip(id, from: incident.id)
            }
            .buttonStyle(.link)
            .font(.system(size: 11))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.orange.opacity(0.08))
        )
    }

    // MARK: Binding

    /// Edits write straight through to the store, which persists on every
    /// change — there's no Save button to forget to press.
    private func binding<Value>(
        _ keyPath: WritableKeyPath<Incident, Value>
    ) -> Binding<Value> {
        Binding(
            get: { incident[keyPath: keyPath] },
            set: { newValue in
                var copy = incident
                copy[keyPath: keyPath] = newValue
                incidents.update(copy)
            }
        )
    }
}
