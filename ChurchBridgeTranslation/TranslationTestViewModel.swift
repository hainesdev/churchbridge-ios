import Foundation
import Observation
import UIKit

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

    var bibleVersions: [BibleVersionOption] = []
    var bibleVersionsError = ""
    var latestError = ""
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
        audioCapture.audioChunkHandler = { [weak self] base64 in
            Task {
                await self?.handleOutgoingAudioChunk(base64)
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

    private func handleOutgoingAudioChunk(_ base64: String) async {
        let now = Date()
        audioChunksObserved += 1
        if firstAudioChunkObservedAt == nil {
            firstAudioChunkObservedAt = now
        }
        lastAudioChunkObservedAt = now

        let localAnalysis = analyzeOutgoingChunk(base64: base64)

        let result = await streamClient.sendAudio(base64Float32: base64)
        let sequence = nextOutgoingChunkSequence()
        rememberOutgoingChunk(
            OutgoingAudioChunkRecord(
                sequence: sequence,
                createdAt: now,
                sampleRate: 16_000,
                encodedBytes: result.encodedBytes,
                decodedBytes: result.decodedBytes,
                base64: base64,
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
                try await audioCapture.start(mode: settings.captureMode)
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
                sampleRate: 16_000,
                sourceScriptureVersion: settings.sourceScriptureVersion,
                displayScriptureVersion: settings.displayScriptureVersion
            )
            await streamClient.connect(configuration: configuration)
            startedLocalStream = true
            try? await Task.sleep(for: .milliseconds(500))
        }

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: settings.captureMode)
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
                sampleRate: 16_000,
                sourceScriptureVersion: settings.sourceScriptureVersion,
                displayScriptureVersion: settings.displayScriptureVersion
            )
            await streamClient.connect(configuration: configuration)
            startedLocalStream = true
            try? await Task.sleep(for: .milliseconds(500))
        }

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: settings.captureMode)
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
                sampleRate: 16_000,
                sourceScriptureVersion: settings.sourceScriptureVersion,
                displayScriptureVersion: settings.displayScriptureVersion
            )
            await streamClient.connect(configuration: configuration)
            startedLocalStream = true
            try? await Task.sleep(for: .milliseconds(500))
        }

        if !usedExistingCapture {
            do {
                try await audioCapture.start(mode: settings.captureMode)
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

    private func observeProbe(durationMs: Int) async -> [String: Any] {
        let sampleCount = max(1, min(20, durationMs / 250))
        let startBatches = diagnostics.batchesSent
        let startInterpreter = interpreterProbeSnapshot()
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
                "fallback_reason": diagnostics.fallbackReason,
                "input_sample_rate": diagnostics.inputSampleRate,
                "target_sample_rate": diagnostics.targetSampleRate,
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
                "partial_spanish": displayFeed.snapshot.partialSpanish,
                "partial_english": displayFeed.snapshot.partialEnglish,
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

    private func jsonValue(_ value: Any?) -> Any {
        value ?? NSNull()
    }

    private func analyzeOutgoingChunk(base64: String) -> [String: Any] {
        guard let data = Data(base64Encoded: base64) else {
            return [
                "decode_error": true,
                "sample_count": 0,
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
            "duration_ms": Double(floats.count) / 16.0,
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
        "interim_translation",
        "translation",
        "translation_update",
        "correction",
    ]
}
