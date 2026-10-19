# Fast Power Nap

A dark-mode Flutter app for **sleep-timed power naps**. The countdown starts after the app detects that you have fallen asleep—not when you tap **START NAP**.

If it takes a few minutes to drift off, that time does not reduce your nap. If you wake up during the session, the countdown pauses and resumes after sleep is detected again.

## How it works

1. Place your phone flat beside your pillow and tap **START NAP**.
2. The app monitors stillness and, when enabled and available, breathing and ambient sound.
3. Once the sleep-detection conditions are met, your selected nap countdown begins.
4. During the nap, sustained strong movement is treated as waking: the countdown pauses while the app waits for you to fall asleep again.
5. If you do not fall back asleep within the selected detection period plus 10 minutes, the session ends early.
6. At the end of the countdown, a gentle alert plays and the app shows your sleep time and number of detected wake-ups.

## Sleep detection

Detection combines up to three on-device signals:

| Signal | Source | Role |
|--------|--------|------|
| **Stillness** | Accelerometer | The required signal. Choose Fast (about 3 minutes), Standard (about 7 minutes), or Slow (about 12 minutes). A brief movement such as rolling over only partially reduces accumulated stillness; stronger movement resets it. |
| **Breathing** | Microphone | A detected regular breathing rhythm shortens the stillness requirement by about one third. |
| **Quiet** | Microphone | Recent loud sounds, such as talking or coughing, can delay sleep confirmation. After extended stillness, the sound check is overridden so a noisy room cannot block detection indefinitely. |

The microphone assist can be disabled in Settings. If permission is denied or the microphone is unavailable, detection automatically uses motion only. Audio is analyzed in memory only while detecting; it is never saved or uploaded. The microphone stops after sleep is detected and starts again if you wake.

## Features

- **Sleep-timed countdown** — choose a preset of 10, 15, 20, 30, or 45 minutes, or set a custom duration from 5 to 90 minutes. The default is 20 minutes.
- **Wake detection and resume** — sustained strong movement pauses the timer; the remaining time is preserved while sleep is detected again.
- **Adjustable sleep sensitivity** — Fast (3 min), Standard (7 min), or Slow (12 min) stillness target.
- **Optional microphone assist** — uses breathing rhythm and recent ambient sound to improve detection.
- **Optional white noise** — soft synthesized brown noise starts only after sleep is detected, so it does not mask breathing during detection.
- **Optional black screen after sleep** — lowers the app's screen brightness and displays a pure black overlay while the session keeps running. Tap the screen to briefly reveal the timer for 5 seconds. Brightness is restored when dimming ends; this changes app brightness, not the device's system brightness setting.
- **Gentle wake-up alert** — a synthesized chime plays when the selected countdown completes.
- **Screen stays on during a session** — a wakelock helps keep the app and sensors active.
- **Dark, distraction-free UI** — clear session phases, a large timer, and signal indicators while detecting.
- **Session summary** — displays nap time and detected wake-ups.

## Getting started

### Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) SDK (3.3+)
- iOS and/or Android device or emulator (sensors work best on a physical device)

### Run

```bash
flutter pub get
flutter run
```

### Build with GitHub Actions

The workflow [`.github/workflows/build.yml`](.github/workflows/build.yml) builds a release **APK** and an unsigned **IPA** on GitHub.

**Trigger it:**

1. **Actions** → **Build APK & IPA** → **Run workflow**, or
2. Push a version tag: `git tag v1.1.0 && git push origin v1.1.0`

Artifacts appear under the workflow run (**android-apk-…** / **ios-ipa-…**). Tags starting with `v` also attach the files to a GitHub Release.

| Artifact | Notes |
|----------|--------|
| APK | Release build (currently signed with the debug keystore — fine for sideload/testing) |
| IPA | Unsigned; re-sign with your Apple Developer cert before installing on a device or uploading to App Store / TestFlight |

Flutter version used in CI is pinned to **3.47.7** (stable), matching this project.

### Permissions

- **Microphone** (optional) — used during sleep detection for breathing and ambient sound analysis. Disable anytime in Settings.

## Project structure

```
lib/
  main.dart                 # App entry, dark theme, portrait lock
  nap_home_page.dart        # UI: phases, timer, settings sheet
  nap_controller.dart       # Sleep fusion, wake monitor, countdown, audio
  sleep_audio_analyzer.dart # In-memory PCM analysis (breathing + quiet)
```

## License

Private / unpublished (`publish_to: 'none'`).
