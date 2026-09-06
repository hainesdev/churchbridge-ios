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

## Acknowledgments

The on-device noise suppression is **DeepFilterNet3** by Hendrik Schröter,
Tobias Rosenkranz, Alberto N. Escalante-B., and Andreas Maier. The architecture
and the trained model are theirs; this app reimplements the streaming signal
chain in Swift against Accelerate so it runs on an iPhone.

> Schröter, H., Rosenkranz, T., Escalante-B., A. N., and Maier, A.
> "DeepFilterNet: Perceptually Motivated Real-Time Speech Enhancement."
> INTERSPEECH, 2023.

The Core ML build of that model is
[aufklarer's INT8 conversion](https://huggingface.co/aufklarer/DeepFilterNet3-CoreML) —
without it there would be no on-device path at all. The `.npz` auxiliary-data
loading is derived from
[soniqo/speech-swift](https://github.com/soniqo/speech-swift), and the capture
graph follows Apple's `Using Voice Processing` sample, which is what the design
was rebuilt around after two earlier attempts crashed.

Scripture text comes from
[dscottpi/bibles](https://github.com/dscottpi/bibles).

Full license terms are in [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md).
