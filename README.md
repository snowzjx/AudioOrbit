# AudioOrbit

AudioOrbit is a native macOS menu-bar app that sends each application's audio to the output mapped to the display containing its window. Multiple applications can play through different physical outputs simultaneously without changing the system default output.

## Key features

- Automatic display-to-audio-output routing for multiple applications.
- Stable Safari and helper-process routing, including full-screen transitions, playback-window anchoring, and following a playing tab dragged to another window or display.
- Smooth live destination switching with sample-rate conversion and adaptive clock correction.
- Persistent display mappings, remembered routes, and application-level ignore rules.
- Headphone Override sends all managed audio to one selected device and restores display routing when it disconnects.
- Physical-device volume controls when the output exposes a writable Core Audio volume control.
- Optional launch at login from Settings → General.
- Optional notification when an application's audio follows its window to a different output.
- Automatic updates via Sparkle (menu bar → right-click → Check for Updates).
- Safe pass-through when permission, capture, or destination failures occur.
- Private by design: audio stays in bounded volatile memory and is never stored, transmitted, transcribed, or analyzed.

## Requirements

- macOS 14.2 or later.
- Accessibility permission for window location and focus.
- System Audio Recording permission when the first route starts.

The production bundle identifier is `me.snowzjx.AudioOrbit`.

## Use AudioOrbit

1. Download the latest notarized ZIP from [GitHub Releases](https://github.com/snowzjx/AudioOrbit/releases), move AudioOrbit to Applications, and open it.
2. Open **Settings → Displays** and map each display to a physical audio output. Choose **Use System Default** to leave a display unmanaged.
3. Grant and recheck Accessibility permission in **Settings → Permissions**.
4. Enable AudioOrbit from the menu-bar popover and start playback.

Moving the selected window to another mapped display moves its audio after a short stable delay. Removing a route permanently ignores that application until **Settings → General → Allow Again** is selected.

Safari media routes stay anchored to the window where playback began, so using another Safari window does not move established audio. Dragging the playing tab into another window — including tearing it off into a new window on another display — follows the audio to the destination window after a short dwell. Pausing and resuming the same video keeps the audio where it was. Safari does not expose reliable public per-tab audio ownership, so simultaneous tabs or background autoplay can remain ambiguous.

## Build and test

Open `AudioOrbit.xcodeproj` and run the **AudioOrbit** scheme with Xcode 26 or a compatible Xcode containing the macOS Core Audio process-tap SDK.

```sh
xcodebuild -project AudioOrbit.xcodeproj -scheme AudioOrbit test
```

The automated suite contains 60 tests.

## Documentation

- [Product specification](PROJECT_SPEC.md)
- [Audio routing architecture](docs/ADR-001-audio-routing-engine.md)
- [Performance budgets](docs/PERFORMANCE_BUDGETS.md)
