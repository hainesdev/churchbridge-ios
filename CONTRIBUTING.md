# Contributing to the ChurchBridge iPhone app

Thanks for your interest. This covers the native iOS app — audio capture,
on-device noise suppression, the live caption view, and the scripture reader.

## What is most useful

**Field reports from real rooms.** Capture behaviour is the whole point of this
app, and it cannot be evaluated from a desk. If you have run it in a service:
what the room was like, where the phone sat, which capture path was active, what
the diagnostics showed when things degraded. That is worth more than most code.

**Device-specific findings.** Different iPhone models, iOS versions, audio
routes, and accessories behave differently. A reproducible report tied to a
specific device and route is genuinely useful.

**Issues and questions** are welcome in the tracker.

## The simulator is not a validation target

This is the rule most likely to trip you up. The simulator is fine for build
validation, UI flow, and settings work. It is **not** valid for judging audio
quality, echo cancellation, automatic gain behaviour, or microphone isolation —
it has already behaved differently from real hardware, and the app deliberately
falls back to a different capture path there and reports that it did so.

Any claim about capture quality needs a physical device in a real room.

## Code contributions and the CLA

ChurchBridge is deliberately kept under **single copyright ownership**. That is
what makes it possible to publish the source under a noncommercial license while
still licensing it commercially, and what keeps the project cleanly
transferable.

Accepted code contributions therefore require a **contributor license agreement
assigning copyright in the contribution to Daniel Haines**. Without it, a merged
pull request would make the contributor a co-owner of part of the codebase, and
neither the noncommercial license nor any commercial license could be offered
cleanly over the whole.

Say so on the issue and the CLA will be sent. Please don't open a pull request
with substantial code before it is in place — it cannot be merged.

## Building

Open `ChurchBridgeTranslation.xcodeproj` in Xcode on macOS. The shared scheme
`ChurchBridgeTranslation` lives under `xcshareddata/xcschemes` and is required
for Xcode Cloud builds, so keep it shared if you touch project settings.

You will need to set your own signing team; the project's `DEVELOPMENT_TEAM`
will not work for you.

The app points at a ChurchBridge platform instance, configurable in Settings.

## Touching the audio path

`AudioCaptureManager` and `DeepFilterNet3Processor` are the two files where
small changes have large consequences.

- Keep the tap callback light. Copy samples and get off the callback; do
  resampling and chunking on the processing queue.
- Preserve the WebSocket contract — base64 Float32 chunks with the sample rate
  declared at session start. The backend expects it and the browser client
  shares it.
- Do not make a capture path fail silently. If something falls back, the reason
  must reach the diagnostics; a path that degrades quietly is worse than one
  that fails loudly.
- The noise suppression mix is deliberately conservative. It was set by
  listening, not by a metric, after full-strength suppression measured better
  and transcribed worse. Please don't raise it without evidence from real
  audio.

## Things that must not enter this repository

- **Credentials, signing assets, or provisioning profiles.**
- **Model weights.** DeepFilterNet3 assets are downloaded at runtime, not
  bundled.
- **Bible data.** Scripture is fetched from the platform. Reina-Valera 1960 in
  particular is copyrighted and must not be committed here.
- **Recordings.** Captured audio from real services does not belong in version
  control.

See [`THIRD-PARTY-NOTICES.md`](THIRD-PARTY-NOTICES.md) for what the app builds
on and under which terms. If you add a dependency or adapt third-party code, add
it there in the same change.

## Licensing questions

See [`LICENSE-FAQ.md`](LICENSE-FAQ.md), or open an issue.

## Security

Do not report security issues in public issues. Use GitHub's private
vulnerability reporting on this repository.
