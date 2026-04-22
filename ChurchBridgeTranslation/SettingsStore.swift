import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    private enum Keys {
        static let baseURL = "churchbridge.baseURL"
        static let churchID = "churchbridge.churchID"
        static let sourceVersion = "churchbridge.sourceVersion"
        static let displayVersion = "churchbridge.displayVersion"
        static let captureMode = "churchbridge.captureMode"
        static let captureStrategy = "churchbridge.captureStrategy"
        static let translationTextSize = "churchbridge.translationTextSize"
        static let lastBibleVersionSlug = "churchbridge.lastBibleVersionSlug"
        static let lastBibleVersionName = "churchbridge.lastBibleVersionName"
        static let lastBibleBook = "churchbridge.lastBibleBook"
        static let lastBibleChapter = "churchbridge.lastBibleChapter"
        static let lastBibleVerse = "churchbridge.lastBibleVerse"
    }

    private let defaults: UserDefaults

    var baseURLString: String {
        didSet { defaults.set(baseURLString, forKey: Keys.baseURL) }
    }

    var churchID: String {
        didSet { defaults.set(churchID, forKey: Keys.churchID) }
    }

    var sourceScriptureVersion: String {
        didSet { defaults.set(sourceScriptureVersion, forKey: Keys.sourceVersion) }
    }

    var displayScriptureVersion: String {
        didSet { defaults.set(displayScriptureVersion, forKey: Keys.displayVersion) }
    }

    var captureMode: CaptureMode {
        didSet { defaults.set(captureMode.rawValue, forKey: Keys.captureMode) }
    }

    var captureStrategy: AudioCaptureStrategy {
        didSet { defaults.set(captureStrategy.rawValue, forKey: Keys.captureStrategy) }
    }

    var translationTextSize: Double {
        didSet { defaults.set(translationTextSize, forKey: Keys.translationTextSize) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURLString = defaults.string(forKey: Keys.baseURL) ?? "https://churchbridge.dhaines.dev/"
        self.churchID = defaults.string(forKey: Keys.churchID) ?? "christ-fellowship"
        self.sourceScriptureVersion = defaults.string(forKey: Keys.sourceVersion) ?? "rvr1960"
        self.displayScriptureVersion = defaults.string(forKey: Keys.displayVersion) ?? "kjv"
        self.captureMode = CaptureMode(rawValue: defaults.string(forKey: Keys.captureMode) ?? "") ?? .voiceProcessing
        self.captureStrategy = .liveDefault
        let storedTextSize = defaults.object(forKey: Keys.translationTextSize) as? Double
        self.translationTextSize = storedTextSize ?? 24
        defaults.set(self.captureStrategy.rawValue, forKey: Keys.captureStrategy)
    }

    var apiBaseURL: URL? {
        normalizedURL(from: baseURLString)
    }

    var webSocketBaseURL: URL? {
        guard let apiBaseURL else { return nil }
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        components?.scheme = apiBaseURL.scheme == "https" ? "wss" : "ws"
        return components?.url
    }

    var lastBibleVersionSlug: String? { defaults.string(forKey: Keys.lastBibleVersionSlug) }
    var lastBibleVersionName: String? { defaults.string(forKey: Keys.lastBibleVersionName) }
    var lastBibleBook: String? { defaults.string(forKey: Keys.lastBibleBook) }

    var lastBibleChapter: Int? {
        let value = defaults.integer(forKey: Keys.lastBibleChapter)
        return value > 0 ? value : nil
    }

    var lastBibleVerse: Int? {
        let value = defaults.integer(forKey: Keys.lastBibleVerse)
        return value > 0 ? value : nil
    }

    var hasLastBibleLocation: Bool {
        lastBibleVersionSlug != nil && lastBibleVersionName != nil && lastBibleBook != nil && lastBibleChapter != nil
    }

    func saveBibleLocation(
        versionSlug: String,
        versionName: String,
        book: String,
        chapter: Int,
        verse: Int?
    ) {
        defaults.set(versionSlug, forKey: Keys.lastBibleVersionSlug)
        defaults.set(versionName, forKey: Keys.lastBibleVersionName)
        defaults.set(book, forKey: Keys.lastBibleBook)
        defaults.set(chapter, forKey: Keys.lastBibleChapter)
        if let verse {
            defaults.set(verse, forKey: Keys.lastBibleVerse)
        } else {
            defaults.removeObject(forKey: Keys.lastBibleVerse)
        }
    }

    private func normalizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "http://\(trimmed)")
    }
}
