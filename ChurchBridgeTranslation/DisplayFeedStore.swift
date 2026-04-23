import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class DisplayFeedStore {
    private(set) var snapshot = DisplayFeedSnapshot()
    private var mergedInto: [Int: Int] = [:]
    private var flashClearTask: Task<Void, Never>?

    func setConnected(_ connected: Bool) {
        snapshot.connected = connected
    }

    func resetForNewSession() {
        flashClearTask?.cancel()
        snapshot.segments.removeAll()
        snapshot.spanishLines.removeAll()
        snapshot.partialSpanish = ""
        snapshot.partialEnglish = ""
        snapshot.flashingID = nil
        snapshot.lastInterimSpanish = ""
        snapshot.lastFinalSpanish = ""
        snapshot.lastCommittedEnglish = ""
        snapshot.lastInterimAt = nil
        snapshot.lastFinalAt = nil
        snapshot.lastTranslationAt = nil
        snapshot.lastVisibleSegmentID = nil
        mergedInto.removeAll()
    }

    func handle(messageData: Data) throws {
        let json = try JSONSerialization.jsonObject(with: messageData) as? [String: Any]
        guard let json, let type = json["type"] as? String else { return }
        let now = Date()

        switch type {
        case "interim":
            let text = (json["text"] as? String) ?? ""
            snapshot.partialSpanish = text
            snapshot.lastInterimSpanish = text
            snapshot.lastInterimAt = now

        case "stt_final":
            let text = (json["text"] as? String) ?? ""
            snapshot.spanishLines.append(text)
            snapshot.spanishLines = Array(snapshot.spanishLines.suffix(8))
            snapshot.partialSpanish = ""
            snapshot.lastFinalSpanish = text
            snapshot.lastFinalAt = now

        case "interim_translation":
            let text = ((json["text"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            snapshot.partialEnglish = snapshot.partialEnglish.isEmpty ? text : "\(snapshot.partialEnglish) \(text)"

        case "translation":
            let spanish = (json["spanish"] as? String) ?? ""
            let english = (json["english"] as? String) ?? ""
            let ts = (json["ts"] as? Int) ?? Int(Date().timeIntervalSince1970 * 1000)
            if let index = snapshot.segments.firstIndex(where: { $0.id == ts }) {
                snapshot.segments[index].spanish = spanish
                snapshot.segments[index].english = english
            } else {
                snapshot.segments.append(TranslationSegment(id: ts, spanish: spanish, english: english))
                snapshot.segments = Array(snapshot.segments.suffix(100))
            }
            snapshot.spanishLines.removeAll()
            snapshot.partialSpanish = ""
            snapshot.partialEnglish = ""
            snapshot.lastCommittedEnglish = english
            snapshot.lastTranslationAt = now
            snapshot.lastVisibleSegmentID = ts

        case "translation_update", "correction":
            let english = (json["english"] as? String) ?? ""
            let ts = resolveVisibleSegmentID((json["ts"] as? Int) ?? 0)
            guard let index = snapshot.segments.firstIndex(where: { $0.id == ts }) else { return }
            snapshot.segments[index].english = english
            snapshot.segments[index].pendingCompletion = false
            flashSegment(ts)
            snapshot.lastVisibleSegmentID = ts

        case "caption_merge":
            guard
                let keepID = json["ts_keep"] as? Int,
                let absorbID = json["ts_absorb"] as? Int,
                let keepIndex = snapshot.segments.firstIndex(where: { $0.id == resolveVisibleSegmentID(keepID) })
            else {
                return
            }
            let resolvedKeepID = resolveVisibleSegmentID(keepID)
            let absorbed = snapshot.segments.first(where: { $0.id == absorbID })
            mergedInto[absorbID] = resolvedKeepID
            snapshot.segments.removeAll(where: { $0.id == absorbID })
            snapshot.segments[keepIndex].spanish = (json["spanish"] as? String) ?? snapshot.segments[keepIndex].spanish
            snapshot.segments[keepIndex].english = (json["english"] as? String) ?? snapshot.segments[keepIndex].english
            snapshot.segments[keepIndex].pendingCompletion = false
            if snapshot.segments[keepIndex].verseDetected == nil {
                snapshot.segments[keepIndex].verseDetected = absorbed?.verseDetected
            }
            if snapshot.segments[keepIndex].verseSuggestions.isEmpty {
                snapshot.segments[keepIndex].verseSuggestions = absorbed?.verseSuggestions ?? []
            }
            snapshot.lastVisibleSegmentID = resolvedKeepID

        case "segment_metadata":
            guard
                let ts = json["ts"] as? Int,
                let index = snapshot.segments.firstIndex(where: { $0.id == resolveVisibleSegmentID(ts) })
            else {
                return
            }
            snapshot.segments[index].pendingCompletion = (json["pending_completion"] as? Bool) ?? snapshot.segments[index].pendingCompletion
            snapshot.segments[index].terminalIncomplete = (json["terminal_incomplete"] as? Bool) ?? snapshot.segments[index].terminalIncomplete

        case "mode_change":
            snapshot.sermonMode = (json["to"] as? String) ?? snapshot.sermonMode

        case "verse_detected":
            guard
                let ts = json["ts"] as? Int,
                let index = snapshot.segments.firstIndex(where: { $0.id == resolveVisibleSegmentID(ts) }),
                let verseData = try? JSONSerialization.data(withJSONObject: json["verse"] as Any),
                let verse = try? JSONDecoder().decode(VerseDetection.self, from: verseData)
            else {
                return
            }
            snapshot.segments[index].verseDetected = verse

        case "verse_range_update":
            guard
                let ts = json["ts"] as? Int,
                let index = snapshot.segments.firstIndex(where: { $0.id == resolveVisibleSegmentID(ts) }),
                let verseData = try? JSONSerialization.data(withJSONObject: json["verse"] as Any),
                let verse = try? JSONDecoder().decode(VerseDetection.self, from: verseData)
            else {
                return
            }
            snapshot.segments[index].verseDetected = verse

        case "verse_suggestion":
            guard
                let ts = json["ts"] as? Int,
                let index = snapshot.segments.firstIndex(where: { $0.id == resolveVisibleSegmentID(ts) }),
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

    private func resolveVisibleSegmentID(_ ts: Int) -> Int {
        var current = ts
        var visited = Set<Int>()
        while let next = mergedInto[current], !visited.contains(next) {
            visited.insert(current)
            current = next
        }
        return current
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
}
