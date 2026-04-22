import Foundation
import Observation

@MainActor
@Observable
final class TranslationTestViewModel {
    var settings: SettingsStore
    let displayFeed: DisplayFeedStore
    let audioCapture: AudioCaptureManager

    var bibleVersions: [BibleVersionOption] = []
    var bibleVersionsError = ""
    var latestError = ""
    var streamStatus: StreamStatus = .idle
    var displayConnected = false
    var diagnostics = AudioDiagnostics()
    var sessionID: Int?
    var isRunning = false
    var showSettings = false

    private let bibleService = BibleVersionService()
    private let streamClient = StreamSocketClient()
    private let displayClient = DisplaySocketClient()

    init() {
        let settings = SettingsStore()
        let displayFeed = DisplayFeedStore()
        let audioCapture = AudioCaptureManager()
        self.settings = settings
        self.displayFeed = displayFeed
        self.audioCapture = audioCapture

        audioCapture.diagnosticsDidChange = { [weak self] diagnostics in
            Task { @MainActor in self?.diagnostics = diagnostics }
        }
        audioCapture.errorHandler = { [weak self] message in
            Task { @MainActor in self?.latestError = message }
        }
        audioCapture.audioChunkHandler = { [weak self] base64 in
            Task {
                await self?.streamClient.sendAudio(base64Float32: base64)
            }
        }

        Task { await configureSockets() }
    }

    func onAppear() async {
        await connectDisplay()
        await loadBibleVersions()
    }

    func loadBibleVersions() async {
        guard let apiBaseURL = settings.apiBaseURL else {
            bibleVersionsError = NetworkError.invalidBaseURL.localizedDescription
            return
        }
        do {
            bibleVersionsError = ""
            bibleVersions = try await bibleService.fetchVersions(baseURL: apiBaseURL, churchID: settings.churchID)
            if !bibleVersions.contains(where: { $0.slug == settings.sourceScriptureVersion }), let first = bibleVersions.first {
                settings.sourceScriptureVersion = first.slug
            }
            if !bibleVersions.contains(where: { $0.slug == settings.displayScriptureVersion }), let first = bibleVersions.first {
                settings.displayScriptureVersion = first.slug
            }
        } catch {
            bibleVersionsError = error.localizedDescription
        }
    }

    func restartDisplayConnection() async {
        await connectDisplay()
    }

    func start() async {
        guard let wsBaseURL = settings.webSocketBaseURL else {
            latestError = NetworkError.invalidBaseURL.localizedDescription
            return
        }

        latestError = ""
        displayFeed.resetForNewSession()
        let configuration = StreamSocketClient.StreamConfiguration(
            url: wsBaseURL,
            churchID: settings.churchID,
            sampleRate: 16_000,
            sourceScriptureVersion: settings.sourceScriptureVersion,
            displayScriptureVersion: settings.displayScriptureVersion
        )

        await streamClient.connect(configuration: configuration)
        do {
            try await audioCapture.start(mode: settings.captureMode)
            isRunning = true
        } catch {
            latestError = error.localizedDescription
            await streamClient.disconnect()
        }
    }

    func stop() async {
        audioCapture.stop()
        isRunning = false
        await streamClient.disconnect()
    }

    private func configureSockets() async {
        await streamClient.setHandlers(
            statusHandler: { [weak self] status in
                Task { @MainActor in self?.streamStatus = status }
            },
            messageHandler: { [weak self] message in
                Task { @MainActor in self?.latestError = message }
            },
            sessionIDHandler: { [weak self] sessionID in
                Task { @MainActor in self?.sessionID = sessionID }
            }
        )

        await displayClient.setHandlers(
            statusHandler: { [weak self] connected in
                Task { @MainActor in
                    self?.displayConnected = connected
                    self?.displayFeed.setConnected(connected)
                }
            },
            messageHandler: { [weak self] data in
                Task { @MainActor in
                    do {
                        try self?.displayFeed.handle(messageData: data)
                    } catch {
                        self?.latestError = "Display decode failed: \(error.localizedDescription)"
                    }
                }
            },
            errorHandler: { [weak self] message in
                Task { @MainActor in self?.latestError = message }
            }
        )
    }

    private func connectDisplay() async {
        guard let wsBaseURL = settings.webSocketBaseURL else {
            latestError = NetworkError.invalidBaseURL.localizedDescription
            return
        }
        await displayClient.connect(baseURL: wsBaseURL, churchID: settings.churchID)
    }
}
