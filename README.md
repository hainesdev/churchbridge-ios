# Church Bridge Translation Test iPhone App

Native SwiftUI iPhone app for the Church Bridge `Translation Test` flow.

Highlights:

- Native `AVAudioSession` + `AVAudioEngine` microphone capture
- Voice-processing-first audio path with capability-checked echo-cancelled fallback
- Existing websocket contracts preserved for `/api/stream/v1` and `/api/display/v1`
- Live diagnostics for route, sample rate, clipping, speech activity, reconnect state, and voice-processing status

Open `ChurchBridgeTranslation.xcodeproj` in Xcode on the macOS VM at `~/MacVmShared/churchbridge-ios`.

Development notes:

- See [IOS_AUDIO_NOTES.md](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/IOS_AUDIO_NOTES.md) for native voice-capture findings, sample-code references, redesign notes, and next steps.
- See [IOS_DEVELOPMENT_NOTES.md](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/IOS_DEVELOPMENT_NOTES.md) for VM workflow, signing, Xcode Cloud, App Store Connect, and TestFlight findings from the first deployment cycle.
