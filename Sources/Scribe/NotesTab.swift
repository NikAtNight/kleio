import SwiftUI

/// Notes pinned to moments in a document's audio.
struct NotesTab: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var playback: PlaybackController
    let document: ScribeDocument

    @State private var newNoteText = ""
    @State private var editError: String?

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
        .alert("Note not saved", isPresented: Binding(
            get: { editError != nil },
            set: { if !$0 { editError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(editError ?? "")
        }
    }

    private func addNote() {
        let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        do {
            try DocumentEditing.appendNote(
                MeetingNote(time: currentTime, text: text),
                documentID: document.id,
                library: library
            )
            newNoteText = ""
        } catch {
            editError = error.localizedDescription
        }
    }

    private func updateNote(_ noteID: UUID, text: String) -> Bool {
        do {
            _ = try DocumentEditing.updateNoteText(
                text, noteID: noteID, documentID: document.id, library: library
            )
            return true
        } catch {
            editError = error.localizedDescription
            return false
        }
    }

    private func deleteNote(_ noteID: UUID) {
        do {
            _ = try DocumentEditing.deleteNote(noteID, documentID: document.id, library: library)
        } catch {
            editError = error.localizedDescription
        }
    }
}

private struct NoteTabRow: View {
    let note: MeetingNote
    let onSeek: () -> Void
    let onEdit: (String) -> Bool
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
        if onEdit(text) { isEditing = false }
    }
}
