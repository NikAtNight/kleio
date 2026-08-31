import SwiftUI

/// Notes pinned to moments in a document's audio.
struct NotesTab: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let document: ScribeDocument

    @State private var newNoteText = ""

    private var currentTime: TimeInterval {
        playback.documentID == document.id ? playback.currentTime : 0
    }

    private var notes: [MeetingNote] {
        (document.notes ?? []).sorted { $0.time < $1.time }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("Add a note at \(currentTime.clockString)…", text: $newNoteText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addNote)
                .padding(20)

            if notes.isEmpty {
                ContentUnavailableView {
                    Label("No notes", systemImage: "pencil.line")
                } description: {
                    Text("Notes you take during recording, or add here, appear pinned to their moment.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(notes) { note in
                            NoteTabRow(
                                note: note,
                                onSeek: { playback.seek(to: note.time) },
                                onEdit: { updateNote(note.id, text: $0) },
                                onDelete: { deleteNote(note.id) }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func addNote() {
        let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, var updatedDocument = library.document(id: document.id) else { return }
        var updatedNotes = updatedDocument.notes ?? []
        updatedNotes.append(MeetingNote(time: currentTime, text: text))
        updatedDocument.notes = updatedNotes
        library.update(updatedDocument)
        newNoteText = ""
    }

    private func updateNote(_ noteID: UUID, text: String) {
        guard var updatedDocument = library.document(id: document.id),
              let index = updatedDocument.notes?.firstIndex(where: { $0.id == noteID }),
              updatedDocument.notes?[index].text != text else { return }
        updatedDocument.notes?[index].text = text
        library.update(updatedDocument)
    }

    private func deleteNote(_ noteID: UUID) {
        guard var updatedDocument = library.document(id: document.id) else { return }
        updatedDocument.notes?.removeAll { $0.id == noteID }
        library.update(updatedDocument)
    }
}

private struct NoteTabRow: View {
    let note: MeetingNote
    let onSeek: () -> Void
    let onEdit: (String) -> Void
    let onDelete: () -> Void

    @State private var text = ""
    @State private var isEditing = false
    @State private var isHovered = false
    @FocusState private var focused: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Button(action: onSeek) {
                Text(note.time.clockString)
                    .font(Theme.metaValue)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("Jump playback here")
            .frame(width: 56, alignment: .trailing)

            if isEditing {
                TextField("Note", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit(commitEdit)
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commitEdit() }
                    }
            } else {
                Text(LocalizedStringKey(note.text))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 6) {
                Button("Edit") {
                    isEditing = true
                    DispatchQueue.main.async { focused = true }
                }
                .buttonStyle(.borderless)

                Button("Delete", role: .destructive, action: onDelete)
                    .buttonStyle(.borderless)
            }
            .opacity(isHovered || isEditing ? 1 : 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.cardBackground))
        .onHover { isHovered = $0 }
        .onAppear { text = note.text }
        .onChange(of: note.text) { _, newValue in
            if !focused { text = newValue }
        }
    }

    private func commitEdit() {
        onEdit(text)
        isEditing = false
    }
}
