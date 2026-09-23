import Foundation

/// Applies document edits to the latest saved value and publishes them only
/// after the manifest write succeeds.
@MainActor
enum DocumentEditing {
    enum Failure: LocalizedError {
        case unavailable
        case speakerUnavailable
        case save(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "This recording is no longer available."
            case .speakerUnavailable:
                return "This speaker is no longer available, or speaker analysis is still running."
            case .save(let message):
                return message
            }
        }
    }

    @discardableResult
    static func updateTitle(_ title: String, documentID: UUID, library: LibraryStore) throws -> Bool {
        try persist(documentID: documentID, library: library) { document in
            guard !title.isEmpty, document.title != title else { return false }
            document.title = title
            return true
        }
    }

    /// Returns the previous text only when a new value was saved.
    static func updateSegmentText(
        _ text: String, segmentID: UUID, documentID: UUID, library: LibraryStore
    ) throws -> String? {
        var previous: String?
        let saved = try persist(documentID: documentID, library: library) { document in
            guard let index = document.segments.firstIndex(where: { $0.id == segmentID }) else {
                throw Failure.unavailable
            }
            guard document.segments[index].text != text else { return false }
            previous = document.segments[index].text
            document.segments[index].text = text
            return true
        }
        return saved ? previous : nil
    }

    @discardableResult
    static func appendNote(_ note: MeetingNote, documentID: UUID, library: LibraryStore) throws -> Bool {
        try persist(documentID: documentID, library: library) { document in
            var notes = document.notes ?? []
            notes.append(note)
            document.notes = notes
            return true
        }
    }

    @discardableResult
    static func updateNoteText(
        _ text: String, noteID: UUID, documentID: UUID, library: LibraryStore
    ) throws -> Bool {
        try persist(documentID: documentID, library: library) { document in
            guard let index = document.notes?.firstIndex(where: { $0.id == noteID }) else {
                throw Failure.unavailable
            }
            guard document.notes?[index].text != text else { return false }
            document.notes?[index].text = text
            return true
        }
    }

    @discardableResult
    static func deleteNote(_ noteID: UUID, documentID: UUID, library: LibraryStore) throws -> Bool {
        try persist(documentID: documentID, library: library) { document in
            guard document.notes?.contains(where: { $0.id == noteID }) == true else { return false }
            document.notes?.removeAll { $0.id == noteID }
            return true
        }
    }

    /// Returns the number of changed segments after they have been saved.
    static func replaceAll(
        _ search: String,
        with replacement: String,
        options: String.CompareOptions,
        documentID: UUID,
        library: LibraryStore
    ) throws -> Int {
        guard !search.isEmpty else { return 0 }
        var count = 0
        let saved = try persist(documentID: documentID, library: library) { document in
            for index in document.segments.indices {
                let oldText = document.segments[index].text
                let newText = oldText.replacingOccurrences(of: search, with: replacement, options: options)
                if newText != oldText {
                    document.segments[index].text = newText
                    count += 1
                }
            }
            return count > 0
        }
        return saved ? count : 0
    }

    @discardableResult
    static func applySpeakerEdit(
        documentID: UUID,
        library: LibraryStore,
        undoManager: UndoManager?,
        actionName: String,
        onUndoFailure: @escaping (String) -> Void,
        change: (inout ScribeDocument) -> Bool
    ) throws -> Bool {
        var snapshot: SpeakerEditingSnapshot?
        let saved = try persist(documentID: documentID, library: library) { document in
            guard document.speakerAnalysisStatus != .running else { throw Failure.speakerUnavailable }
            document.normalizeSpeakerIdentities()
            snapshot = SpeakerEditingSnapshot(document: document)
            return change(&document)
        }
        if saved, let snapshot, let undoManager {
            registerSpeakerUndo(
                snapshot,
                library: library,
                undoManager: undoManager,
                actionName: actionName,
                onFailure: onUndoFailure
            )
        }
        return saved
    }

    /// Renames a speaker, optionally saving them as a person first. The
    /// availability check, the saved-person write, the Recording edit, and
    /// undo registration all happen behind this one call, so a failed
    /// Recording save cannot leave an orphaned saved person behind. A saved
    /// person this call did not create (an existing pick, or a
    /// case-insensitive name match inside `SavedPeopleStore.add`) is never
    /// removed.
    @discardableResult
    static func renameSpeaker(
        _ speakerID: UUID,
        to name: String,
        savedPersonID: UUID?,
        savePerson: Bool,
        documentID: UUID,
        library: LibraryStore,
        savedPeople: SavedPeopleStore,
        undoManager: UndoManager?,
        actionName: String,
        onUndoFailure: @escaping (String) -> Void
    ) throws -> Bool {
        guard let document = library.document(id: documentID) else { throw Failure.unavailable }
        guard document.speakerAnalysisStatus != .running,
              document.speakers?.contains(where: { $0.id == speakerID && !$0.isMicrophone }) == true
        else { throw Failure.speakerUnavailable }

        var personID = savedPersonID
        var createdPersonID: UUID?
        if savePerson {
            let existingIDs = Set(savedPeople.people.map(\.id))
            let person = try savedPeople.add(name: name)
            personID = person.id
            if !existingIDs.contains(person.id) { createdPersonID = person.id }
        }

        do {
            return try applySpeakerEdit(
                documentID: documentID,
                library: library,
                undoManager: undoManager,
                actionName: actionName,
                onUndoFailure: onUndoFailure,
                change: { $0.renameSpeaker(id: speakerID, to: name, savedPersonID: personID) }
            )
        } catch {
            if let createdPersonID {
                try? savedPeople.remove(id: createdPersonID)
            }
            throw error
        }
    }

    /// Runs speaker-identity normalization on the latest document and saves
    /// it only when normalization actually changed something. Intended for
    /// opening a document, where a save failure is background housekeeping
    /// rather than the result of a user action.
    @discardableResult
    static func normalizeSpeakerIdentitiesOnOpen(documentID: UUID, library: LibraryStore) throws -> Bool {
        try persist(documentID: documentID, library: library) { document in
            document.normalizeSpeakerIdentities()
            return true
        }
    }

    /// Saves edited segment text and returns the dictation corrections
    /// eligible to suggest to the user, or nil when the current suggestions
    /// should be left alone (the text did not change, there weren't 1-3
    /// corrections, or the edit changed the word count).
    ///
    /// The existing-rule comparison duplicates
    /// `ReplacementStore.addRule(original:replacement:)`, which is not
    /// reachable from here without changing a file this change does not own.
    static func commitSegmentEdit(
        _ text: String,
        segmentID: UUID,
        documentID: UUID,
        library: LibraryStore,
        existingRules: [TextReplacement]
    ) throws -> [(wrong: String, right: String)]? {
        guard let oldText = try updateSegmentText(
            text, segmentID: segmentID, documentID: documentID, library: library
        ) else { return nil }
        let corrections = DictationDiff.proposedCorrections(original: oldText, edited: text)
        guard (1...3).contains(corrections.count),
              oldText.split(whereSeparator: { $0.isWhitespace }).count
                == text.split(whereSeparator: { $0.isWhitespace }).count else { return nil }
        return corrections.filter { correction in
            !existingRules.contains(where: { rule in
                rule.original.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(correction.wrong) == .orderedSame
                    && rule.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
                    .caseInsensitiveCompare(correction.right) == .orderedSame
            })
        }
    }

    @discardableResult
    private static func persist(
        documentID: UUID,
        library: LibraryStore,
        change: (inout ScribeDocument) throws -> Bool
    ) throws -> Bool {
        guard var document = library.document(id: documentID) else { throw Failure.unavailable }
        let before = document
        guard try change(&document), document != before else { return false }
        guard library.update(document) else {
            throw Failure.save(library.lastError ?? "The recording could not be saved.")
        }
        return true
    }

    private static func registerSpeakerUndo(
        _ snapshot: SpeakerEditingSnapshot,
        library: LibraryStore,
        undoManager: UndoManager,
        actionName: String,
        onFailure: @escaping (String) -> Void
    ) {
        undoManager.registerUndo(withTarget: library) { [weak undoManager] store in
            guard let undoManager else { return }
            do {
                var redo: SpeakerEditingSnapshot?
                let saved = try persist(documentID: snapshot.documentID, library: store) { document in
                    redo = SpeakerEditingSnapshot(document: document)
                    return document.restoreSpeakerEdits(snapshot)
                }
                if saved, let redo {
                    registerSpeakerUndo(
                        redo,
                        library: store,
                        undoManager: undoManager,
                        actionName: actionName,
                        onFailure: onFailure
                    )
                }
            } catch {
                let message = error.localizedDescription
                DispatchQueue.main.async {
                    registerSpeakerUndo(
                        snapshot,
                        library: store,
                        undoManager: undoManager,
                        actionName: actionName,
                        onFailure: onFailure
                    )
                    onFailure(message)
                }
            }
        }
        undoManager.setActionName(actionName)
    }
}
