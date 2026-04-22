# iOS Audio Notes

This note captures the current understanding of the Church Bridge iPhone app's native audio stack, the relevant Apple guidance, the experiments attempted so far, and the recommended next steps for future development.

## Scope

These notes are specifically about the native iPhone implementation of the Church Bridge `Translation Test` flow in:

- [churchbridge-ios](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios)

Relevant app files:

- [AudioCaptureManager.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/AudioCaptureManager.swift)
- [TranslationTestViewModel.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/TranslationTestViewModel.swift)
- [TranslationTestView.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/TranslationTestView.swift)
- [SettingsStore.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/SettingsStore.swift)
- [Models.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/Models.swift)

Backend contract references from the existing web app and server:

- `client/components/MobileTest.tsx`
- `client/lib/useTranslationFeed.ts`
- `server/routes/stream.py`
- `server/routes/display.py`
- `server/services/audio_utils.py`
- `server/services/deepgram_session.py`

## Backend Contract Findings

The iOS app must preserve the current websocket contracts:

- `/api/stream/v1`
- `/api/display/v1`

Important details discovered from the server code:

- The stream pipeline still expects base64-encoded `Float32` audio payloads from the client.
- The server converts those samples to PCM16 internally.
- The stream start message includes:
  - `sampleRate`
  - `topic`
  - `sourceScriptureVersion`
  - `displayScriptureVersion`
- The display feed includes richer event types than a simple final transcript stream, including:
  - `interim`
  - `stt_final`
  - `interim_translation`
  - `translation`
  - `translation_update`
  - `correction`
  - `caption_merge`
  - `segment_metadata`
  - `mode_change`
  - `verse_detected`
  - `verse_range_update`
  - `verse_suggestion`

This means the audio redesign should not change the network contract. The native app should continue to send `16 kHz` mono `Float32` chunks encoded as base64.

## Server Configuration

The app default server was updated to:

- `https://churchbridge.dhaines.dev/`

That default is currently set in:

- [SettingsStore.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/SettingsStore.swift)

## Apple Guidance Found

Primary Apple references:

- `Using Voice Processing`
  - https://developer.apple.com/documentation/avfaudio/using-voice-processing
- `What’s New in AVAudioEngine` WWDC19
  - https://developer.apple.com/videos/play/wwdc2019/510/
- `What’s new in voice processing` WWDC23
  - https://developer.apple.com/videos/play/wwdc2023/10235/
- `AVAudioInputNode`
  - https://developer.apple.com/documentation/avfaudio/avaudioinputnode
- `AVAudioSession.Mode.voiceChat`
  - https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat
- `AVAudioApplication.requestRecordPermission()`
  - https://developer.apple.com/documentation/avfaudio/avaudioapplication/requestrecordpermission%28completionhandler%3A%29

Key takeaways from Apple:

- For VoIP-like speech capture, use `AVAudioSession` with `.playAndRecord`.
- For native speech cleanup, prefer `.voiceChat` plus `AVAudioEngine` voice processing.
- Enable voice processing with `setVoiceProcessingEnabled(true)` on the engine I/O path.
- Voice processing is only meaningful when rendering to an audio device.
- Voice processing cannot be enabled dynamically while the engine is already running.
- On the input chain, the hardware format is authoritative. Apple explicitly says input-node format conversion is not supported when rendering from a real device.
- `AVAudioInputNode` exposes useful diagnostics and controls:
  - `isVoiceProcessingEnabled`
  - `isVoiceProcessingAGCEnabled`
  - `isVoiceProcessingBypassed`
  - muted speech activity listener APIs
- `AVAudioSinkNode` is intended for real-time input-chain processing, but it has strict graph and format constraints.

## Relevant Sample Code Retrieved

### Apple Current Sample

Official current Apple sample:

- `Using Voice Processing`
  - Download URL:
    - https://docs-assets.developer.apple.com/published/8599a413511b/UsingVoiceProcessing.zip

Extracted locally to:

- [tmp_UsingVoiceProcessing](C:/Users/Dan/Desktop/Projects/churchbridge-ai/tmp_UsingVoiceProcessing)

Most relevant files:

- [AudioEngine.swift](C:/Users/Dan/Desktop/Projects/churchbridge-ai/tmp_UsingVoiceProcessing/AVEchoTouch/AudioEngine.swift)
- [ViewController.swift](C:/Users/Dan/Desktop/Projects/churchbridge-ai/tmp_UsingVoiceProcessing/AVEchoTouch/ViewController.swift)

Important observation:

- Apple’s current sample enables voice processing on the input node and uses `input.installTap(...)`.
- The sample does not use the sink-node approach for its basic voice-processing capture flow.

### Apple Archived Low-Level Sample

Older Apple sample:

- `echoTouch - Using the Voice Processing I/O audio unit`
  - Download URL:
    - https://developer.apple.com/library/archive/samplecode/echoTouch/echoTouch-UsingtheVoiceProcessingIOaudiounit.zip

Extracted locally to:

- [tmp_echoTouch](C:/Users/Dan/Desktop/Projects/churchbridge-ai/tmp_echoTouch)

This sample is older and based on the lower-level Voice Processing I/O audio unit, but it is still useful if the app ever needs to abandon `AVAudioEngine` and use the lower-level audio unit directly.

### Public GitHub References

#### Picovoice iOS Voice Processor

- Repo:
  - https://github.com/Picovoice/ios-voice-processor
- Key file:
  - https://github.com/Picovoice/ios-voice-processor/blob/main/src/ios_voice_processor/VoiceProcessor.swift

Why it matters:

- Clean real-time microphone capture implementation.
- Good reference for interruption handling and fixed-size frame delivery.
- Uses `AudioQueue`, not `AVAudioEngine`, so it is not the direct Church Bridge architecture, but it is useful for understanding robust capture patterns.

#### expo-speech-recognition

- Repo:
  - https://github.com/jamsch/expo-speech-recognition
- Key file:
  - https://github.com/jamsch/expo-speech-recognition/blob/main/ios/ExpoSpeechRecognizer.swift

Why it matters:

- Modern Swift implementation using `AVAudioEngine`.
- Uses mixer-plus-tap capture.
- Includes route-change recovery.
- Includes downsampling for persisted audio.
- Includes optional voice processing via:
  - `inputNode.setVoiceProcessingEnabled(true)`
  - `outputNode.setVoiceProcessingEnabled(true)`

#### AVDemo Mirror

- Repo:
  - https://github.com/ElfSundae/AVDemo

Why it matters:

- Useful index of older Apple audio/video samples.
- Good reference for general `AVAudioEngine` graph patterns.

## Experiments Attempted

### 1. Initial Native Capture Path

The first native app implementation used:

- `AVAudioSession`
- `AVAudioEngine`
- direct input capture
- resampling to `16 kHz` mono `Float32`
- websocket streaming to the existing backend contract

This established the basic app structure and backend compatibility.

### 2. Server Default Fix

The app originally defaulted to localhost and was updated to:

- `https://churchbridge.dhaines.dev/`

This was necessary so the simulator app would connect to the actual backend by default.

### 3. First Crash: Install Tap on Voice-Processing I/O

The first `Start Test` crash happened while installing a tap on the audio node with voice processing enabled.

Crash signature:

- `EXC_CRASH / SIGABRT`
- stack included `installTapOnBus` and `CreateRecordingTap`

Interpretation:

- The initial tap-based graph shape was not accepted by the underlying voice-processing path in that configuration.

### 4. Sink-Node Experiment

Because Apple notes that `AVAudioSinkNode` is useful for real-time VoIP-style input, a sink-node-based redesign was attempted.

What changed:

- Replaced the input tap with `AVAudioSinkNode`
- Copied audio from the sink callback
- Moved conversion and chunking off the callback

What happened:

- This compiled after some API fixes.
- It then crashed at runtime when connecting the input node to the sink node.

Crash signature:

- `EXC_CRASH / SIGABRT`
- crash inside `-[AVAudioEngine connect:to:format:]`
- faulting line was the `engine.connect(inputNode, to: sinkNode, format: hardwareFormat)` call

Interpretation:

- The sink-node graph shape was still not accepted by the engine in the tested simulator configuration.
- This may be a graph topology issue, a format issue, or a simulator limitation.

### 5. Current Redesign

The audio path was redesigned again around Apple’s current sample structure.

Current shape in [AudioCaptureManager.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/AudioCaptureManager.swift):

- `AVAudioSession(.playAndRecord)`
- `.voiceChat` for the preferred voice-processing mode
- `inputNode.setVoiceProcessingEnabled(true)` for the preferred path
- direct `inputNode.installTap(...)`
- immediate sample copy from the tap
- resampling and chunking on a dedicated processing queue
- diagnostics surfaced in the UI

The current design also adds an explicit simulator fallback:

- On simulator, capture falls back to raw mode
- This is surfaced in diagnostics as a fallback reason

This avoids pretending that simulator behavior is a trustworthy substitute for real-device voice processing.

## Current Design Principles

The current implementation should continue to follow these rules:

1. Prefer Apple voice processing on real iPhone hardware.
2. Keep the render callback light.
3. Copy microphone data immediately.
4. Do resampling and websocket chunking off the callback.
5. Preserve the backend websocket contract.
6. Expose diagnostics that say what path is actually active.
7. Treat simulator results as functional-only, not quality validation.

## Current Diagnostics

The app now exposes or tracks:

- route name
- route inputs
- route outputs
- capture path
- fallback reason
- input sample rate
- target sample rate
- input channel count
- input format description
- clipping
- speech activity
- RMS level
- noise floor
- chunk count
- last batch time
- voice processing requested
- voice processing enabled
- voice processing AGC enabled
- echo-cancelled input availability
- echo-cancelled input enabled
- microphone permission state
- engine running state

These are defined in:

- [Models.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/Models.swift)

And shown in:

- [TranslationTestView.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/TranslationTestView.swift)

## Current Known Limitations

### 1. Simulator Is Not a Final Audio Validation Target

The simulator has already behaved differently from the intended device path.

The simulator is useful for:

- build validation
- UI flow validation
- settings and diagnostics validation

The simulator is not sufficient for:

- final voice-processing quality evaluation
- echo-cancellation validation
- AGC behavior validation
- microphone isolation comparisons

### 2. Physical Device Validation Is Still Required

The final acceptance criteria for “voice capture is actually better than the browser path” still requires a physical iPhone test.

### 3. The Current Tap-Based Voice-Processing Path Must Still Be Manually Exercised

After the redesign, the app builds successfully, but a human still needs to:

- launch the app
- tap `Start Test`
- confirm no crash
- verify diagnostics
- verify websocket streaming works end to end

## Recommended Next Steps

1. Manually run `Start Test` on the simulator just to confirm the raw fallback no longer crashes.
2. Run on a physical iPhone and verify:
   - no crash
   - `voice processing enabled` is actually true
   - route and format diagnostics are correct
   - chunks are flowing to `/api/stream/v1`
   - translations arrive from `/api/display/v1`
3. Test all capture modes on device:
   - `Voice Processing`
   - `Echo-Cancelled Input`
   - `Raw Debug`
4. Compare real sermon-room speech capture against the existing web app.
5. If `AVAudioEngine` still proves too fragile on device, consider a lower-level fallback implementation based on the Voice Processing I/O audio unit, using Apple’s archived `echoTouch` sample as the reference.

## Practical Recommendation

For future work, the default strategy should be:

- use Apple’s current `Using Voice Processing` sample as the baseline architecture
- keep the backend protocol unchanged
- keep the simulator on a safe fallback path
- use real iPhone hardware for any final audio-quality decisions

## Files Generated During Research

These local research artifacts exist in the workspace:

- [tmp_UsingVoiceProcessing](C:/Users/Dan/Desktop/Projects/churchbridge-ai/tmp_UsingVoiceProcessing)
- [tmp_echoTouch](C:/Users/Dan/Desktop/Projects/churchbridge-ai/tmp_echoTouch)
- `tmp_UsingVoiceProcessing.zip`
- `tmp_echoTouch.zip`

These are reference materials and not part of the app itself.
