import FluidAudio
import Foundation
import SwiftUI

struct VoiceProfile: Codable, Identifiable, Hashable {
    var name: String
    var centroids: [[Float]]
    var sampleCount: Int
    var updatedAt: Date

    var id: String { name }
}

enum VoiceMatchTier: Equatable {
    case apply
    case suggest
    case none
}

@MainActor
final class VoiceProfileStore: ObservableObject {
    static let shared = VoiceProfileStore()

    nonisolated static let voiceRecognitionEnabledKey = "voiceRecognitionEnabled"
    nonisolated static let autoApplyDistanceThreshold: Float = 0.35
    nonisolated static let suggestDistanceThreshold: Float = 0.45
    nonisolated static let centroidMergeDistanceThreshold: Float = autoApplyDistanceThreshold
    nonisolated static let maximumCentroids = 3
    nonisolated static let maximumAverageWeight = 20

    @Published private(set) var profiles: [VoiceProfile] = []

    private let fileURL: URL

    init() {
        fileURL = Self.defaultFileURL
        load()
    }

    init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    var isRecognitionEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Self.voiceRecognitionEnabledKey) != nil else { return true }
        return defaults.bool(forKey: Self.voiceRecognitionEnabledKey)
    }

    func learn(name proposedName: String, embedding: [Float]) {
        guard isRecognitionEnabled, Self.isValid(embedding: embedding) else { return }
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if let index = profileIndex(named: name) {
            let profile = profiles[index]
            profiles[index].centroids = Self.updatedCentroids(
                profile.centroids,
                sampleCount: profile.sampleCount,
                adding: embedding
            )
            profiles[index].sampleCount += 1
            profiles[index].updatedAt = Date()
        } else {
            profiles.append(VoiceProfile(
                name: name,
                centroids: [Self.normalized(embedding)],
                sampleCount: 1,
                updatedAt: Date()
            ))
        }
        sortProfiles()
        save()
    }

    func match(embedding: [Float]) -> (name: String, distance: Float)? {
        guard isRecognitionEnabled, Self.isValid(embedding: embedding) else {
            DiagLog.log("voice match name %@ distance %.4f decision no", "none", Float.infinity)
            return nil
        }

        let candidates = profiles.flatMap { profile in
            profile.centroids.map { (name: profile.name, distance: Self.cosineDistance(embedding, $0)) }
        }
        guard let best = candidates.min(by: { $0.distance < $1.distance }) else {
            DiagLog.log("voice match name %@ distance %.4f decision no", "none", Float.infinity)
            return nil
        }

        let decision: String
        switch Self.matchTier(for: best.distance) {
        case .apply: decision = "applied"
        case .suggest: decision = "suggested"
        case .none: decision = "no"
        }
        DiagLog.log("voice match name %@ distance %.4f decision %@", best.name, best.distance, decision)
        return best
    }

    func delete(name: String) {
        profiles.removeAll { Self.namesMatch($0.name, name) }
        save()
    }

    func renameProfile(from oldName: String, to proposedName: String) {
        let newName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty,
              let sourceIndex = profileIndex(named: oldName) else { return }

        if Self.namesMatch(oldName, newName) {
            guard profiles[sourceIndex].name != newName else { return }
            profiles[sourceIndex].name = newName
            profiles[sourceIndex].updatedAt = Date()
            sortProfiles()
            save()
            return
        }

        let source = profiles.remove(at: sourceIndex)
        if let targetIndex = profileIndex(named: newName) {
            var target = profiles[targetIndex]
            target.centroids = Array((target.centroids + source.centroids).suffix(Self.maximumCentroids))
            target.sampleCount += source.sampleCount
            target.updatedAt = Date()
            profiles[targetIndex] = target
        } else {
            var renamed = source
            renamed.name = newName
            renamed.updatedAt = Date()
            profiles.append(renamed)
        }
        sortProfiles()
        save()
    }

    func hasProfile(named name: String) -> Bool {
        profileIndex(named: name) != nil
    }

    nonisolated static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Float {
        SpeakerUtilities.cosineDistance(lhs, rhs)
    }

    nonisolated static func matchTier(for distance: Float) -> VoiceMatchTier {
        if distance < autoApplyDistanceThreshold { return .apply }
        if distance < suggestDistanceThreshold { return .suggest }
        return .none
    }

    /// Centroids are kept oldest first so adding a fourth microphone profile
    /// evicts the first one.
    nonisolated static func updatedCentroids(
        _ centroids: [[Float]],
        sampleCount: Int,
        adding embedding: [Float]
    ) -> [[Float]] {
        guard isValid(embedding: embedding) else { return centroids }
        var result = centroids.filter { isValid(embedding: $0) }
        if let matchIndex = result.indices.min(by: {
            cosineDistance(result[$0], embedding) < cosineDistance(result[$1], embedding)
        }), cosineDistance(result[matchIndex], embedding) < centroidMergeDistanceThreshold {
            let existing = result[matchIndex]
            let weight = Float(max(1, min(sampleCount, maximumAverageWeight)))
            let averaged = zip(existing, embedding).map { ($0 * weight + $1) / (weight + 1) }
            result[matchIndex] = normalized(averaged)
        } else {
            result.append(normalized(embedding))
        }
        return Array(result.suffix(maximumCentroids))
    }

    nonisolated static func normalized(_ embedding: [Float]) -> [Float] {
        let magnitude = embedding.reduce(Float.zero) { $0 + $1 * $1 }.squareRoot()
        guard magnitude > 0, magnitude.isFinite else { return embedding }
        return embedding.map { $0 / magnitude }
    }

    private nonisolated static func isValid(embedding: [Float]) -> Bool {
        !embedding.isEmpty && embedding.allSatisfy(\.isFinite)
            && embedding.contains(where: { $0 != 0 })
    }

    private nonisolated static let defaultFileURL: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scribe/voice-profiles.json")
    }()

    private func profileIndex(named name: String) -> Int? {
        profiles.firstIndex { Self.namesMatch($0.name, name) }
    }

    private nonisolated static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            == rhs.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    private func sortProfiles() {
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            profiles = try decoder.decode([VoiceProfile].self, from: data).map { profile in
                var profile = profile
                profile.centroids = Array(profile.centroids.suffix(Self.maximumCentroids))
                return profile
            }
            sortProfiles()
        } catch {
            DiagLog.log("failed to load voice profiles: %@", error.localizedDescription)
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(profiles).write(to: fileURL, options: .atomic)
        } catch {
            DiagLog.log("failed to save voice profiles: %@", error.localizedDescription)
        }
    }
}
