# iOS Development Notes

This note captures the practical findings from the first Church Bridge native iPhone app build and deployment cycle.

Scope:

- Native SwiftUI iPhone app in [churchbridge-ios](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios)
- Deployment workflow through the macOS VM, Xcode, Xcode Cloud, App Store Connect, and TestFlight
- Signing, provisioning, and packaging issues that came up during the first end-to-end release attempt

## Project Location

Primary workspace:

- [churchbridge-ios](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios)

macOS VM shared path:

- `~/MacVmShared/churchbridge-ios`

Project file:

- [ChurchBridgeTranslation.xcodeproj](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation.xcodeproj/project.pbxproj)

Main app target:

- `ChurchBridgeTranslation`

## VM Workflow

The reliable workflow for building and validating the app is:

1. Edit files from the Windows side in the shared workspace.
2. Use the macOS VM for Xcode builds, archives, simulator runs, and Apple-service interactions.
3. Prefer the existing VM script runner when possible:
   - `C:\Users\Dan\Desktop\Projects\macOS-ios-dev\scripts\Invoke-MacVmScript.ps1`
4. Use `ssh mac-vm` when direct inspection is faster, especially for:
   - `~/Downloads`
   - Xcode Cloud log artifacts
   - ad hoc local build verification

Important practical note:

- App Store Connect and Xcode Cloud failures often need log inspection from the VM `Downloads` folder. Do not rely on the App Store Connect summary alone.

## Current App Identity

Current bundle identifier:

- `com.churchbridgeqa.translationtest`

Current Apple team id:

- Set in Xcode under Signing & Capabilities; the team identifier is not
  recorded here.

Current default backend server:

- `https://churchbridge.dhaines.dev/`

That default is currently set in:

- [SettingsStore.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/SettingsStore.swift)

## Git And Xcode Cloud Requirements

Xcode Cloud required a remote Git repository.

Working setup:

- GitHub repo: `https://github.com/hainesdev/churchbridge-ios`
- branch: `main`

Important project details that mattered for Xcode Cloud:

1. The project needed a shared scheme.
2. User-specific Xcode metadata should not be committed.
3. The repo needed to be pushed before Xcode Cloud setup.

Current relevant repo hygiene:

- shared scheme exists under `xcshareddata/xcschemes`
- `.gitignore` excludes `xcuserdata/` and `*.xcuserstate`

## Signing And Provisioning Findings

### 1. App Store Connect Access Is Not Immediate After Payment

Apple Developer Program activation can lag after payment.

Observed pattern:

- account showed purchase-processing state before full activation
- App Store Connect access was blocked until membership became active

Practical recommendation:

- verify the membership is active before debugging Xcode or App Store Connect permissions

### 2. Xcode Cloud Can Succeed For App Store Export While Still Marking The Build Failed

This happened during the first Xcode Cloud attempts.

What the logs showed:

- App Store export succeeded
- Development export failed
- Ad Hoc export failed

Exact root cause:

- the Apple team had no registered physical devices yet
- Xcode Cloud could not generate Development or Ad Hoc provisioning profiles

Typical failure lines found in the logs:

- `No profiles for 'com.churchbridgeqa.translationtest' were found`
- `Your team has no devices from which to generate a provisioning profile.`

Meaning:

- a red Xcode Cloud build status did not necessarily mean the App Store export path was broken
- always inspect the separate export logs before assuming signing is fully broken

### 3. Registering A Physical iPhone Matters For Development And Ad Hoc Exports

If Xcode Cloud or Xcode tries to produce Development or Ad Hoc outputs, Apple needs at least one registered device on the team.

Practical recommendation:

- register at least one real iPhone early in the project lifecycle
- this reduces confusion when cloud builds try to generate non-App-Store provisioning profiles

### 4. Manual Archive And Upload Is Still A Useful Escape Hatch

Even when Xcode Cloud is available, manual archive/upload from Xcode in the VM is still valuable for:

- faster iteration
- clearer signing errors
- easier TestFlight uploads when the cloud workflow becomes noisy

## TestFlight Findings

### 1. TestFlight Will Not Show The App Just Because The Device Is Registered

Seeing only the `Redeem` screen on the iPhone usually means:

1. no build has finished processing yet, or
2. the Apple ID has not been added to internal testing, or
3. the build has not been assigned to the internal testing group

Required steps:

1. upload the build
2. wait for processing
3. add the Apple ID as an internal tester
4. attach the build to that internal testing group

### 2. Device Registration And TestFlight Solve Different Problems

Device registration helps:

- Development signing
- Ad Hoc signing

TestFlight requires:

- a processed App Store Connect build
- tester assignment

Do not treat device registration as sufficient for TestFlight availability.

## App Store Connect Packaging Findings

The first accepted upload path still produced a rejection email because the bundle was missing required icon packaging.

Apple rejection codes encountered:

- `ITMS-90022: Missing required icon file`
- `ITMS-90713: Missing Info.plist value`

Root cause:

1. the app had an `AppIcon.appiconset` entry but no actual PNG assets inside it
2. the hand-written `Info.plist` was missing `CFBundleIconName`

Fix that was applied:

- added all required iPhone icon PNGs to:
  - [AppIcon.appiconset](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/Assets.xcassets/AppIcon.appiconset)
- updated:
  - [Info.plist](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/Info.plist)
  - set `CFBundleIconName` to `AppIcon`

Practical recommendation:

- if the project uses a hand-authored `Info.plist` with `GENERATE_INFOPLIST_FILE = NO`, verify icon-related keys explicitly
- do not assume `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon` is enough if the asset catalog is empty

## Audio And Backend Findings

The key implementation constraints for future iOS work were:

1. preserve the current websocket contracts:
   - `/api/stream/v1`
   - `/api/display/v1`
2. use native iOS audio capture, not web or browser APIs
3. prefer Apple voice-processing features when supported

Important backend finding:

- the current server still expects base64-encoded `Float32` microphone payloads from the client, even though the server converts internally later

Important validation finding:

- simulator behavior is only good for functional validation
- physical iPhone testing is still required for real voice-processing quality validation

For the detailed audio research and architecture notes, see:

- [IOS_AUDIO_NOTES.md](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/IOS_AUDIO_NOTES.md)

## Recommended Future Checklist

For the next native iOS feature or release, use this order:

1. Confirm Apple Developer membership is active.
2. Confirm App Store Connect access works.
3. Confirm the project has:
   - a real bundle id
   - a team id
   - a shared scheme
   - app icons populated in the asset catalog
   - `CFBundleIconName` present when using a manual `Info.plist`
4. Push the project to Git before setting up Xcode Cloud.
5. Register at least one physical iPhone on the Apple team early.
6. Validate a local VM build before starting cloud builds.
7. When Xcode Cloud fails, inspect the per-export logs from `~/Downloads`.
8. For TestFlight, verify:
   - build uploaded
   - build processed
   - internal tester added
   - build assigned to the test group
9. Validate real audio behavior on a physical iPhone before treating the feature as complete.

## Files Most Likely To Need Attention In Future Releases

- [project.pbxproj](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation.xcodeproj/project.pbxproj)
- [Info.plist](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/Info.plist)
- [AppIcon.appiconset](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/Assets.xcassets/AppIcon.appiconset)
- [SettingsStore.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/SettingsStore.swift)
- [AudioCaptureManager.swift](C:/Users/Dan/Desktop/Projects/macOS-ios-dev/shared/churchbridge-ios/ChurchBridgeTranslation/AudioCaptureManager.swift)
