import Foundation
import Observation
import UIKit

enum UserFacingError {
    static func userMessage(_ raw: String) -> String {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if let mapped = directMappings.first(where: { t.localizedCaseInsensitiveContains($0.key) })?.value { return mapped }
        if t.hasPrefix("Display decode failed:") { return "Couldn’t read the live text feed. Try Reconnect in the menu." }
        if t.contains("http") && t.contains("statusCode") { return "A network request failed. Check your connection and try again." }
        if t == NetworkError.invalidBaseURL.localizedDescription { return "Add a valid server address in Settings." }
        if t.contains("The operation couldn’t be completed") && t.contains("NSURLError") { return "Network error. Check Wi‑Fi or cellular, then try again." }
        return t
    }

    private static let directMappings: KeyValuePairs<String, String> = [
        "Input is clipping": "Audio is peaking. Move a bit away from the speaker, or we’ll keep hearing distortion.",
    ]
}

private struct InterpreterProbeSnapshot {
    let audioChunksObserved: Int
    let audioChunksSent: Int
    let audioSendFailures: Int
    let audioBytesEncodedSent: Int
    let audioBytesDecodedSent: Int
    let displayEventCount: Int
    let translationEventCount: Int
    let sessionStartCount: Int
}

private struct OutgoingAudioChunkRecord {
    let sequence: Int
    let createdAt: Date
    let sampleRate: Int
    let encodedBytes: Int
    let decodedBytes: Int
    let base64: String
    let analysis: [String: Any]
}

@MainActor
@Observable
final class TranslationTestViewModel {
    var settings: SettingsStore
    let displayFeed: DisplayFeedStore
    let audioCapture: AudioCaptureManager

    var bibleData = BibleDataManager()
    var bibleVersions: [BibleVersionOption] = []
    var bibleVersionsError = ""
    var latestError = ""
    var userFacingLatestError: String { UserFacingError.userMessage(latestError) }
    var streamStatus: StreamStatus = .idle
    var displayConnected = false
    var diagnostics = AudioDiagnostics()
    var sessionID: Int?
    var isRunning = false
    var showSettings = false
    var interpreterChunksObserved: Int { audioChunksObserved }
    var interpreterChunksSent: Int { audioChunksSent }
    var interpreterSendFailures: Int { audioSendFailures }
    var interpreterLastChunkObservedAt: Date? { lastAudioChunkObservedAt }
    var interpreterLastChunkSentAt: Date? { lastAudioChunkSentAt }
    var interpreterLastSendFailureAt: Date? { lastAudioSendFailureAt }

    private let bibleService = BibleVersionService()
    private let streamClient = StreamSocketClient()
    private let displayClient = DisplaySocketClient()
    private var remoteDiagnosticsTask: Task<Void, Never>?
    private var audioChunksObserved = 0
    private var audioChunksSent = 0
    private var audioSendFailures = 0
    private var audioBytesEncodedSent = 0
    private var audioBytesDecodedSent = 0
    private var firstAudioChunkObservedAt: Date?
    private var lastAudioChunkObservedAt: Date?
    private var firstAudioChunkSentAt: Date?
    private var lastAudioChunkSentAt: Date?
    private var lastAudioSendFailureAt: Date?
    private var sessionStartCount = 0
    private var sessionStartedAt: Date?
    private var displayEventCount = 0
    private var translationEventCount = 0
    private var firstDisplayEventAt: Date?
    private var lastDisplayEventAt: Date?
    private var firstTranslationEventAt: Date?
    private var lastTranslationEventAt: Date?
    private var lastDisplayEventType = ""
    private var displayEventTypeCounts: [String: Int] = [:]
    private var outgoingChunkSequence = 0
    private var recentOutgoingChunks: [OutgoingAudioChunkRecord] = []

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
        audioCapture.audioChunkHandler = { [weak self] chunk in
            Task {
                await self?.handleOutgoingAudioChunk(chunk)
            }
        }

        Task { await configureSockets() }
    }

    func onAppear() async {
        await connectDisplay()
        await loadBibleVersions()
        await bibleData.prepare(baseURL: settings.apiBaseURL)
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
        let liveStrategy = AudioCaptureStrategy.liveDefault
        if settings.captureStrategy != liveStrategy {
            settings.captureStrategy = liveStrategy
        }
        let configuration = StreamSocketClient.StreamConfiguration(
            url: wsBaseURL,
            churchID: settings.churchID,
            sampleRate: liveStrategy.targetSampleRate,
            sourceScriptureVersion: settings.sourceScriptureVersion,
            displayScriptureVersion: settings.displayScriptureVersion
        )

        await streamClient.connect(configuration: configuration)
        do {
            try await audioCapture.start(mode: settings.captureMode, strategy: liveStrategy)
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
                Task { @MainActor in
                    self?.sessionID = sessionID
                    self?.recordSessionStart(sessionID)
                }
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
                    await self?.handleDisplayMessageData(data)
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

    private func handleDisplayMessageData(_ data: Data) async {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = json["type"] as? String else {
                return
            }

            if type == "diagnostics_command", let command = json["command"] as? [String: Any] {
                await handleRemoteDiagnosticsCommand(command)
                return
            }

            recordDisplayEvent(type: type)
            try displayFeed.handle(messageData: data)
        } catch {
            latestError = "Display decode failed: \(error.localizedDescription)"
        }
    }

    private func handleRemoteDiagnosticsCommand(_ command: [String: Any]) async {
        guard let commandID = command["id"] as? String,
              let commandName = command["command"] as? String else {
            return
        }

        if let task = remoteDiagnosticsTask, !task.isCancelled {
            await postDiagnosticsReport(
                commandID: commandID,
                reportType: commandName,
                status: "failed",
                payload: [
                    "error": "A diagnostics task is already in progress.",
                    "snapshot": diagnosticsSnapshotPayload(),
                ]
            )
            return
        }

        let payload = command["payload"] as? [String: Any] ?? [:]
        remoteDiagnosticsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.postDiagnosticsReport(
                commandID: commandID,
                reportType: commandName,
                status: "acknowledged",
                payload: [
                    "snapshot": self.diagnosticsSnapshotPayload(),
                ]
            )

            switch commandName {
            case "snapshot":
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: "completed",
                    payload: [
                        "snapshot": self.diagnosticsSnapshotPayload(),
                    ]
                )
            case "audio_probe":
                let durationMs = intValue(payload["duration_ms"], default: 5_000)
                let result = await self.runAudioProbe(durationMs: durationMs)
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: result.success ? "completed" : "failed",
                    payload: result.payload
                )
            case "stream_probe":
                let durationMs = intValue(payload["duration_ms"], default: 5_000)
                let result = await self.runStreamProbe(durationMs: durationMs)
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: result.success ? "completed" : "failed",
                    payload: result.payload
                )
            case "personal_interpreter_probe":
                let durationMs = intValue(payload["duration_ms"], default: 7_000)
                let result = await self.runPersonalInterpreterProbe(durationMs: durationMs)
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: result.success ? "completed" : "failed",
                    payload: result.payload
                )
            case "audio_forensics_probe":
                let durationMs = intValue(payload["duration_ms"], default: 7_000)
                let maxChunks = intValue(payload["max_chunks"], default: 3)
                let result = await self.runAudioForensicsProbe(durationMs: durationMs, maxChunks: maxChunks)
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: result.success ? "completed" : "failed",
                    payload: result.payload
                )
            case "capture_pipeline_probe":
                let durationMs = intValue(payload["duration_ms"], default: 6_000)
                let includeStream = boolValue(payload["include_stream"], default: false)
                let requestedMode = captureModeValue(payload["capture_mode"])
                let requestedStrategy = captureStrategyValue(payload["capture_strategy"])
                let result = await self.runCapturePipelineProbe(
                    durationMs: durationMs,
                    captureMode: requestedMode,
                    captureStrategy: requestedStrategy,
                    includeStream: includeStream
                )
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: result.success ? "completed" : "failed",
                    payload: result.payload
                )
            case "capture_rebuild_probe":
                let durationMs = intValue(payload["duration_ms"], default: 8_000)
                let rebuildDelayMs = intValue(payload["rebuild_delay_ms"], default: 1_500)
                let includeStream = boolValue(payload["include_stream"], default: true)
                let requestedMode = captureModeValue(payload["capture_mode"])
                let requestedStrategy = captureStrategyValue(payload["capture_strategy"])
                let result = await self.runCaptureRebuildProbe(
                    durationMs: durationMs,
                    rebuildDelayMs: rebuildDelayMs,
                    captureMode: requestedMode,
                    captureStrategy: requestedStrategy,
                    includeStream: includeStream
                )
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: result.success ? "completed" : "failed",
                    payload: result.payload
                )
            case "capture_mode_matrix_probe":
                let perModeDurationMs = intValue(payload["per_mode_duration_ms"], default: 4_000)
                let includeStream = boolValue(payload["include_stream"], default: false)
                let requestedStrategy = captureStrategyValue(payload["capture_strategy"])
                let result = await self.runCaptureModeMatrixProbe(
                    perModeDurationMs: perModeDurationMs,
                    captureStrategy: requestedStrategy,
                    includeStream: includeStream
                )
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: result.success ? "completed" : "failed",
                    payload: result.payload
                )
            case "capture_strategy_matrix_probe":
                let perStrategyDurationMs = intValue(payload["per_strategy_duration_ms"], default: 4_000)
                let includeStream = boolValue(payload["include_stream"], default: false)
                let requestedMode = captureModeValue(payload["capture_mode"])
                let result = await self.runCaptureStrategyMatrixProbe(
                    perStrategyDurationMs: perStrategyDurationMs,
                    captureMode: requestedMode,
                    includeStream: includeStream
                )
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: result.success ? "completed" : "failed",
                    payload: result.payload
                )
            default:
                await self.postDiagnosticsReport(
                    commandID: commandID,
                    reportType: commandName,
                    status: "failed",
                    payload: [
                        "error": "Unsupported diagnostics command: \(commandName)",
                        "snapshot": self.diagnosticsSnapshotPayload(),
                    ]
                )
            }
        }
        await remoteDiagnosticsTask?.value
        remoteDiagnosticsTask = nil
    }

    private func handleOutgoingAudioChunk(_ chunk: AudioChunkEnvelope) async {
        let now = Date()
        audioChunksObserved += 1
        if firstAudioChunkObservedAt == nil {
            firstAudioChunkObservedAt = now
        }
        lastAudioChunkObservedAt = now

        let localAnalysis = analyzeOutgoingChunk(base64: chunk.base64, sampleRate: chunk.sampleRate)

        let result = await streamClient.sendAudio(base64Float32: chunk.base64)
        let sequence = nextOutgoingChunkSequence()
        rememberOutgoingChunk(
            OutgoingAudioChunkRecord(
                sequence: sequence,
                createdAt: now,
                sampleRate: chunk.sampleRate,
                encodedBytes: result.encodedBytes,
                decodedBytes: result.decodedBytes,
                base64: chunk.base64,
                analysis: localAnalysis
            )
        )
        if result.success {
            audioChunksSent += 1
            audioBytesEncodedSent += result.encodedBytes
            audioBytesDecodedSent += result.decodedBytes
            if firstAudioChunkSentAt == nil {
                firstAudioChunkSentAt = now
            }
            lastAudioChunkSentAt = now
        } else {
            audioSendFailures += 1
            lastAudioSendFailureAt = now
        }
    }

    private func runAudioProbe(durationMs: Int) async -> (success: Bool, payload: [String: Any]) {
        let initialSnapshot = diagnosticsSnapshotPayload()
        let usedExistingCapture = isRunning
        var startedLocalCapture = false

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: settings.captureMode, strategy: settings.captureStrategy)
                startedLocalCapture = true
            } catch {
                return (
                    false,
                    [
                        "error": error.localizedDescription,
                        "initial_snapshot": initialSnapshot,
                        "final_snapshot": diagnosticsSnapshotPayload(),
                    ]
                )
            }
        }

        let observation = await observeProbe(durationMs: durationMs)

        if startedLocalCapture {
            audioCapture.stop()
        }

        return (
            true,
            [
                "duration_ms": durationMs,
                "used_existing_capture": usedExistingCapture,
                "started_local_capture": startedLocalCapture,
                "initial_snapshot": initialSnapshot,
                "probe_observation": observation,
                "final_snapshot": diagnosticsSnapshotPayload(),
            ]
        )
    }

    private func runStreamProbe(durationMs: Int) async -> (success: Bool, payload: [String: Any]) {
        let initialSnapshot = diagnosticsSnapshotPayload()
        let usedExistingCapture = isRunning
        let usedExistingStream = isRunning || streamStatus == .connected || streamStatus == .connecting || streamStatus == .reconnecting
        var startedLocalStream = false
        var startedLocalCapture = false

        if !usedExistingStream {
            guard let wsBaseURL = settings.webSocketBaseURL else {
                return (
                    false,
                    [
                        "error": NetworkError.invalidBaseURL.localizedDescription ?? "Invalid base URL.",
                        "initial_snapshot": initialSnapshot,
                    ]
                )
            }
            let configuration = StreamSocketClient.StreamConfiguration(
                url: wsBaseURL,
                churchID: settings.churchID,
                sampleRate: settings.captureStrategy.targetSampleRate,
                sourceScriptureVersion: settings.sourceScriptureVersion,
                displayScriptureVersion: settings.displayScriptureVersion
            )
            await streamClient.connect(configuration: configuration)
            startedLocalStream = true
            try? await Task.sleep(for: .milliseconds(500))
        }

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: settings.captureMode, strategy: settings.captureStrategy)
                startedLocalCapture = true
            } catch {
                if startedLocalStream {
                    await streamClient.disconnect()
                }
                return (
                    false,
                    [
                        "error": error.localizedDescription,
                        "initial_snapshot": initialSnapshot,
                        "final_snapshot": diagnosticsSnapshotPayload(),
                    ]
                )
            }
        }

        let observation = await observeProbe(durationMs: durationMs)

        if startedLocalCapture {
            audioCapture.stop()
        }
        if startedLocalStream {
            await streamClient.disconnect()
        }

        let finalSnapshot = diagnosticsSnapshotPayload()
        let finalStream = finalSnapshot["stream"] as? [String: Any]
        let initialStream = initialSnapshot["stream"] as? [String: Any]
        let sessionStarted = (finalStream?["session_id"] as? Int) != nil || (initialStream?["session_id"] as? Int) != nil
        let batchesSent = (((observation["diagnostics_summary"] as? [String: Any])?["batches_sent_delta"] as? Int) ?? 0) > 0

        return (
            sessionStarted || batchesSent,
            [
                "duration_ms": durationMs,
                "used_existing_capture": usedExistingCapture,
                "used_existing_stream": usedExistingStream,
                "started_local_capture": startedLocalCapture,
                "started_local_stream": startedLocalStream,
                "initial_snapshot": initialSnapshot,
                "probe_observation": observation,
                "final_snapshot": finalSnapshot,
            ]
        )
    }

    private func runPersonalInterpreterProbe(durationMs: Int) async -> (success: Bool, payload: [String: Any]) {
        let initialSnapshot = diagnosticsSnapshotPayload()
        let initialInterpreter = interpreterProbeSnapshot()
        let usedExistingCapture = isRunning
        let usedExistingStream = isRunning || streamStatus == .connected || streamStatus == .connecting || streamStatus == .reconnecting
        var startedLocalStream = false
        var startedLocalCapture = false

        if !usedExistingStream {
            guard let wsBaseURL = settings.webSocketBaseURL else {
                return (
                    false,
                    [
                        "error": NetworkError.invalidBaseURL.localizedDescription ?? "Invalid base URL.",
                        "initial_snapshot": initialSnapshot,
                    ]
                )
            }
            let configuration = StreamSocketClient.StreamConfiguration(
                url: wsBaseURL,
                churchID: settings.churchID,
                sampleRate: settings.captureStrategy.targetSampleRate,
                sourceScriptureVersion: settings.sourceScriptureVersion,
                displayScriptureVersion: settings.displayScriptureVersion
            )
            await streamClient.connect(configuration: configuration)
            startedLocalStream = true
            try? await Task.sleep(for: .milliseconds(500))
        }

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: settings.captureMode, strategy: settings.captureStrategy)
                startedLocalCapture = true
            } catch {
                if startedLocalStream {
                    await streamClient.disconnect()
                }
                return (
                    false,
                    [
                        "error": error.localizedDescription,
                        "initial_snapshot": initialSnapshot,
                        "final_snapshot": diagnosticsSnapshotPayload(),
                    ]
                )
            }
        }

        let observation = await observeProbe(durationMs: durationMs)

        if startedLocalCapture {
            audioCapture.stop()
        }
        if startedLocalStream {
            await streamClient.disconnect()
        }

        let finalSnapshot = diagnosticsSnapshotPayload()
        let finalInterpreter = interpreterProbeSnapshot()
        let stageChecks = personalInterpreterStageChecks(
            initial: initialInterpreter,
            final: finalInterpreter,
            observation: observation,
            initialSnapshot: initialSnapshot,
            finalSnapshot: finalSnapshot
        )
        let success = (stageChecks["microphone_permission_granted"] as? Bool ?? false)
            && (stageChecks["engine_running"] as? Bool ?? false)
            && (stageChecks["audio_chunks_observed"] as? Bool ?? false)
            && (stageChecks["audio_chunks_sent"] as? Bool ?? false)
            && (stageChecks["session_started"] as? Bool ?? false)
            && (stageChecks["translation_received"] as? Bool ?? false)

        return (
            success,
            [
                "duration_ms": durationMs,
                "used_existing_capture": usedExistingCapture,
                "used_existing_stream": usedExistingStream,
                "started_local_capture": startedLocalCapture,
                "started_local_stream": startedLocalStream,
                "initial_snapshot": initialSnapshot,
                "probe_observation": observation,
                "stage_checks": stageChecks,
                "final_snapshot": finalSnapshot,
            ]
        )
    }

    private func runAudioForensicsProbe(durationMs: Int, maxChunks: Int) async -> (success: Bool, payload: [String: Any]) {
        let initialSnapshot = diagnosticsSnapshotPayload()
        let initialSequence = outgoingChunkSequence
        let usedExistingCapture = isRunning
        let usedExistingStream = isRunning || streamStatus == .connected || streamStatus == .connecting || streamStatus == .reconnecting
        var startedLocalStream = false
        var startedLocalCapture = false

        if !usedExistingStream {
            guard let wsBaseURL = settings.webSocketBaseURL else {
                return (
                    false,
                    [
                        "error": NetworkError.invalidBaseURL.localizedDescription ?? "Invalid base URL.",
                        "initial_snapshot": initialSnapshot,
                    ]
                )
            }
            let configuration = StreamSocketClient.StreamConfiguration(
                url: wsBaseURL,
                churchID: settings.churchID,
                sampleRate: settings.captureStrategy.targetSampleRate,
                sourceScriptureVersion: settings.sourceScriptureVersion,
                displayScriptureVersion: settings.displayScriptureVersion
            )
            await streamClient.connect(configuration: configuration)
            startedLocalStream = true
            try? await Task.sleep(for: .milliseconds(500))
        }

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: settings.captureMode, strategy: settings.captureStrategy)
                startedLocalCapture = true
            } catch {
                if startedLocalStream {
                    await streamClient.disconnect()
                }
                return (
                    false,
                    [
                        "error": error.localizedDescription,
                        "initial_snapshot": initialSnapshot,
                        "final_snapshot": diagnosticsSnapshotPayload(),
                    ]
                )
            }
        }

        let observation = await observeProbe(durationMs: durationMs)
        let newChunks = recentOutgoingChunks
            .filter { $0.sequence > initialSequence }
            .suffix(max(1, min(maxChunks, 5)))
        let localChunks = newChunks.map(chunkPayload)
        let serverAnalyses = await requestServerChunkAnalyses(for: Array(newChunks))

        if startedLocalCapture {
            audioCapture.stop()
        }
        if startedLocalStream {
            await streamClient.disconnect()
        }

        let successfulServerAnalyses = serverAnalyses.filter { ($0["analysis"] as? [String: Any]) != nil }
        let looksLikeSpeech = successfulServerAnalyses.contains { item in
            let analysis = item["analysis"] as? [String: Any]
            let float32 = analysis?["float32"] as? [String: Any]
            return (float32?["looks_like_speech_energy"] as? Bool) ?? false
        }

        return (
            !newChunks.isEmpty && !successfulServerAnalyses.isEmpty && looksLikeSpeech,
            [
                "duration_ms": durationMs,
                "used_existing_capture": usedExistingCapture,
                "used_existing_stream": usedExistingStream,
                "started_local_capture": startedLocalCapture,
                "started_local_stream": startedLocalStream,
                "initial_snapshot": initialSnapshot,
                "probe_observation": observation,
                "local_chunk_count": newChunks.count,
                "local_chunks": localChunks,
                "server_analyses": serverAnalyses,
                "final_snapshot": diagnosticsSnapshotPayload(),
            ]
        )
    }

    private func runCapturePipelineProbe(
        durationMs: Int,
        captureMode: CaptureMode?,
        captureStrategy: AudioCaptureStrategy?,
        includeStream: Bool
    ) async -> (success: Bool, payload: [String: Any]) {
        let requestedMode = captureMode ?? settings.captureMode
        let requestedStrategy = captureStrategy ?? settings.captureStrategy
        if isRunning && (requestedMode != settings.captureMode || requestedStrategy != settings.captureStrategy) {
            return (
                false,
                [
                    "error": "Stop the current test before probing a different capture configuration.",
                    "requested_mode": requestedMode.rawValue,
                    "requested_strategy": requestedStrategy.rawValue,
                    "current_mode": settings.captureMode.rawValue,
                    "current_strategy": settings.captureStrategy.rawValue,
                    "initial_snapshot": diagnosticsSnapshotPayload(),
                ]
            )
        }

        let initialSnapshot = diagnosticsSnapshotPayload()
        let usedExistingCapture = isRunning
        let usedExistingStream = includeStream && streamIsActive
        var startedLocalStream = false
        var startedLocalCapture = false

        if includeStream, !usedExistingStream {
            guard await connectStreamForDiagnostics(sampleRate: requestedStrategy.targetSampleRate) else {
                return (
                    false,
                    [
                        "error": NetworkError.invalidBaseURL.localizedDescription ?? "Invalid base URL.",
                        "requested_mode": requestedMode.rawValue,
                        "requested_strategy": requestedStrategy.rawValue,
                        "initial_snapshot": initialSnapshot,
                    ]
                )
            }
            startedLocalStream = true
        }

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: requestedMode, strategy: requestedStrategy)
                startedLocalCapture = true
            } catch {
                if startedLocalStream {
                    await streamClient.disconnect()
                }
                return (
                    false,
                    [
                        "error": error.localizedDescription,
                        "requested_mode": requestedMode.rawValue,
                        "requested_strategy": requestedStrategy.rawValue,
                        "initial_snapshot": initialSnapshot,
                        "final_snapshot": diagnosticsSnapshotPayload(),
                    ]
                )
            }
        }

        let observation = await observeProbe(durationMs: durationMs)
        let finalSnapshot = diagnosticsSnapshotPayload()
        let stageChecks = capturePipelineStageChecks(
            initialSnapshot: initialSnapshot,
            finalSnapshot: finalSnapshot,
            observation: observation
        )

        if startedLocalCapture {
            audioCapture.stop()
        }
        if startedLocalStream {
            await streamClient.disconnect()
        }

        let tapCallbacksSeen = stageChecks["tap_callbacks_seen"] as? Bool ?? false
        let convertedFramesSeen = stageChecks["converted_frames_seen"] as? Bool ?? false
        let chunksSent = stageChecks["audio_chunks_sent"] as? Bool ?? false
        return (
            tapCallbacksSeen || convertedFramesSeen || chunksSent,
            [
                "duration_ms": durationMs,
                "requested_mode": requestedMode.rawValue,
                "requested_strategy": requestedStrategy.rawValue,
                "include_stream": includeStream,
                "used_existing_capture": usedExistingCapture,
                "used_existing_stream": usedExistingStream,
                "started_local_capture": startedLocalCapture,
                "started_local_stream": startedLocalStream,
                "initial_snapshot": initialSnapshot,
                "probe_observation": observation,
                "stage_checks": stageChecks,
                "final_snapshot": finalSnapshot,
            ]
        )
    }

    private func runCaptureRebuildProbe(
        durationMs: Int,
        rebuildDelayMs: Int,
        captureMode: CaptureMode?,
        captureStrategy: AudioCaptureStrategy?,
        includeStream: Bool
    ) async -> (success: Bool, payload: [String: Any]) {
        let requestedMode = captureMode ?? settings.captureMode
        let requestedStrategy = captureStrategy ?? settings.captureStrategy
        if isRunning && (requestedMode != settings.captureMode || requestedStrategy != settings.captureStrategy) {
            return (
                false,
                [
                    "error": "Stop the current test before probing a different capture configuration.",
                    "requested_mode": requestedMode.rawValue,
                    "requested_strategy": requestedStrategy.rawValue,
                    "current_mode": settings.captureMode.rawValue,
                    "current_strategy": settings.captureStrategy.rawValue,
                    "initial_snapshot": diagnosticsSnapshotPayload(),
                ]
            )
        }

        let initialSnapshot = diagnosticsSnapshotPayload()
        let usedExistingCapture = isRunning
        let usedExistingStream = includeStream && streamIsActive
        var startedLocalStream = false
        var startedLocalCapture = false

        if includeStream, !usedExistingStream {
            guard await connectStreamForDiagnostics(sampleRate: requestedStrategy.targetSampleRate) else {
                return (
                    false,
                    [
                        "error": NetworkError.invalidBaseURL.localizedDescription ?? "Invalid base URL.",
                        "requested_mode": requestedMode.rawValue,
                        "requested_strategy": requestedStrategy.rawValue,
                        "initial_snapshot": initialSnapshot,
                    ]
                )
            }
            startedLocalStream = true
        }

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: requestedMode, strategy: requestedStrategy)
                startedLocalCapture = true
            } catch {
                if startedLocalStream {
                    await streamClient.disconnect()
                }
                return (
                    false,
                    [
                        "error": error.localizedDescription,
                        "requested_mode": requestedMode.rawValue,
                        "requested_strategy": requestedStrategy.rawValue,
                        "initial_snapshot": initialSnapshot,
                        "final_snapshot": diagnosticsSnapshotPayload(),
                    ]
                )
            }
        }

        let settledSnapshot = diagnosticsSnapshotPayload()
        try? await Task.sleep(for: .milliseconds(max(250, rebuildDelayMs)))
        let rebuildSucceeded = await audioCapture.forceDiagnosticRebuild(reason: "remote capture rebuild probe")
        let postRebuildSnapshot = diagnosticsSnapshotPayload()
        let observation = await observeProbe(durationMs: max(1_000, durationMs - rebuildDelayMs))
        let finalSnapshot = diagnosticsSnapshotPayload()
        let stageChecks = capturePipelineStageChecks(
            initialSnapshot: postRebuildSnapshot,
            finalSnapshot: finalSnapshot,
            observation: observation
        )

        if startedLocalCapture {
            audioCapture.stop()
        }
        if startedLocalStream {
            await streamClient.disconnect()
        }

        return (
            rebuildSucceeded && ((stageChecks["tap_callbacks_seen"] as? Bool ?? false) || (stageChecks["converted_frames_seen"] as? Bool ?? false)),
            [
                "duration_ms": durationMs,
                "rebuild_delay_ms": rebuildDelayMs,
                "requested_mode": requestedMode.rawValue,
                "requested_strategy": requestedStrategy.rawValue,
                "include_stream": includeStream,
                "used_existing_capture": usedExistingCapture,
                "used_existing_stream": usedExistingStream,
                "started_local_capture": startedLocalCapture,
                "started_local_stream": startedLocalStream,
                "rebuild_succeeded": rebuildSucceeded,
                "initial_snapshot": initialSnapshot,
                "settled_snapshot": settledSnapshot,
                "post_rebuild_snapshot": postRebuildSnapshot,
                "probe_observation": observation,
                "stage_checks": stageChecks,
                "final_snapshot": finalSnapshot,
            ]
        )
    }

    private func runCaptureModeMatrixProbe(
        perModeDurationMs: Int,
        captureStrategy: AudioCaptureStrategy?,
        includeStream: Bool
    ) async -> (success: Bool, payload: [String: Any]) {
        if isRunning || streamIsActive {
            return (
                false,
                [
                    "error": "Stop the current test before running the capture mode matrix probe.",
                    "initial_snapshot": diagnosticsSnapshotPayload(),
                ]
            )
        }

        let initialSnapshot = diagnosticsSnapshotPayload()
        var results: [[String: Any]] = []
        var anyExecuted = false
        let requestedStrategy = captureStrategy ?? settings.captureStrategy

        for mode in CaptureMode.allCases {
            let probe = await runCapturePipelineProbe(
                durationMs: perModeDurationMs,
                captureMode: mode,
                captureStrategy: requestedStrategy,
                includeStream: includeStream
            )
            results.append([
                "capture_mode": mode.rawValue,
                "capture_strategy": requestedStrategy.rawValue,
                "success": probe.success,
                "payload": probe.payload,
            ])
            anyExecuted = true
        }

        return (
            anyExecuted,
            [
                "per_mode_duration_ms": perModeDurationMs,
                "include_stream": includeStream,
                "capture_strategy": requestedStrategy.rawValue,
                "initial_snapshot": initialSnapshot,
                "mode_results": results,
                "final_snapshot": diagnosticsSnapshotPayload(),
            ]
        )
    }

    private func runCaptureStrategyMatrixProbe(
        perStrategyDurationMs: Int,
        captureMode: CaptureMode?,
        includeStream: Bool
    ) async -> (success: Bool, payload: [String: Any]) {
        if isRunning || streamIsActive {
            return (
                false,
                [
                    "error": "Stop the current test before running the capture strategy matrix probe.",
                    "initial_snapshot": diagnosticsSnapshotPayload(),
                ]
            )
        }

        let requestedMode = captureMode ?? settings.captureMode
        let initialSnapshot = diagnosticsSnapshotPayload()
        var results: [[String: Any]] = []

        for strategy in AudioCaptureStrategy.allCases {
            let probe = await runCapturePipelineProbe(
                durationMs: perStrategyDurationMs,
                captureMode: requestedMode,
                captureStrategy: strategy,
                includeStream: includeStream
            )
            results.append([
                "capture_mode": requestedMode.rawValue,
                "capture_strategy": strategy.rawValue,
                "success": probe.success,
                "payload": probe.payload,
            ])
        }

        return (
            !results.isEmpty,
            [
                "per_strategy_duration_ms": perStrategyDurationMs,
                "capture_mode": requestedMode.rawValue,
                "include_stream": includeStream,
                "initial_snapshot": initialSnapshot,
                "strategy_results": results,
                "final_snapshot": diagnosticsSnapshotPayload(),
            ]
        )
    }

    private func observeProbe(durationMs: Int) async -> [String: Any] {
        let sampleCount = max(1, min(20, durationMs / 250))
        let startBatches = diagnostics.batchesSent
        let startInterpreter = interpreterProbeSnapshot()
        let startTapCallbacks = diagnostics.tapCallbackCount
        let startConvertedFrames = diagnostics.convertedFrameCount
        let startProcessingInvocations = diagnostics.processingInvocationCount
        let startPendingHighWater = diagnostics.pendingSampleHighWaterMark
        let startRestarts = diagnostics.captureRestartCount
        let startDate = Date()
        var peakRms = diagnostics.rmsLevel
        var peakNoiseFloor = diagnostics.noiseFloor
        var speechSeen = diagnostics.speechDetected
        var clippingSeen = diagnostics.clipping
        var samples: [[String: Any]] = []

        for _ in 0..<sampleCount {
            try? await Task.sleep(for: .milliseconds(max(100, durationMs / sampleCount)))
            peakRms = max(peakRms, diagnostics.rmsLevel)
            peakNoiseFloor = max(peakNoiseFloor, diagnostics.noiseFloor)
            speechSeen = speechSeen || diagnostics.speechDetected
            clippingSeen = clippingSeen || diagnostics.clipping
            samples.append([
                "offset_ms": Int(Date().timeIntervalSince(startDate) * 1000),
                "rms_level": diagnostics.rmsLevel,
                "noise_floor": diagnostics.noiseFloor,
                "speech_detected": diagnostics.speechDetected,
                "clipping": diagnostics.clipping,
                "batches_sent": diagnostics.batchesSent,
                "stream_status": streamStatus.rawValue,
                "display_connected": displayConnected,
                "audio_chunks_observed": audioChunksObserved,
                "audio_chunks_sent": audioChunksSent,
                "audio_send_failures": audioSendFailures,
                "translation_event_count": translationEventCount,
                "display_event_count": displayEventCount,
                "session_start_count": sessionStartCount,
                "tap_callback_count": diagnostics.tapCallbackCount,
                "tap_frame_count": diagnostics.tapFrameCount,
                "processing_invocation_count": diagnostics.processingInvocationCount,
                "conversion_success_count": diagnostics.conversionSuccessCount,
                "converted_frame_count": diagnostics.convertedFrameCount,
                "zero_frame_conversion_count": diagnostics.zeroFrameConversionCount,
                "pending_sample_count": diagnostics.pendingSampleCount,
                "pending_sample_high_water_mark": diagnostics.pendingSampleHighWaterMark,
                "capture_restart_count": diagnostics.captureRestartCount,
            ])
        }

        let finalInterpreter = interpreterProbeSnapshot()
        return [
            "diagnostics_summary": [
                "peak_rms_level": peakRms,
                "peak_noise_floor": peakNoiseFloor,
                "speech_seen": speechSeen,
                "clipping_seen": clippingSeen,
                "batches_sent_delta": diagnostics.batchesSent - startBatches,
                "audio_chunks_observed_delta": finalInterpreter.audioChunksObserved - startInterpreter.audioChunksObserved,
                "audio_chunks_sent_delta": finalInterpreter.audioChunksSent - startInterpreter.audioChunksSent,
                "audio_send_failures_delta": finalInterpreter.audioSendFailures - startInterpreter.audioSendFailures,
                "audio_bytes_encoded_sent_delta": finalInterpreter.audioBytesEncodedSent - startInterpreter.audioBytesEncodedSent,
                "audio_bytes_decoded_sent_delta": finalInterpreter.audioBytesDecodedSent - startInterpreter.audioBytesDecodedSent,
                "display_event_count_delta": finalInterpreter.displayEventCount - startInterpreter.displayEventCount,
                "translation_event_count_delta": finalInterpreter.translationEventCount - startInterpreter.translationEventCount,
                "session_start_count_delta": finalInterpreter.sessionStartCount - startInterpreter.sessionStartCount,
                "tap_callback_count_delta": diagnostics.tapCallbackCount - startTapCallbacks,
                "processing_invocation_count_delta": diagnostics.processingInvocationCount - startProcessingInvocations,
                "converted_frame_count_delta": diagnostics.convertedFrameCount - startConvertedFrames,
                "pending_sample_high_water_mark_delta": diagnostics.pendingSampleHighWaterMark - startPendingHighWater,
                "capture_restart_count_delta": diagnostics.captureRestartCount - startRestarts,
                "stream_status": streamStatus.rawValue,
                "display_connected": displayConnected,
                "latest_error": latestError,
            ],
            "samples": samples,
        ]
    }

    private func diagnosticsSnapshotPayload() -> [String: Any] {
        [
            "settings": [
                "base_url": settings.baseURLString,
                "church_id": settings.churchID,
                "source_scripture_version": settings.sourceScriptureVersion,
                "display_scripture_version": settings.displayScriptureVersion,
                "capture_mode": settings.captureMode.rawValue,
            ],
            "stream": [
                "status": streamStatus.rawValue,
                "display_connected": displayConnected,
                "session_id": jsonValue(sessionID),
                "session_started_at": jsonValue(sessionStartedAt?.ISO8601Format()),
                "is_running": isRunning,
                "latest_error": latestError,
            ],
            "audio": [
                "route_name": diagnostics.routeName,
                "route_inputs": diagnostics.routeInputs,
                "route_outputs": diagnostics.routeOutputs,
                "capture_path": diagnostics.capturePath,
                "capture_strategy": diagnostics.captureStrategy,
                "fallback_reason": diagnostics.fallbackReason,
                "input_sample_rate": diagnostics.inputSampleRate,
                "target_sample_rate": diagnostics.targetSampleRate,
                "emitted_sample_rate": diagnostics.emittedSampleRate,
                "chunk_sample_count": diagnostics.chunkSampleCount,
                "input_channels": diagnostics.inputChannels,
                "input_format_description": diagnostics.inputFormatDescription,
                "clipping": diagnostics.clipping,
                "speech_detected": diagnostics.speechDetected,
                "last_speech_at": jsonValue(diagnostics.lastSpeechAt?.ISO8601Format()),
                "rms_level": diagnostics.rmsLevel,
                "noise_floor": diagnostics.noiseFloor,
                "batches_sent": diagnostics.batchesSent,
                "last_batch_at": jsonValue(diagnostics.lastBatchAt?.ISO8601Format()),
                "voice_processing_requested": diagnostics.voiceProcessingRequested,
                "voice_processing_enabled": diagnostics.voiceProcessingEnabled,
                "voice_processing_agc_enabled": diagnostics.voiceProcessingAGCEnabled,
                "echo_cancelled_input_available": diagnostics.echoCancelledInputAvailable,
                "echo_cancelled_input_enabled": diagnostics.echoCancelledInputEnabled,
                "microphone_permission_granted": diagnostics.microphonePermissionGranted,
                "engine_running": diagnostics.engineRunning,
                "tap_callback_count": diagnostics.tapCallbackCount,
                "tap_frame_count": diagnostics.tapFrameCount,
                "last_tap_at": jsonValue(diagnostics.lastTapAt?.ISO8601Format()),
                "copy_mono_success_count": diagnostics.copyMonoSuccessCount,
                "copy_mono_failure_count": diagnostics.copyMonoFailureCount,
                "processing_invocation_count": diagnostics.processingInvocationCount,
                "conversion_success_count": diagnostics.conversionSuccessCount,
                "conversion_failure_count": diagnostics.conversionFailureCount,
                "zero_frame_conversion_count": diagnostics.zeroFrameConversionCount,
                "converted_frame_count": diagnostics.convertedFrameCount,
                "last_converted_at": jsonValue(diagnostics.lastConvertedAt?.ISO8601Format()),
                "pending_sample_count": diagnostics.pendingSampleCount,
                "pending_sample_high_water_mark": diagnostics.pendingSampleHighWaterMark,
                "capture_restart_count": diagnostics.captureRestartCount,
                "last_restart_at": jsonValue(diagnostics.lastRestartAt?.ISO8601Format()),
                "last_restart_reason": diagnostics.lastRestartReason,
            ],
            "interpreter": [
                "audio_chunks_observed": audioChunksObserved,
                "audio_chunks_sent": audioChunksSent,
                "audio_send_failures": audioSendFailures,
                "audio_bytes_encoded_sent": audioBytesEncodedSent,
                "audio_bytes_decoded_sent": audioBytesDecodedSent,
                "first_audio_chunk_observed_at": jsonValue(firstAudioChunkObservedAt?.ISO8601Format()),
                "last_audio_chunk_observed_at": jsonValue(lastAudioChunkObservedAt?.ISO8601Format()),
                "first_audio_chunk_sent_at": jsonValue(firstAudioChunkSentAt?.ISO8601Format()),
                "last_audio_chunk_sent_at": jsonValue(lastAudioChunkSentAt?.ISO8601Format()),
                "last_audio_send_failure_at": jsonValue(lastAudioSendFailureAt?.ISO8601Format()),
                "session_start_count": sessionStartCount,
                "display_event_count": displayEventCount,
                "translation_event_count": translationEventCount,
                "first_display_event_at": jsonValue(firstDisplayEventAt?.ISO8601Format()),
                "last_display_event_at": jsonValue(lastDisplayEventAt?.ISO8601Format()),
                "first_translation_event_at": jsonValue(firstTranslationEventAt?.ISO8601Format()),
                "last_translation_event_at": jsonValue(lastTranslationEventAt?.ISO8601Format()),
                "last_display_event_type": lastDisplayEventType,
                "display_event_type_counts": displayEventTypeCounts,
                "recent_outgoing_chunks": recentOutgoingChunks.map(chunkPayload),
            ],
            "display_feed": [
                "connected": displayFeed.snapshot.connected,
                "segment_count": displayFeed.snapshot.segments.count,
                "partial_spanish": displayFeed.snapshot.interimSpanish,
                "partial_english": displayFeed.snapshot.liveDock.english,
                "sermon_mode": displayFeed.snapshot.sermonMode,
                "last_interim_at": jsonValue(displayFeed.snapshot.lastInterimAt?.ISO8601Format()),
                "last_final_at": jsonValue(displayFeed.snapshot.lastFinalAt?.ISO8601Format()),
                "last_translation_at": jsonValue(displayFeed.snapshot.lastTranslationAt?.ISO8601Format()),
                "last_interim_spanish": displayFeed.snapshot.lastInterimSpanish,
                "last_final_spanish": displayFeed.snapshot.lastFinalSpanish,
                "last_committed_english": displayFeed.snapshot.lastCommittedEnglish,
            ],
        ]
    }

    private func postDiagnosticsReport(
        commandID: String,
        reportType: String,
        status: String,
        payload: [String: Any]
    ) async {
        guard let apiBaseURL = settings.apiBaseURL else {
            latestError = NetworkError.invalidBaseURL.localizedDescription ?? "Invalid base URL."
            return
        }

        let endpoint = apiBaseURL
            .appending(path: "api")
            .appending(path: "churches")
            .appending(path: settings.churchID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settings.churchID)
            .appending(path: "mobile-diagnostics")
            .appending(path: "reports")

        let body: [String: Any] = [
            "command_id": commandID,
            "report_type": reportType,
            "status": status,
            "payload": payload,
            "device": deviceMetadataPayload(),
            "app": appMetadataPayload(),
        ]

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                latestError = "Diagnostics report failed with HTTP \(http.statusCode)."
            }
        } catch {
            latestError = "Diagnostics report failed: \(error.localizedDescription)"
        }
    }

    private func deviceMetadataPayload() -> [String: Any] {
        let device = UIDevice.current
        return [
            "name": device.name,
            "model": device.model,
            "system_name": device.systemName,
            "system_version": device.systemVersion,
            "identifier_for_vendor": jsonValue(device.identifierForVendor?.uuidString),
        ]
    }

    private func appMetadataPayload() -> [String: Any] {
        let info = Bundle.main.infoDictionary ?? [:]
        return [
            "bundle_identifier": jsonValue(Bundle.main.bundleIdentifier),
            "app_version": jsonValue(info["CFBundleShortVersionString"] as? String),
            "build_number": jsonValue(info["CFBundleVersion"] as? String),
        ]
    }

    private func intValue(_ value: Any?, default defaultValue: Int) -> Int {
        if let int = value as? Int {
            return int
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        if let string = value as? String, let int = Int(string) {
            return int
        }
        return defaultValue
    }

    private func boolValue(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let bool = value as? Bool {
            return bool
        }
        if let number = value as? NSNumber {
            return number.boolValue
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "1", "yes", "y", "on":
                return true
            case "false", "0", "no", "n", "off":
                return false
            default:
                break
            }
        }
        return defaultValue
    }

    private func captureModeValue(_ value: Any?) -> CaptureMode? {
        guard let string = value as? String else { return nil }
        let normalized = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        switch normalized {
        case "voiceprocessing", "voice":
            return .voiceProcessing
        case "echocancelled", "echo":
            return .echoCancelled
        case "rawdebug", "raw":
            return .rawDebug
        default:
            return CaptureMode(rawValue: string)
        }
    }

    private func captureStrategyValue(_ value: Any?) -> AudioCaptureStrategy? {
        guard let string = value as? String else { return nil }
        let normalized = string
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
            .lowercased()

        switch normalized {
        case "applevoicepassthrough", "apple", "passthrough", "serverresample":
            return .appleVoicePassthrough
        case "persistentconverter", "persistent", "streamingconverter":
            return .persistentConverter
        case "ephemeralconverter", "ephemeral", "perbufferconverter":
            return .ephemeralConverter
        default:
            return AudioCaptureStrategy(rawValue: string)
        }
    }

    private func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private func analyzeOutgoingChunk(base64: String, sampleRate: Int) -> [String: Any] {
        guard let data = Data(base64Encoded: base64) else {
            return [
                "decode_error": true,
                "sample_count": 0,
                "sample_rate": sampleRate,
            ]
        }
        let floats: [Float] = data.withUnsafeBytes { rawBuffer in
            let bound = rawBuffer.bindMemory(to: Float.self)
            return Array(bound)
        }
        guard !floats.isEmpty else {
            return [
                "decode_error": false,
                "sample_count": 0,
                "looks_silent": true,
                "sample_rate": sampleRate,
            ]
        }

        var peak: Float = 0
        var sumSquares: Float = 0
        var sumAbs: Float = 0
        var nearZeroCount = 0
        var clippingCount = 0
        var zeroCrossings = 0
        var previousSign = floats[0] >= 0

        for sample in floats {
            let abs = Swift.abs(sample)
            peak = max(peak, abs)
            sumSquares += sample * sample
            sumAbs += abs
            if abs < 0.001 { nearZeroCount += 1 }
            if abs >= 0.98 { clippingCount += 1 }
            let currentSign = sample >= 0
            if currentSign != previousSign {
                zeroCrossings += 1
            }
            previousSign = currentSign
        }

        let count = Float(floats.count)
        let rms = sqrt(sumSquares / max(count, 1.0))
        let nearZeroRatio = Float(nearZeroCount) / max(count, 1.0)
        let clippingRatio = Float(clippingCount) / max(count, 1.0)
        return [
            "sample_count": floats.count,
            "sample_rate": sampleRate,
            "duration_ms": Double(floats.count) / max(Double(sampleRate) / 1000.0, 1.0),
            "rms": Double(rms),
            "peak": Double(peak),
            "mean_abs": Double(sumAbs / max(count, 1.0)),
            "near_zero_ratio": Double(nearZeroRatio),
            "clipping_ratio": Double(clippingRatio),
            "zero_crossing_ratio": Double(Float(zeroCrossings) / max(count - 1.0, 1.0)),
            "looks_silent": rms < 0.005 && nearZeroRatio > 0.9,
            "looks_like_speech_energy": rms >= 0.01 && peak >= 0.03 && nearZeroRatio < 0.98,
            "sample_preview": floats.prefix(16).map { Double($0) },
        ]
    }

    private func nextOutgoingChunkSequence() -> Int {
        outgoingChunkSequence += 1
        return outgoingChunkSequence
    }

    private func rememberOutgoingChunk(_ record: OutgoingAudioChunkRecord) {
        recentOutgoingChunks.append(record)
        if recentOutgoingChunks.count > 8 {
            recentOutgoingChunks.removeFirst(recentOutgoingChunks.count - 8)
        }
    }

    private func chunkPayload(_ chunk: OutgoingAudioChunkRecord) -> [String: Any] {
        [
            "sequence": chunk.sequence,
            "created_at": chunk.createdAt.ISO8601Format(),
            "sample_rate": chunk.sampleRate,
            "encoded_bytes": chunk.encodedBytes,
            "decoded_bytes": chunk.decodedBytes,
            "analysis": chunk.analysis,
        ]
    }

    private func requestServerChunkAnalyses(for chunks: [OutgoingAudioChunkRecord]) async -> [[String: Any]] {
        guard !chunks.isEmpty, let apiBaseURL = settings.apiBaseURL else { return [] }

        let endpoint = apiBaseURL
            .appending(path: "api")
            .appending(path: "churches")
            .appending(path: settings.churchID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? settings.churchID)
            .appending(path: "mobile-diagnostics")
            .appending(path: "analyses")
            .appending(path: "audio-chunk")

        var responses: [[String: Any]] = []
        for chunk in chunks {
            let body: [String: Any] = [
                "audio_base64": chunk.base64,
                "sample_rate": chunk.sampleRate,
                "label": "chunk-\(chunk.sequence)",
            ]

            do {
                var request = URLRequest(url: endpoint)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    responses.append([
                        "sequence": chunk.sequence,
                        "error": "Server analysis returned no HTTP response.",
                    ])
                    continue
                }
                guard (200..<300).contains(http.statusCode) else {
                    responses.append([
                        "sequence": chunk.sequence,
                        "error": "Server analysis failed with HTTP \(http.statusCode).",
                    ])
                    continue
                }
                let json = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                responses.append([
                    "sequence": chunk.sequence,
                    "label": json["label"] as? String ?? "chunk-\(chunk.sequence)",
                    "byte_length": json["byte_length"] as? Int ?? 0,
                    "analysis": json["analysis"] as? [String: Any] ?? [:],
                ])
            } catch {
                responses.append([
                    "sequence": chunk.sequence,
                    "error": "Server analysis failed: \(error.localizedDescription)",
                ])
            }
        }
        return responses
    }

    private func recordSessionStart(_ sessionID: Int?) {
        guard sessionID != nil else { return }
        sessionStartCount += 1
        sessionStartedAt = Date()
    }

    private func recordDisplayEvent(type: String) {
        let now = Date()
        displayEventCount += 1
        if firstDisplayEventAt == nil {
            firstDisplayEventAt = now
        }
        lastDisplayEventAt = now
        lastDisplayEventType = type
        displayEventTypeCounts[type, default: 0] += 1

        if Self.translationEventTypes.contains(type) {
            translationEventCount += 1
            if firstTranslationEventAt == nil {
                firstTranslationEventAt = now
            }
            lastTranslationEventAt = now
        }
    }

    private func interpreterProbeSnapshot() -> InterpreterProbeSnapshot {
        InterpreterProbeSnapshot(
            audioChunksObserved: audioChunksObserved,
            audioChunksSent: audioChunksSent,
            audioSendFailures: audioSendFailures,
            audioBytesEncodedSent: audioBytesEncodedSent,
            audioBytesDecodedSent: audioBytesDecodedSent,
            displayEventCount: displayEventCount,
            translationEventCount: translationEventCount,
            sessionStartCount: sessionStartCount
        )
    }

    private var streamIsActive: Bool {
        isRunning || streamStatus == .connected || streamStatus == .connecting || streamStatus == .reconnecting
    }

    private func connectStreamForDiagnostics(sampleRate: Int) async -> Bool {
        guard let wsBaseURL = settings.webSocketBaseURL else { return false }
        let configuration = StreamSocketClient.StreamConfiguration(
            url: wsBaseURL,
            churchID: settings.churchID,
            sampleRate: sampleRate,
            sourceScriptureVersion: settings.sourceScriptureVersion,
            displayScriptureVersion: settings.displayScriptureVersion
        )
        await streamClient.connect(configuration: configuration)
        try? await Task.sleep(for: .milliseconds(500))
        return true
    }

    private func capturePipelineStageChecks(
        initialSnapshot: [String: Any],
        finalSnapshot: [String: Any],
        observation: [String: Any]
    ) -> [String: Any] {
        let initialAudio = initialSnapshot["audio"] as? [String: Any]
        let finalAudio = finalSnapshot["audio"] as? [String: Any]
        let summary = observation["diagnostics_summary"] as? [String: Any]

        let tapCallbacksDelta = ((finalAudio?["tap_callback_count"] as? Int) ?? 0) - ((initialAudio?["tap_callback_count"] as? Int) ?? 0)
        let processingDelta = ((finalAudio?["processing_invocation_count"] as? Int) ?? 0) - ((initialAudio?["processing_invocation_count"] as? Int) ?? 0)
        let conversionDelta = ((finalAudio?["conversion_success_count"] as? Int) ?? 0) - ((initialAudio?["conversion_success_count"] as? Int) ?? 0)
        let convertedFramesDelta = ((finalAudio?["converted_frame_count"] as? Int) ?? 0) - ((initialAudio?["converted_frame_count"] as? Int) ?? 0)
        let zeroFrameDelta = ((finalAudio?["zero_frame_conversion_count"] as? Int) ?? 0) - ((initialAudio?["zero_frame_conversion_count"] as? Int) ?? 0)
        let pendingHighWaterDelta = ((finalAudio?["pending_sample_high_water_mark"] as? Int) ?? 0) - ((initialAudio?["pending_sample_high_water_mark"] as? Int) ?? 0)
        let chunksObservedDelta = (summary?["audio_chunks_observed_delta"] as? Int) ?? 0
        let chunksSentDelta = (summary?["audio_chunks_sent_delta"] as? Int) ?? 0
        let batchesDelta = (summary?["batches_sent_delta"] as? Int) ?? 0

        let likelyFailureStage: String
        if tapCallbacksDelta == 0 {
            likelyFailureStage = "input_tap"
        } else if processingDelta == 0 {
            likelyFailureStage = "processing_queue"
        } else if conversionDelta == 0 && zeroFrameDelta > 0 {
            likelyFailureStage = "converter_zero_frames"
        } else if conversionDelta == 0 {
            likelyFailureStage = "converter"
        } else if pendingHighWaterDelta == 0 && batchesDelta == 0 {
            likelyFailureStage = "pending_buffer"
        } else if chunksObservedDelta == 0 {
            likelyFailureStage = "chunk_emission"
        } else if chunksSentDelta == 0 {
            likelyFailureStage = "socket_send"
        } else {
            likelyFailureStage = "none"
        }

        return [
            "tap_callbacks_seen": tapCallbacksDelta > 0,
            "processing_seen": processingDelta > 0,
            "converted_frames_seen": convertedFramesDelta > 0,
            "zero_frame_conversions_seen": zeroFrameDelta > 0,
            "pending_samples_accumulated": pendingHighWaterDelta > 0,
            "audio_chunks_observed": chunksObservedDelta > 0,
            "audio_chunks_sent": chunksSentDelta > 0,
            "batches_emitted": batchesDelta > 0,
            "tap_callback_count_delta": tapCallbacksDelta,
            "processing_invocation_count_delta": processingDelta,
            "conversion_success_count_delta": conversionDelta,
            "converted_frame_count_delta": convertedFramesDelta,
            "zero_frame_conversion_count_delta": zeroFrameDelta,
            "pending_sample_high_water_mark_delta": pendingHighWaterDelta,
            "likely_failure_stage": likelyFailureStage,
            "last_tap_at": finalAudio?["last_tap_at"] ?? NSNull(),
            "last_converted_at": finalAudio?["last_converted_at"] ?? NSNull(),
            "last_restart_at": finalAudio?["last_restart_at"] ?? NSNull(),
            "last_restart_reason": finalAudio?["last_restart_reason"] ?? "",
        ]
    }

    private func personalInterpreterStageChecks(
        initial: InterpreterProbeSnapshot,
        final: InterpreterProbeSnapshot,
        observation: [String: Any],
        initialSnapshot: [String: Any],
        finalSnapshot: [String: Any]
    ) -> [String: Any] {
        let initialAudio = initialSnapshot["audio"] as? [String: Any]
        let finalAudio = finalSnapshot["audio"] as? [String: Any]
        let initialStream = initialSnapshot["stream"] as? [String: Any]
        let finalStream = finalSnapshot["stream"] as? [String: Any]
        let summary = observation["diagnostics_summary"] as? [String: Any]

        let microphonePermissionGranted = (finalAudio?["microphone_permission_granted"] as? Bool ?? false)
            || (initialAudio?["microphone_permission_granted"] as? Bool ?? false)
        let engineRunning = (finalAudio?["engine_running"] as? Bool ?? false)
            || (initialAudio?["engine_running"] as? Bool ?? false)
            || ((summary?["audio_chunks_observed_delta"] as? Int) ?? 0) > 0
        let sessionStarted = ((finalStream?["session_id"] as? Int) != nil)
            || ((initialStream?["session_id"] as? Int) != nil)
            || final.sessionStartCount > initial.sessionStartCount
        let translationReceived = final.translationEventCount > initial.translationEventCount
        let speechDetected = (summary?["speech_seen"] as? Bool ?? false)
            || (finalAudio?["speech_detected"] as? Bool ?? false)
            || (initialAudio?["speech_detected"] as? Bool ?? false)

        return [
            "microphone_permission_granted": microphonePermissionGranted,
            "engine_running": engineRunning,
            "speech_detected": speechDetected,
            "audio_chunks_observed": final.audioChunksObserved > initial.audioChunksObserved,
            "audio_chunks_sent": final.audioChunksSent > initial.audioChunksSent,
            "audio_send_failures_detected": final.audioSendFailures > initial.audioSendFailures,
            "session_started": sessionStarted,
            "translation_received": translationReceived,
            "audio_chunks_observed_delta": final.audioChunksObserved - initial.audioChunksObserved,
            "audio_chunks_sent_delta": final.audioChunksSent - initial.audioChunksSent,
            "audio_send_failures_delta": final.audioSendFailures - initial.audioSendFailures,
            "audio_bytes_encoded_sent_delta": final.audioBytesEncodedSent - initial.audioBytesEncodedSent,
            "audio_bytes_decoded_sent_delta": final.audioBytesDecodedSent - initial.audioBytesDecodedSent,
            "display_event_count_delta": final.displayEventCount - initial.displayEventCount,
            "translation_event_count_delta": final.translationEventCount - initial.translationEventCount,
            "session_start_count_delta": final.sessionStartCount - initial.sessionStartCount,
        ]
    }

    private static let translationEventTypes: Set<String> = [
        "live_translation",
        "feed_commit",
        "feed_revision",
        "live_translation_clear",
    ]
}
