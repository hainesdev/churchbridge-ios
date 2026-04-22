@preconcurrency import AVFAudio
import Foundation

final class AudioCaptureManager: NSObject {
    var diagnosticsDidChange: ((AudioDiagnostics) -> Void)?
    var errorHandler: ((String) -> Void)?
    var audioChunkHandler: ((AudioChunkEnvelope) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(label: "ChurchBridgeTranslation.audio-processing", qos: .userInitiated)
    private let processingQueueKey = DispatchSpecificKey<UInt8>()
    private var hardwareInputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var diagnostics = AudioDiagnostics()
    private var pendingSamples: [Float] = []
    private var isRunning = false
    private var currentMode: CaptureMode?
    private var currentRequestedMode: CaptureMode?
    private var currentStrategy: AudioCaptureStrategy = .appleVoicePassthrough
    private var isReconfiguring = false
    private var lastReconfigureAt: Date?

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

    func start(mode: CaptureMode, strategy: AudioCaptureStrategy) async throws {
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
        currentStrategy = strategy
        resetStageDiagnostics()
        diagnostics.captureStrategy = strategy.rawValue
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
        currentStrategy = .appleVoicePassthrough
        lastReconfigureAt = nil
        diagnostics.engineRunning = false
        diagnostics.speechDetected = false
        diagnostics.rmsLevel = 0
        diagnostics.clipping = false
        diagnostics.pendingSampleCount = 0
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
        let outputSampleRate = currentStrategy == .appleVoicePassthrough ? hardwareFormat.sampleRate : 16_000
        guard let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputSampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "ChurchBridgeAudio", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unable to create output processing format."])
        }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "ChurchBridgeAudio", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unable to create mono processing format."])
        }

        hardwareInputFormat = hardwareFormat
        self.targetFormat = targetFormat
        converter = currentStrategy == .persistentConverter ? makeConverter(from: monoFormat, to: targetFormat) : nil
        resetPendingSamples()

        diagnostics.inputSampleRate = hardwareFormat.sampleRate
        diagnostics.inputChannels = Int(hardwareFormat.channelCount)
        diagnostics.inputFormatDescription = describe(format: hardwareFormat)
        diagnostics.targetSampleRate = targetFormat.sampleRate
        diagnostics.emittedSampleRate = outputSampleRate
        diagnostics.chunkSampleCount = chunkSampleCount(for: outputSampleRate)
        diagnostics.voiceProcessingAGCEnabled = inputNode.isVoiceProcessingAGCEnabled
        diagnostics.batchesSent = 0
        diagnostics.lastBatchAt = nil
        diagnostics.lastSpeechAt = nil
        diagnostics.rmsLevel = 0
        diagnostics.noiseFloor = 0
        diagnostics.clipping = false
        diagnostics.speechDetected = false
        diagnostics.pendingSampleCount = 0

        let tapBufferSize = max(AVAudioFrameCount((hardwareFormat.sampleRate * 0.02).rounded()), 256)
        inputNode.installTap(onBus: 0, bufferSize: tapBufferSize, format: hardwareFormat) { [weak self] buffer, _ in
            self?.captureBuffer(buffer)
        }
    }

    private func captureBuffer(_ buffer: AVAudioPCMBuffer) {
        diagnostics.tapCallbackCount += 1
        diagnostics.tapFrameCount += Int(buffer.frameLength)
        diagnostics.lastTapAt = Date()
        guard let copiedSamples = copyMonoSamples(from: buffer) else {
            diagnostics.copyMonoFailureCount += 1
            publishDiagnostics()
            return
        }
        diagnostics.copyMonoSuccessCount += 1
        processingQueue.async { [weak self] in
            self?.process(samples: copiedSamples)
        }
    }

    private func process(samples: [Float]) {
        diagnostics.processingInvocationCount += 1

        let outputSamples: [Float]
        if currentStrategy == .appleVoicePassthrough {
            outputSamples = samples
        } else {
            guard
                let hardwareInputFormat,
                let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareInputFormat.sampleRate, channels: 1, interleaved: false),
                let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
            else {
                return
            }

            sourceBuffer.frameLength = AVAudioFrameCount(samples.count)
            guard let destination = sourceBuffer.floatChannelData?[0] else { return }
            destination.update(from: samples, count: samples.count)

            guard let converted = convertBuffer(sourceBuffer, sourceFormat: sourceFormat) else { return }
            outputSamples = converted
        }

        guard !outputSamples.isEmpty else { return }
        updateLevels(from: outputSamples)
        pendingSamples.append(contentsOf: outputSamples)
        diagnostics.pendingSampleCount = pendingSamples.count
        diagnostics.pendingSampleHighWaterMark = max(diagnostics.pendingSampleHighWaterMark, pendingSamples.count)

        let chunkSamples = chunkSampleCount(for: diagnostics.emittedSampleRate)
        while pendingSamples.count >= chunkSamples {
            let chunk = Array(pendingSamples.prefix(chunkSamples))
            pendingSamples.removeFirst(chunkSamples)
            diagnostics.pendingSampleCount = pendingSamples.count
            let base64 = chunk.withUnsafeBufferPointer { pointer in
                Data(buffer: pointer).base64EncodedString()
            }
            diagnostics.batchesSent += 1
            diagnostics.lastBatchAt = Date()
            publishDiagnostics()
            emitChunk(base64, sampleRate: Int(diagnostics.emittedSampleRate.rounded()))
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

    private func convertBuffer(_ sourceBuffer: AVAudioPCMBuffer, sourceFormat: AVAudioFormat) -> [Float]? {
        guard let targetFormat else { return nil }
        let outputCapacity = AVAudioFrameCount((Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate).rounded(.up)) + 64
        guard outputCapacity > 0 else { return nil }

        let activeConverter: AVAudioConverter?
        switch currentStrategy {
        case .persistentConverter:
            activeConverter = converter
        case .ephemeralConverter:
            activeConverter = makeConverter(from: sourceFormat, to: targetFormat)
        case .appleVoicePassthrough:
            activeConverter = nil
        }

        guard let activeConverter else { return nil }
        var outputSamples: [Float] = []
        var conversionError: NSError?
        var inputProvided = false

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return nil }
            let status = activeConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                if inputProvided {
                    outStatus.pointee = self.currentStrategy == .persistentConverter ? .noDataNow : .endOfStream
                    return nil
                }
                inputProvided = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if let conversionError {
                diagnostics.conversionFailureCount += 1
                emitError("Audio convert failed: \(conversionError.localizedDescription)")
                publishDiagnostics()
                return nil
            }

            let frameCount = Int(outputBuffer.frameLength)
            if frameCount > 0, let channelData = outputBuffer.floatChannelData?[0] {
                diagnostics.conversionSuccessCount += 1
                diagnostics.convertedFrameCount += frameCount
                diagnostics.lastConvertedAt = Date()
                outputSamples.append(contentsOf: UnsafeBufferPointer(start: channelData, count: frameCount))
            }

            switch status {
            case .haveData:
                if frameCount == 0 {
                    diagnostics.zeroFrameConversionCount += 1
                    publishDiagnostics()
                    return outputSamples.isEmpty ? nil : outputSamples
                }
                continue
            case .inputRanDry, .endOfStream:
                if frameCount == 0 {
                    diagnostics.zeroFrameConversionCount += 1
                }
                publishDiagnostics()
                return outputSamples.isEmpty ? nil : outputSamples
            case .error:
                diagnostics.conversionFailureCount += 1
                publishDiagnostics()
                return nil
            @unknown default:
                publishDiagnostics()
                return outputSamples.isEmpty ? nil : outputSamples
            }
        }
    }

    private func makeConverter(from sourceFormat: AVAudioFormat, to targetFormat: AVAudioFormat) -> AVAudioConverter? {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return nil
        }
        converter.primeMethod = .none
        converter.downmix = false
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        return converter
    }

    private func teardownCaptureGraph() {
        let inputNode = engine.inputNode
        inputNode.removeTap(onBus: 0)
        converter = nil
        hardwareInputFormat = nil
        targetFormat = nil
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

    private func emitChunk(_ base64: String, sampleRate: Int) {
        DispatchQueue.main.async { [weak self] in
            self?.audioChunkHandler?(AudioChunkEnvelope(base64: base64, sampleRate: sampleRate))
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

    private func reconfigureCaptureGraph(reason: String, completion: ((Bool) -> Void)? = nil) {
        guard isRunning, !isReconfiguring else { return }
        guard let mode = currentMode, let requestedMode = currentRequestedMode else { return }
        if let lastReconfigureAt, Date().timeIntervalSince(lastReconfigureAt) < 0.75 {
            completion?(false)
            return
        }

        diagnostics.captureRestartCount += 1
        diagnostics.lastRestartAt = Date()
        diagnostics.lastRestartReason = reason
        lastReconfigureAt = diagnostics.lastRestartAt
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
                completion?(true)
            } catch {
                self.emitError("Audio capture reconfiguration failed after \(reason): \(error.localizedDescription)")
                completion?(false)
            }
        }
    }

    func forceDiagnosticRebuild(reason: String = "diagnostics probe") async -> Bool {
        guard isRunning, !isReconfiguring, currentMode != nil, currentRequestedMode != nil else { return false }
        return await withCheckedContinuation { continuation in
            reconfigureCaptureGraph(reason: reason) { success in
                continuation.resume(returning: success)
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
        diagnostics.pendingSampleCount = 0
    }

    private func resetStageDiagnostics() {
        diagnostics.tapCallbackCount = 0
        diagnostics.tapFrameCount = 0
        diagnostics.lastTapAt = nil
        diagnostics.copyMonoSuccessCount = 0
        diagnostics.copyMonoFailureCount = 0
        diagnostics.processingInvocationCount = 0
        diagnostics.conversionSuccessCount = 0
        diagnostics.conversionFailureCount = 0
        diagnostics.zeroFrameConversionCount = 0
        diagnostics.convertedFrameCount = 0
        diagnostics.lastConvertedAt = nil
        diagnostics.pendingSampleCount = 0
        diagnostics.pendingSampleHighWaterMark = 0
        diagnostics.captureRestartCount = 0
        diagnostics.lastRestartAt = nil
        diagnostics.lastRestartReason = ""
        diagnostics.captureStrategy = currentStrategy.rawValue
        diagnostics.emittedSampleRate = Double(currentStrategy.targetSampleRate)
        diagnostics.chunkSampleCount = chunkSampleCount(for: diagnostics.emittedSampleRate)
    }

    private func chunkSampleCount(for sampleRate: Double) -> Int {
        max(Int((sampleRate * 0.1).rounded()), 256)
    }
}
