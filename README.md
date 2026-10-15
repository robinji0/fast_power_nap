# Fast Power Nap

A minimal dark-mode Flutter app for **20-minute power naps**. The countdown starts only after you fall asleep — not when you press the button.

## Why

Most nap timers begin the moment you tap Start. If it takes you five minutes to drift off, you lose that time from your actual rest.

Fast Power Nap waits until you are still (and optionally quiet / breathing regularly), then starts a true 20-minute recovery window. If you wake up mid-nap, the timer pauses and resumes only after you fall asleep again.

## How it works

1. Place your phone flat beside your pillow and tap **START NAP**.
2. The app enters a **detecting** phase and watches for sleep signals.
3. Once sleep is confirmed, a **20-minute countdown** begins.
4. During the nap, motion is monitored for waking. A brief roll over is ignored; getting up pauses the timer.
5. If you stay awake for too long (about 10 minutes), the session ends early.
6. When the countdown finishes, a gentle alert wakes you.

## Sleep detection

Detection fuses up to three on-device signals:

| Signal | Source | Role |
|--------|--------|------|
| **Stillness** | Accelerometer | Required continuous stillness (2–4 min depending on strictness) |
| **Breathing** | Microphone | Regular breathing shortens the stillness requirement |
| **Quiet** | Microphone | Recent ambient spikes (talking, coughing) delay the start |

If the microphone is off, denied, or unavailable, the app falls back to motion-only detection.

Audio is analyzed in memory in real time. Nothing is saved or uploaded.

## Features

- **True sleep-timed nap** — countdown starts after sleep detection, not on tap
- **Wake & resume** — timer pauses if you wake; resumes after you settle again
- **Adjustable strictness** — Relaxed (2 min), Standard (3 min), or Strict (4 min)
- **Optional white noise** — plays only after sleep is confirmed, so it does not mask breathing during detection
- **Optional mic assist** — toggle breathing / ambient analysis in Settings
- **Screen stays on** — wakelock keeps the display awake during a session
- **Dark, distraction-free UI** — large circular control, clear phase states, signal chips while detecting
- **Session summary** — actual sleep time and wake count when finished

## Getting started

### Prerequisites

- [Flutter](https://docs.flutter.dev/get-started/install) SDK (3.3+)
- iOS and/or Android device or emulator (sensors work best on a physical device)

### Run

```bash
flutter pub get
flutter run
```

### Permissions

- **Microphone** (optional) — only used during the detecting phase for breathing and ambient sound. Disable anytime in Settings.

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
