import Foundation

enum CaptureMode: String, CaseIterable, Identifiable, Codable {
    case voiceProcessing = "Voice Processing"
    case echoCancelled = "Echo-Cancelled Input"
    case rawDebug = "Raw Debug"

    var id: String { rawValue }

    var sessionModeDescription: String {
        switch self {
        case .voiceProcessing:
            return "AVAudioEngine voice processing on the I/O path"
        case .echoCancelled:
            return "Default mode plus capability-checked echo-cancelled input"
        case .rawDebug:
            return "Minimal processing for A/B comparison"
        }
    }
}

enum AudioCaptureStrategy: String, CaseIterable, Identifiable, Codable {
    case appleVoicePassthrough = "Apple Voice Passthrough"
    case persistentConverter = "Persistent Converter"
    case ephemeralConverter = "Ephemeral Converter"

    var id: String { rawValue }

    static let liveDefault: AudioCaptureStrategy = .appleVoicePassthrough

    var summary: String {
        switch self {
        case .appleVoicePassthrough:
            return "Capture the voice-processing input format directly and let the server resample."
        case .persistentConverter:
            return "Keep one AVAudioConverter alive across callbacks and drain it like a stream."
        case .ephemeralConverter:
            return "Build a fresh AVAudioConverter for each tap buffer to avoid sticky converter state."
        }
    }

    var targetSampleRate: Int {
        switch self {
        case .appleVoicePassthrough:
            return 48_000
        case .persistentConverter, .ephemeralConverter:
            return 16_000
        }
    }

    var isDiagnosticsOnly: Bool {
        self != .appleVoicePassthrough
    }
}

enum StreamStatus: String {
    case idle
    case connecting
    case connected
    case reconnecting
    case failed
}

struct BibleVersionOption: Identifiable, Codable, Hashable {
    let slug: String
    let name: String
    let languageCode: String

    var id: String { slug }

    enum CodingKeys: String, CodingKey {
        case slug
        case name
        case languageCode = "language_code"
    }
}

struct ScripturePassageVerse: Codable, Hashable {
    let verse: Int
    let text: String
    let reference: String
}

struct ScripturePassageVersion: Codable, Hashable {
    let slug: String
    let name: String
}

struct ScripturePassage: Codable, Hashable {
    let version: ScripturePassageVersion
    let book: String
    let chapter: Int
    let verseStart: Int
    let verseEnd: Int?
    let reference: String
    let verses: [ScripturePassageVerse]

    enum CodingKeys: String, CodingKey {
        case version
        case book
        case chapter
        case verseStart = "verse_start"
        case verseEnd = "verse_end"
        case reference
        case verses
    }
}

struct VerseDetection: Codable, Hashable {
    let book: String
    let chapter: Int
    let verseStart: Int
    let verseEnd: Int?
    let spanishText: String
    let canonicalEnglish: String
    let reference: String
    let confidence: String
    let explanation: String?
    let sourceVersionSlug: String?
    let displayVersionSlug: String?
    let sourcePassage: ScripturePassage?
    let displayPassage: ScripturePassage?

    enum CodingKeys: String, CodingKey {
        case book
        case chapter
        case verseStart = "verse_start"
        case verseEnd = "verse_end"
        case spanishText = "spanish_text"
        case canonicalEnglish = "canonical_english"
        case reference
        case confidence
        case explanation
        case sourceVersionSlug = "source_version_slug"
        case displayVersionSlug = "display_version_slug"
        case sourcePassage = "source_passage"
        case displayPassage = "display_passage"
    }
}

struct VerseSuggestion: Codable, Hashable {
    let reference: String
    let canonicalEnglish: String
    let relevanceNote: String
    let explanation: String?
    let sourceVersionSlug: String?
    let displayVersionSlug: String?
    let sourcePassage: ScripturePassage?
    let displayPassage: ScripturePassage?

    enum CodingKeys: String, CodingKey {
        case reference
        case canonicalEnglish = "canonical_english"
        case relevanceNote = "relevance_note"
        case explanation
        case sourceVersionSlug = "source_version_slug"
        case displayVersionSlug = "display_version_slug"
        case sourcePassage = "source_passage"
        case displayPassage = "display_passage"
    }
}

struct TranslationSegment: Identifiable, Equatable {
    let id: Int
    var spanish: String
    var english: String
    var verseDetected: VerseDetection?
    var verseSuggestions: [VerseSuggestion] = []
    var pendingCompletion = false
    var terminalIncomplete = false
}

struct DisplayFeedSnapshot {
    var segments: [TranslationSegment] = []
    var spanishLines: [String] = []
    var partialSpanish = ""
    var partialEnglish = ""
    var flashingID: Int?
    var connected = false
    var sermonMode = "exposition"
    var lastInterimAt: Date?
    var lastFinalAt: Date?
    var lastTranslationAt: Date?
    var lastInterimSpanish = ""
    var lastFinalSpanish = ""
    var lastCommittedEnglish = ""
    var lastVisibleSegmentID: Int?
}

struct AudioDiagnostics {
    var routeName = "Unknown route"
    var routeInputs: [String] = []
    var routeOutputs: [String] = []
    var capturePath = "Not configured"
    var fallbackReason = ""
    var inputSampleRate: Double = 0
    var targetSampleRate: Double = 16_000
    var inputChannels = 0
    var inputFormatDescription = ""
    var clipping = false
    var speechDetected = false
    var lastSpeechAt: Date?
    var rmsLevel: Float = 0
    var noiseFloor: Float = 0
    var batchesSent = 0
    var lastBatchAt: Date?
    var voiceProcessingRequested = false
    var voiceProcessingEnabled = false
    var voiceProcessingAGCEnabled = false
    var echoCancelledInputAvailable = false
    var echoCancelledInputEnabled = false
    var microphonePermissionGranted = false
    var engineRunning = false
    var tapCallbackCount = 0
    var tapFrameCount = 0
    var lastTapAt: Date?
    var copyMonoSuccessCount = 0
    var copyMonoFailureCount = 0
    var processingInvocationCount = 0
    var conversionSuccessCount = 0
    var conversionFailureCount = 0
    var zeroFrameConversionCount = 0
    var convertedFrameCount = 0
    var lastConvertedAt: Date?
    var pendingSampleCount = 0
    var pendingSampleHighWaterMark = 0
    var captureRestartCount = 0
    var lastRestartAt: Date?
    var lastRestartReason = ""
    var captureStrategy = AudioCaptureStrategy.appleVoicePassthrough.rawValue
    var emittedSampleRate: Double = 16_000
    var chunkSampleCount = 1_600
}

struct AudioChunkEnvelope: Sendable {
    let base64: String
    let sampleRate: Int
}

struct StreamStartPayload: Encodable {
    let type = "session.start"
    let sampleRate: Int
    let topic: String
    let sourceScriptureVersion: String
    let displayScriptureVersion: String
}

struct StreamStopPayload: Encodable {
    let type = "session.stop"
}

struct StreamAudioPayload: Encodable {
    let type = "audio"
    let audio: String
}

struct StreamSessionStartedEvent: Decodable {
    let type: String
    let sessionId: Int?
    let sourceScriptureVersion: String?
    let displayScriptureVersion: String?
}

struct ErrorEvent: Decodable {
    let type: String
    let message: String
}
