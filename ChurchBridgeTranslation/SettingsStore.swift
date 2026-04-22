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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.baseURLString = defaults.string(forKey: Keys.baseURL) ?? "https://churchbridge.dhaines.dev/"
        self.churchID = defaults.string(forKey: Keys.churchID) ?? "christ-fellowship"
        self.sourceScriptureVersion = defaults.string(forKey: Keys.sourceVersion) ?? "rvr1960"
        self.displayScriptureVersion = defaults.string(forKey: Keys.displayVersion) ?? "kjv"
        self.captureMode = CaptureMode(rawValue: defaults.string(forKey: Keys.captureMode) ?? "") ?? .voiceProcessing
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

    private func normalizedURL(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if let url = URL(string: trimmed), url.scheme != nil {
            return url
        }
        return URL(string: "http://\(trimmed)")
    }
}
