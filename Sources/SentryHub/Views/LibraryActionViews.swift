import SwiftUI

/// Progress for a running copy or delete. Copying a Sentry event off a USB 2.0
/// dashcam drive takes real seconds, so it needs to be visible rather than a
/// frozen window.
struct TransferBanner: View {
    @ObservedObject private var local = LocalLibrary.shared
    @Environment(\.appTheme) private var theme

    var body: some View {
        if let transfer = local.transfer {
            HStack(spacing: 12) {
                ProgressView(value: transfer.fraction)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(transfer.label) — \(transfer.completed + 1) of \(transfer.total)")
                        .font(.system(size: 12, weight: .semibold))
                    Text(transfer.currentName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(minWidth: 200, alignment: .leading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(theme.primary.opacity(0.3), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 14, y: 5)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

/// Names a selection in one go. One clip takes the name as typed; several get
/// numbered, which is what makes a five-camera pile-up reviewable later.
struct BulkRenameSheet: View {
    let count: Int
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(count == 1 ? "Rename clip" : "Rename \(count) clips")
                .font(.system(size: 16, weight: .semibold))

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(commit)

            Text(count == 1
                 ? "The files on the drive keep the name the car gave them."
                 : "They'll be numbered \u{201C}\(example) 1\u{201D}, \u{201C}\(example) 2\u{201D}, and so on, in the order they're shown. The files on the drive keep the names the car gave them.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Clear Custom Names", role: .destructive) {
                    onCommit("")
                    dismiss()
                }
                .buttonStyle(.link)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .onAppear { focused = true }
    }

    private var example: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "Parking lot" : trimmed
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

/// Files a selection into an incident — an existing one, or a new one named on
/// the spot.
struct AddToIncidentSheet: View {
    let clipIDs: [Clip.ID]

    @ObservedObject private var incidents = IncidentStore.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.appTheme) private var theme
    @State private var newTitle = ""
    @State private var selectedID: Incident.ID?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add \(clipIDs.count) clip\(clipIDs.count == 1 ? "" : "s") to an incident")
                .font(.system(size: 16, weight: .semibold))

            if !incidents.incidents.isEmpty {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(incidents.incidents) { incident in
                            Button {
                                selectedID = incident.id
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: incident.status.symbolName)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(incident.title)
                                            .font(.system(size: 13, weight: .medium))
                                        Text("\(incident.clipIDs.count) clip\(incident.clipIDs.count == 1 ? "" : "s")")
                                            .font(.system(size: 11))
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    if selectedID == incident.id {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(theme.primary)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(selectedID == incident.id
                                              ? theme.primary.opacity(0.12) : Color.clear)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 180)

                Divider()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Or start a new one")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
                TextField("Incident name", text: $newTitle)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onChange(of: newTitle) { _, value in
                        if !value.isEmpty { selectedID = nil }
                    }
                    .onSubmit(commit)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(theme.primary)
                    .disabled(!canCommit)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if incidents.incidents.isEmpty { focused = true }
        }
    }

    private var canCommit: Bool {
        selectedID != nil || !newTitle.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func commit() {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let incident = incidents.create(title: trimmed, clipIDs: clipIDs)
            ToastCenter.shared.show(
                "Created “\(incident.title)”",
                detail: "\(clipIDs.count) clip\(clipIDs.count == 1 ? "" : "s") filed.",
                style: .success
            )
        } else if let selectedID {
            let added = incidents.add(clipIDs, to: selectedID)
            let title = incidents.incident(selectedID)?.title ?? "the incident"
            ToastCenter.shared.show(
                added == 0 ? "Already filed" : "Added \(added) to “\(title)”",
                detail: added == 0 ? "Every selected clip was already in it." : nil,
                style: added == 0 ? .info : .success
            )
        }
        dismiss()
    }
}
