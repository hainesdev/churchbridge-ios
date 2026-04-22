@preconcurrency import AVFAudio
import Foundation

final class AudioCaptureManager: NSObject {
    var diagnosticsDidChange: ((AudioDiagnostics) -> Void)?
    var errorHandler: ((String) -> Void)?
    var audioChunkHandler: ((String) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "ChurchBridgeTranslation.audio-processing", qos: .userInitiated)
    private let processingQueueKey = DispatchSpecificKey<UInt8>()
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    private var hardwareInputFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var diagnostics = AudioDiagnostics()
    private var pendingSamples: [Float] = []
    // Match the browser client by sending ~100 ms of 16 kHz mono audio per websocket
    // message instead of 20 ms frames. Deepgram handles short frames, but the browser
    // path that is known-good batches before sending, so we keep the iOS transport cadence
    // aligned with that production path.
    private let chunkSamples = 1_600
    private var isRunning = false
    private var currentMode: CaptureMode?
    private var currentRequestedMode: CaptureMode?
    private var isReconfiguring = false

    override init() {
        super.init()
        processingQueue.setSpecific(key: processingQueueKey, value: 1)
        NotificationCenter.default.addObserver(self, selector: #selector(handleRouteChange), name: AVAudioSession.routeChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleInterruption), name: AVAudioSession.interruptionNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleEngineConfigurationChange), name: .AVAudioEngineConfigurationChange, object: engine)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func start(mode: CaptureMode) async throws {
        guard !isRunning else { return }

        let granted = await AVAudioApplication.requestRecordPermission()
        diagnostics.microphonePermissionGranted = granted
        publishDiagnostics()
        guard granted else {
            throw NSError(domain: "ChurchBridgeAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "Microphone permission was denied."])
        }

        let effectiveMode = resolveEffectiveMode(requestedMode: mode)
        currentMode = effectiveMode
        currentRequestedMode = mode
        try configureSession(for: effectiveMode)
        try configureEngine(for: effectiveMode, requestedMode: mode)
        engine.prepare()
        try engine.start()
        diagnostics.engineRunning = engine.isRunning
        isRunning = true
        refreshRouteDiagnostics()
        publishDiagnostics()
    }

    func stop() {
        guard isRunning else { return }

        engine.stop()
        teardownCaptureGraph()
        processingQueue.sync {
            pendingSamples.removeAll(keepingCapacity: false)
        }

        isRunning = false
        currentMode = nil
        currentRequestedMode = nil
        diagnostics.engineRunning = false
        diagnostics.speechDetected = false
        diagnostics.rmsLevel = 0
        diagnostics.clipping = false
        publishDiagnostics()

        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            emitError("Audio session deactivate failed: \(error.localizedDescription)")
        }
    }

    private func resolveEffectiveMode(requestedMode: CaptureMode) -> CaptureMode {
        #if targetEnvironment(simulator)
        diagnostics.capturePath = "Simulator fallback"
        diagnostics.fallbackReason = "Simulator uses raw capture because Apple voice-processing behavior is device-only."
        return .rawDebug
        #else
        diagnostics.fallbackReason = ""
        if requestedMode == .voiceProcessing {
            diagnostics.capturePath = "Voice Processing"
        } else if requestedMode == .echoCancelled {
            diagnostics.capturePath = "Echo-Cancelled Input"
        } else {
            diagnostics.capturePath = "Raw Debug"
        }
        return requestedMode
        #endif
    }

    private func configureSession(for mode: CaptureMode) throws {
        let sessionMode: AVAudioSession.Mode
        switch mode {
        case .voiceProcessing:
            sessionMode = .voiceChat
        case .echoCancelled:
            sessionMode = .default
        case .rawDebug:
            sessionMode = .measurement
        }

        try session.setCategory(.playAndRecord, mode: sessionMode, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setPreferredSampleRate(48_000)
        try session.setPreferredIOBufferDuration(0.02)
        try? session.setPreferredInputNumberOfChannels(1)

        if #available(iOS 18.2, *) {
            diagnostics.echoCancelledInputAvailable = session.isEchoCancelledInputAvailable
            if mode == .echoCancelled, session.isEchoCancelledInputAvailable {
                try? session.setPrefersEchoCancelledInput(true)
            } else {
                try? session.setPrefersEchoCancelledInput(false)
            }
            diagnostics.echoCancelledInputEnabled = session.isEchoCancelledInputEnabled
        } else {
            diagnostics.echoCancelledInputAvailable = false
            diagnostics.echoCancelledInputEnabled = false
        }

        try session.setActive(true, options: [])
    }

    private func configureEngine(for mode: CaptureMode, requestedMode: CaptureMode) throws {
        engine.stop()
        engine.reset()
        teardownCaptureGraph()

        let inputNode = engine.inputNode
        _ = engine.outputNode
        _ = engine.mainMixerNode

        diagnostics.voiceProcessingRequested = requestedMode == .voiceProcessing

        if mode == .voiceProcessing {
            do {
                try inputNode.setVoiceProcessingEnabled(true)
                diagnostics.voiceProcessingEnabled = inputNode.isVoiceProcessingEnabled
            } catch {
                diagnostics.voiceProcessingEnabled = false
                diagnostics.capturePath = "Raw fallback"
                diagnostics.fallbackReason = "Voice processing could not be enabled on this route."
                emitError("Voice processing could not be enabled: \(error.localizedDescription)")
            }
        } else {
            if inputNode.isVoiceProcessingEnabled {
                try? inputNode.setVoiceProcessingEnabled(false)
            }
            diagnostics.voiceProcessingEnabled = false
            if requestedMode == .echoCancelled && !diagnostics.echoCancelledInputEnabled && diagnostics.fallbackReason.isEmpty {
                diagnostics.capturePath = "Raw fallback"
                diagnostics.fallbackReason = "Echo-cancelled input is unavailable on this route."
            }
        }

        let hardwareFormat = inputNode.outputFormat(forBus: 0)
        guard let targetFormat else {
            throw NSError(domain: "ChurchBridgeAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create 16 kHz target format."])
        }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "ChurchBridgeAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create mono processing format."])
        }

        hardwareInputFormat = hardwareFormat
        converter = AVAudioConverter(from: monoFormat, to: targetFormat)
        resetPendingSamples()

        diagnostics.inputSampleRate = hardwareFormat.sampleRate
        diagnostics.inputChannels = Int(hardwareFormat.channelCount)
        diagnostics.inputFormatDescription = describe(format: hardwareFormat)
        diagnostics.targetSampleRate = targetFormat.sampleRate
        diagnostics.voiceProcessingAGCEnabled = inputNode.isVoiceProcessingAGCEnabled
        diagnostics.batchesSent = 0
        diagnostics.lastBatchAt = nil
        diagnostics.lastSpeechAt = nil
        diagnostics.rmsLevel = 0
        diagnostics.noiseFloor = 0
        diagnostics.clipping = false
        diagnostics.speechDetected = false

        let tapBufferSize = max(AVAudioFrameCount((hardwareFormat.sampleRate * 0.02).rounded()), 256)
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            self?.captureBuffer(buffer)
        }
    }

    private func captureBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let copiedSamples = copyMonoSamples(from: buffer) else { return }
        processingQueue.async { [weak self] in
            self?.process(samples: copiedSamples)
        }
    }

    private func process(samples: [Float]) {
        guard
            let hardwareInputFormat,
            let converter,
            let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareInputFormat.sampleRate, channels: 1, interleaved: false),
            let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else {
            return
        }

        sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
        guard let destination = sourceBuffer.floatChannelData?[0] else { return }
        destination.update(from: samples, count: samples.count)

        guard let targetFormat else { return }
        let outputCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return }

        var conversionError: NSError?
        var usedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if usedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            usedInput = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let conversionError {
            emitError("Audio convert failed: \(conversionError.localizedDescription)")
            return
        }

        guard status != .error, let channelData = outputBuffer.floatChannelData?[0] else { return }
        let frameCount = Int(outputBuffer.frameLength)
        guard frameCount > 0 else { return }

        let convertedSamples = Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        updateLevels(from: convertedSamples)
        pendingSamples.append(contentsOf: convertedSamples)

        while pendingSamples.count >= chunkSamples {
            let chunk = Array(pendingSamples.prefix(chunkSamples))
            pendingSamples.removeFirst(chunkSamples)
            let base64 = chunk.withUnsafeBufferPointer { pointer in
                Data(buffer: pointer).base64EncodedString()
            }
            diagnostics.batchesSent += 1
            diagnostics.lastBatchAt = Date()
            publishDiagnostics()
            emitChunk(base64)
        }
    }

    private func copyMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return nil }

        let channelCount = Int(buffer.format.channelCount)
        var monoSamples = Array(repeating: Float.zero, count: frameCount)

        switch buffer.format.commonFormat {
        case .pcmFormatFloat32:
            guard let channelData = buffer.floatChannelData else { return nil }
            for channel in 0..<max(channelCount, 1) {
                let source = channelData[min(channel, channelCount - 1)]
                for frame in 0..<frameCount {
                    monoSamples[frame] += source[frame]
                }
            }
        case .pcmFormatInt16:
            guard let channelData = buffer.int16ChannelData else { return nil }
            for channel in 0..<max(channelCount, 1) {
                let source = channelData[min(channel, channelCount - 1)]
                for frame in 0..<frameCount {
                    monoSamples[frame] += Float(source[frame]) / Float(Int16.max)
                }
            }
        case .pcmFormatInt32:
            guard let channelData = buffer.int32ChannelData else { return nil }
            for channel in 0..<max(channelCount, 1) {
                let source = channelData[min(channel, channelCount - 1)]
                for frame in 0..<frameCount {
                    monoSamples[frame] += Float(source[frame]) / Float(Int32.max)
                }
            }
        case .pcmFormatFloat64:
            guard let audioBuffer = buffer.audioBufferList.pointee.mBuffers.mData else { return nil }
            let source = audioBuffer.assumingMemoryBound(to: Double.self)
            for frame in 0..<frameCount {
                monoSamples[frame] = Float(source[frame])
            }
        default:
            return nil
        }

        let divisor = Float(max(channelCount, 1))
        if divisor > 1 {
            for frame in 0..<frameCount {
                monoSamples[frame] /= divisor
            }
        }
        return monoSamples
    }

    private func teardownCaptureGraph() {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        converter = nil
        hardwareInputFormat = nil
    }

    private func updateLevels(from samples: [Float]) {
        guard !samples.isEmpty else { return }

        let peak = samples.reduce(Float.zero) { max($0, abs($1)) }
        let rms = sqrt(samples.reduce(Float.zero) { $0 + ($1 * $1) } / Float(samples.count))
        let nextNoiseFloor: Float
        if diagnostics.noiseFloor == 0 {
            nextNoiseFloor = rms
        } else if rms < diagnostics.noiseFloor {
            nextNoiseFloor = diagnostics.noiseFloor * 0.8 + rms * 0.2
        } else {
            nextNoiseFloor = diagnostics.noiseFloor * 0.98 + rms * 0.02
        }

        let threshold = max(nextNoiseFloor * 2.5, 0.015)
        let speechDetected = rms >= threshold
        diagnostics.rmsLevel = rms
        diagnostics.noiseFloor = nextNoiseFloor
        diagnostics.clipping = peak >= 0.98
        diagnostics.speechDetected = speechDetected
        if speechDetected {
            diagnostics.lastSpeechAt = Date()
        }
        publishDiagnostics()
    }

    private func describe(format: AVAudioFormat) -> String {
        let commonFormat: String
        switch format.commonFormat {
        case .pcmFormatFloat32:
            commonFormat = "Float32"
        case .pcmFormatFloat64:
            commonFormat = "Float64"
        case .pcmFormatInt16:
            commonFormat = "Int16"
        case .pcmFormatInt32:
            commonFormat = "Int32"
        case .otherFormat:
            commonFormat = "Other"
        @unknown default:
            commonFormat = "Unknown"
        }
        let layout = format.isInterleaved ? "interleaved" : "non-interleaved"
        return "\(commonFormat) | \(Int(format.channelCount)) ch | \(layout)"
    }

    private func refreshRouteDiagnostics() {
        let route = session.currentRoute
        diagnostics.routeInputs = route.inputs.map { "\($0.portType.rawValue) | \($0.portName)" }
        diagnostics.routeOutputs = route.outputs.map { "\($0.portType.rawValue) | \($0.portName)" }
        diagnostics.routeName = diagnostics.routeInputs.joined(separator: ", ")
        if diagnostics.routeName.isEmpty {
            diagnostics.routeName = "No active input route"
        }
        diagnostics.inputSampleRate = session.sampleRate
    }

    private func publishDiagnostics() {
        let snapshot = diagnostics
        DispatchQueue.main.async { [weak self] in
            self?.diagnosticsDidChange?(snapshot)
        }
    }

    private func emitError(_ message: String) {
        DispatchQueue.main.async { [weak self] in
            self?.errorHandler?(message)
        }
    }

    private func emitChunk(_ base64: String) {
        DispatchQueue.main.async { [weak self] in
            self?.audioChunkHandler?(base64)
        }
    }

    @objc
    private func handleRouteChange(_ notification: Notification) {
        refreshRouteDiagnostics()
        publishDiagnostics()
        if isRunning {
            reconfigureCaptureGraph(reason: "audio route change")
        }
    }

    @objc
    private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue)
        else {
            return
        }

        if type == .ended, isRunning {
            reconfigureCaptureGraph(reason: "audio interruption ended")
        }
    }

    @objc
    private func handleEngineConfigurationChange(_ notification: Notification) {
        if isRunning {
            refreshRouteDiagnostics()
            publishDiagnostics()
            reconfigureCaptureGraph(reason: "engine configuration change")
        }
    }

    private func reconfigureCaptureGraph(reason: String) {
        guard isRunning, !isReconfiguring else { return }
        guard let mode = currentMode, let requestedMode = currentRequestedMode else { return }

        isReconfiguring = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            defer { self.isReconfiguring = false }

            do {
                try self.configureSession(for: mode)
                try self.configureEngine(for: mode, requestedMode: requestedMode)
                self.engine.prepare()
                try self.engine.start()
                self.diagnostics.engineRunning = self.engine.isRunning
                self.refreshRouteDiagnostics()
                self.publishDiagnostics()
            } catch {
                self.emitError("Audio capture reconfiguration failed after \(reason): \(error.localizedDescription)")
            }
        }
    }

    private func resetPendingSamples() {
        let clear = { self.pendingSamples.removeAll(keepingCapacity: false) }
        if DispatchQueue.getSpecific(key: processingQueueKey) != nil {
            clear()
        } else {
            processingQueue.sync(execute: clear)
        }
    }
}
