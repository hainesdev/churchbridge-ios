import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class DisplayFeedStore {
    private(set) var snapshot = DisplayFeedSnapshot()
    private var flashClearTask: Task<Void, Never>?

    func setConnected(_ connected: Bool) {
        snapshot.connected = connected
    }

    func resetForNewSession() {
        flashClearTask?.cancel()
        snapshot.segments.removeAll()
        snapshot.liveDock = LiveTranslationDockState()
        snapshot.finalSpanishLines.removeAll()
        snapshot.interimSpanish = ""
        snapshot.flashingID = nil
        snapshot.lastInterimSpanish = ""
        snapshot.lastFinalSpanish = ""
        snapshot.lastCommittedEnglish = ""
        snapshot.lastInterimAt = nil
        snapshot.lastFinalAt = nil
        snapshot.lastTranslationAt = nil
        snapshot.lastVisibleSegmentID = nil
    }

    func handle(messageData: Data) throws {
        let json = try JSONSerialization.jsonObject(with: messageData) as? [String: Any]
        guard let json, let type = json["type"] as? String else { return }
        let now = Date()

        switch type {
        case "interim":
            let text = (json["text"] as? String) ?? ""
            snapshot.interimSpanish = text
            snapshot.lastInterimSpanish = text
            snapshot.lastInterimAt = now

        case "stt_final":
            let text = (json["text"] as? String) ?? ""
            snapshot.finalSpanishLines.append(text)
            snapshot.finalSpanishLines = Array(snapshot.finalSpanishLines.suffix(8))
            snapshot.interimSpanish = ""
            snapshot.lastFinalSpanish = text
            snapshot.lastFinalAt = now

        case "live_translation":
            let text = ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let source = (json["source"] as? String) ?? type
            let mergeStrategy = (json["merge_strategy"] as? String) ?? defaultLiveMergeStrategy(for: source)
            updateLiveDock(text: text, source: source, mergeStrategy: mergeStrategy, at: now)

        case "live_translation_clear":
            clearLiveDock()

        case "feed_commit":
            let spanish = (json["spanish"] as? String) ?? ""
            let english = (json["english"] as? String) ?? ""
            let phraseAlignment = decodePhraseAlignment(from: json["phrase_alignment"])
            let segmentID = extractSegmentID(from: json) ?? Int(Date().timeIntervalSince1970 * 1000)
            upsertCommittedSegment(
                segmentID: segmentID,
                spanish: spanish,
                english: english,
                phraseAlignment: phraseAlignment
            )
            snapshot.finalSpanishLines.removeAll()
            snapshot.interimSpanish = ""
            clearLiveDock()
            snapshot.lastCommittedEnglish = english
            snapshot.lastTranslationAt = now
            snapshot.lastVisibleSegmentID = segmentID

        case "feed_revision":
            let english = (json["english"] as? String) ?? ""
            guard
                let segmentID = extractSegmentID(from: json),
                let index = snapshot.segments.firstIndex(where: { $0.segmentID == segmentID })
            else {
                return
            }
            snapshot.segments[index].english = english
            if let spanish = json["spanish"] as? String, !spanish.isEmpty {
                snapshot.segments[index].spanish = spanish
            }
            if let phraseAlignment = decodePhraseAlignment(from: json["phrase_alignment"]) {
                snapshot.segments[index].phraseAlignment = phraseAlignment
            }
            snapshot.segments[index].pendingCompletion = false
            flashSegment(snapshot.segments[index].segmentID)
            snapshot.lastVisibleSegmentID = snapshot.segments[index].segmentID

        case "caption_merge":
            if let reason = json["reason"] as? String,
               reason != "segmentation_repair" {
                return
            }
            guard
                let keepID = extractSegmentID(from: json, preferredKey: "segment_id_keep", legacyKey: "ts_keep"),
                let absorbID = extractSegmentID(from: json, preferredKey: "segment_id_absorb", legacyKey: "ts_absorb"),
                snapshot.segments.contains(where: { $0.segmentID == keepID })
            else {
                return
            }
            snapshot.segments.removeAll(where: { $0.segmentID == absorbID })
            guard let refreshedKeepIndex = snapshot.segments.firstIndex(where: { $0.segmentID == keepID }) else {
                return
            }
            snapshot.segments[refreshedKeepIndex].spanish = (json["spanish"] as? String) ?? snapshot.segments[refreshedKeepIndex].spanish
            snapshot.segments[refreshedKeepIndex].english = (json["english"] as? String) ?? snapshot.segments[refreshedKeepIndex].english
            snapshot.segments[refreshedKeepIndex].phraseAlignment = []
            snapshot.segments[refreshedKeepIndex].pendingCompletion = false
            flashSegment(snapshot.segments[refreshedKeepIndex].segmentID)
            snapshot.lastVisibleSegmentID = snapshot.segments[refreshedKeepIndex].segmentID

        case "segment_metadata":
            guard
                let segmentID = extractSegmentID(from: json),
                let index = snapshot.segments.firstIndex(where: { $0.segmentID == segmentID })
            else {
                return
            }
            snapshot.segments[index].pendingCompletion = (json["pending_completion"] as? Bool) ?? snapshot.segments[index].pendingCompletion
            snapshot.segments[index].terminalIncomplete = (json["terminal_incomplete"] as? Bool) ?? snapshot.segments[index].terminalIncomplete

        case "mode_change":
            snapshot.sermonMode = (json["to"] as? String) ?? snapshot.sermonMode

        case "verse_detected":
            guard
                let segmentID = extractSegmentID(from: json),
                let index = snapshot.segments.firstIndex(where: { $0.segmentID == segmentID }),
                let verseData = try? JSONSerialization.data(withJSONObject: json["verse"] as Any),
                let verse = try? JSONDecoder().decode(VerseDetection.self, from: verseData)
            else {
                return
            }
            snapshot.segments[index].verseDetected = verse

        case "verse_range_update":
            guard
                let segmentID = extractSegmentID(from: json),
                let index = snapshot.segments.firstIndex(where: { $0.segmentID == segmentID }),
                let verseData = try? JSONSerialization.data(withJSONObject: json["verse"] as Any),
                let verse = try? JSONDecoder().decode(VerseDetection.self, from: verseData)
            else {
                return
            }
            snapshot.segments[index].verseDetected = verse

        case "verse_suggestion":
            guard
                let segmentID = extractSegmentID(from: json),
                let index = snapshot.segments.firstIndex(where: { $0.segmentID == segmentID }),
                let suggestionsObject = json["suggestions"],
                let suggestionsData = try? JSONSerialization.data(withJSONObject: suggestionsObject),
                let suggestions = try? JSONDecoder().decode([VerseSuggestion].self, from: suggestionsData)
            else {
                return
            }
            snapshot.segments[index].verseSuggestions = suggestions

        default:
            return
        }
    }

    private func flashSegment(_ ts: Int) {
        if UIAccessibility.isReduceMotionEnabled { return }
        flashClearTask?.cancel()
        snapshot.flashingID = ts
        flashClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled, self?.snapshot.flashingID == ts else { return }
            self?.snapshot.flashingID = nil
        }
    }

    private func updateLiveDock(text: String, source: String, mergeStrategy: String, at now: Date) {
        let incomingTrimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incomingTrimmed.isEmpty else { return }
        if mergeStrategy == "replace" {
            snapshot.liveDock.english = incomingTrimmed
        } else {
            snapshot.liveDock.english = mergedLiveEnglish(current: snapshot.liveDock.english, incoming: incomingTrimmed)
        }
        snapshot.liveDock.source = source
        snapshot.liveDock.updatedAt = now
    }

    private func clearLiveDock() {
        snapshot.liveDock = LiveTranslationDockState()
    }

    private func upsertCommittedSegment(
        segmentID: Int,
        spanish: String,
        english: String,
        phraseAlignment: [PhraseAlignment]?
    ) {
        if let index = snapshot.segments.firstIndex(where: { $0.segmentID == segmentID }) {
            snapshot.segments[index].spanish = spanish
            snapshot.segments[index].english = english
            snapshot.segments[index].phraseAlignment = phraseAlignment ?? snapshot.segments[index].phraseAlignment
        } else {
            snapshot.segments.append(
                TranslationSegment(
                    segmentID: segmentID,
                    spanish: spanish,
                    english: english,
                    phraseAlignment: phraseAlignment ?? []
                )
            )
            snapshot.segments = Array(snapshot.segments.suffix(100))
        }
    }

    private func decodePhraseAlignment(from rawValue: Any?) -> [PhraseAlignment]? {
        guard let rawValue else { return nil }
        guard JSONSerialization.isValidJSONObject(rawValue),
              let data = try? JSONSerialization.data(withJSONObject: rawValue),
              let alignment = try? JSONDecoder().decode([PhraseAlignment].self, from: data)
        else {
            return nil
        }
        return alignment
    }

    private func extractSegmentID(
        from json: [String: Any],
        preferredKey: String = "segment_id",
        legacyKey: String = "ts"
    ) -> Int? {
        if let segmentID = json[preferredKey] as? Int {
            return segmentID
        }
        if let legacy = json[legacyKey] as? Int {
            return legacy
        }
        return nil
    }

    private func defaultLiveMergeStrategy(for source: String) -> String {
        switch source {
        case "google_sentence", "google_correction", "google_interim", "llm":
            return "replace"
        default:
            return "append"
        }
    }

    private func mergedLiveEnglish(current: String, incoming: String) -> String {
        let currentTrimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
        let incomingTrimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !incomingTrimmed.isEmpty else { return currentTrimmed }
        guard !currentTrimmed.isEmpty else { return incomingTrimmed }
        if incomingTrimmed.hasPrefix(currentTrimmed) {
            return incomingTrimmed
        }
        if currentTrimmed.hasPrefix(incomingTrimmed) || currentTrimmed.contains(incomingTrimmed) {
            return currentTrimmed
        }
        return "\(currentTrimmed) \(incomingTrimmed)"
    }
}
