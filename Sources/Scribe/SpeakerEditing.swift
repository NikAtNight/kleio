import Foundation

struct SpeakerEditingSnapshot {
    fileprivate struct SegmentSpeaker {
        let segmentID: UUID
        let speakerID: UUID?
        let name: String?
    }

    let documentID: UUID
    fileprivate let speakers: [DocumentSpeaker]?
    fileprivate let assignments: [SegmentSpeaker]
    fileprivate let knownSpeakers: [String]?
    fileprivate let editsApplied: Bool?
    fileprivate let expectedRemoteSpeakerCount: Int?

    init(document: ScribeDocument) {
        documentID = document.id
        speakers = document.speakers
        assignments = document.segments.map {
            SegmentSpeaker(segmentID: $0.id, speakerID: $0.speakerID, name: $0.speaker)
        }
        knownSpeakers = document.knownSpeakers
        editsApplied = document.speakerEditsApplied
        expectedRemoteSpeakerCount = document.expectedRemoteSpeakerCount
    }
}

extension ScribeDocument {
    @discardableResult
    mutating func addRemoteSpeaker(name: String) -> UUID? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        var edited = self
        edited.normalizeSpeakerIdentities()
        if let existing = edited.speakers?.first(where: { !$0.isMicrophone && $0.name == name }) { return existing.id }
        edited.preserveDetectedSpeakers()
        let speaker = DocumentSpeaker(name: name)
        edited.speakers?.append(speaker)
        edited.syncSpeakerNames()
        self = edited
        return speaker.id
    }

    @discardableResult
    mutating func renameSpeaker(id: UUID, to name: String, savedPersonID: UUID? = nil) -> Bool {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var edited = self
        edited.normalizeSpeakerIdentities()
        guard !name.isEmpty,
              let index = edited.speakers?.firstIndex(where: { $0.id == id && !$0.isMicrophone }),
              edited.speakers?[index].name != name || edited.speakers?[index].savedPersonID != savedPersonID else { return false }
        edited.preserveDetectedSpeakers()
        edited.speakers?[index].name = name
        edited.speakers?[index].savedPersonID = savedPersonID
        edited.syncSpeakerNames()
        self = edited
        return true
    }

    @discardableResult
    mutating func assignSpeaker(to segmentID: UUID, speakerID: UUID) -> Bool {
        var edited = self
        edited.normalizeSpeakerIdentities()
        guard let index = edited.segments.firstIndex(where: { $0.id == segmentID && $0.source != .microphone }),
              edited.segments[index].speakerID != speakerID,
              edited.speakers?.contains(where: { $0.id == speakerID && !$0.isMicrophone }) == true else { return false }
        edited.preserveDetectedSpeakers()
        edited.segments[index].speakerID = speakerID
        edited.syncSpeakerNames()
        self = edited
        return true
    }

    @discardableResult
    mutating func mergeAllRemoteSpeakers(into targetID: UUID? = nil) -> Bool {
        var edited = self
        edited.normalizeSpeakerIdentities()
        let remote = (edited.speakers ?? []).filter { !$0.isMicrophone }
        guard let target = remote.first(where: { targetID == nil || $0.id == targetID }),
              remote.count > 1 || expectedRemoteSpeakerCount != 1 else { return false }
        edited.preserveDetectedSpeakers()
        for index in edited.segments.indices where edited.segments[index].source != .microphone {
            edited.segments[index].speakerID = target.id
        }
        edited.speakers?.removeAll { !$0.isMicrophone && $0.id != target.id }
        edited.expectedRemoteSpeakerCount = 1
        edited.syncSpeakerNames()
        self = edited
        return true
    }

    @discardableResult
    mutating func mergeSpeaker(id sourceID: UUID, into targetID: UUID) -> Bool {
        var edited = self
        edited.normalizeSpeakerIdentities()
        guard sourceID != targetID,
              edited.speakers?.contains(where: { $0.id == sourceID && !$0.isMicrophone }) == true,
              edited.speakers?.contains(where: { $0.id == targetID && !$0.isMicrophone }) == true else { return false }
        edited.preserveDetectedSpeakers()
        for index in edited.segments.indices where edited.segments[index].source != .microphone
            && edited.segments[index].speakerID == sourceID {
            edited.segments[index].speakerID = targetID
        }
        edited.speakers?.removeAll { $0.id == sourceID }
        edited.syncSpeakerNames()
        self = edited
        return true
    }

    @discardableResult
    mutating func restoreSpeakerEdits(_ snapshot: SpeakerEditingSnapshot) -> Bool {
        guard snapshot.documentID == id else { return false }
        var restored = self
        restored.speakers = snapshot.speakers
        restored.knownSpeakers = snapshot.knownSpeakers
        restored.speakerEditsApplied = snapshot.editsApplied
        restored.expectedRemoteSpeakerCount = snapshot.expectedRemoteSpeakerCount
        let assignments = Dictionary(uniqueKeysWithValues: snapshot.assignments.map { ($0.segmentID, $0) })
        for index in restored.segments.indices where restored.segments[index].source != .microphone {
            guard let assignment = assignments[restored.segments[index].id] else { continue }
            restored.segments[index].speakerID = assignment.speakerID
            restored.segments[index].speaker = assignment.name
        }
        restored.normalizeSpeakerIdentities()
        guard restored != self else { return false }
        self = restored
        return true
    }

    private mutating func preserveDetectedSpeakers() {
        if detectedSpeakers == nil { detectedSpeakers = speakers }
        if detectedSpeakerAssignments == nil {
            detectedSpeakerAssignments = segments.compactMap { segment in
                segment.speakerID.map { SpeakerAssignment(segmentID: segment.id, speakerID: $0) }
            }
        }
        speakerEditsApplied = true
    }

    private mutating func syncSpeakerNames() {
        let names = Dictionary(uniqueKeysWithValues: (speakers ?? []).map { ($0.id, $0.name) })
        for index in segments.indices {
            if let id = segments[index].speakerID, let name = names[id] {
                segments[index].speaker = name
            }
        }
        var seen = Set<String>()
        knownSpeakers = (speakers ?? []).map(\.name).filter { seen.insert($0).inserted }
    }

    /// Upgrades name-only documents and repairs mismatched source identities.
    /// Existing remote IDs stay distinct even when their display names match.
    mutating func normalizeSpeakerIdentities() {
        var people = speakers ?? []
        let oldMicrophoneNames = Set(
            segments.filter { $0.source == .microphone }.compactMap(\.speaker)
                + people.filter(\.isMicrophone).map(\.name)
        )
        let microphoneName = microphoneSpeakerName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fixedName = microphoneName.flatMap { $0.isEmpty ? nil : $0 } ?? "You"
        var microphone = people.first { $0.isMicrophone }
        if segments.contains(where: { $0.source == .microphone }) {
            if microphone == nil {
                microphone = DocumentSpeaker(name: fixedName, isMicrophone: true)
            }
            microphone?.name = fixedName
            microphone?.savedPersonID = nil
        }
        people.removeAll { $0.isMicrophone }
        if let microphone { people.insert(microphone, at: 0) }

        for index in segments.indices {
            let segment = segments[index]
            let person: DocumentSpeaker
            if segment.source == .microphone, let microphone {
                person = microphone
            } else if let existing = people.first(where: { $0.id == segment.speakerID && !$0.isMicrophone }) {
                person = existing
            } else {
                let name = segment.speaker?.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = name.flatMap { $0.isEmpty ? nil : $0 } ?? "Speaker 1"
                if let existing = people.first(where: { !$0.isMicrophone && $0.name == label }) {
                    person = existing
                } else {
                    person = DocumentSpeaker(name: label)
                    people.append(person)
                }
            }
            segments[index].speakerID = person.id
            segments[index].speaker = person.name
        }
        for name in knownSpeakers ?? [] {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !oldMicrophoneNames.contains(trimmed),
                  !people.contains(where: { $0.name == trimmed }) else { continue }
            people.append(DocumentSpeaker(name: trimmed))
        }
        speakers = people
        var seen = Set<String>()
        knownSpeakers = people.map(\.name).filter { seen.insert($0).inserted }
    }
}
