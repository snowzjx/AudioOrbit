# AudioOrbit

AudioOrbit is a native macOS menu-bar app that routes an application's audio to the output mapped to the display containing that application's selected window. Different applications can follow different displays and play through different physical outputs at the same time—without changing the system default output device.

## Current status

The repository contains an integrated, hardware-tested MVP. The next phase is onboarding, application rules, broader hardware testing, diagnostics, and release hardening.

Implemented today:

- Per-application Core Audio process taps with safe suppression of the original output.
- Independent routes for multiple audio-producing applications.
- Display-to-output mappings persisted by stable display UUID and Core Audio device UID.
- Automatic window following with 500 ms dwell and display-boundary hysteresis.
- Conservative helper-process correlation, including Safari's `Safari Graphics and Media` process.
- Full-screen transition retention for established Safari and native-app routes.
- Live destination switching with fade-out, fresh buffer priming, and fade-in.
- Mismatched sample-rate support and bounded adaptive correction for independently clocked devices.
- Safe pass-through and same-UID recovery when a normal mapped output disconnects.
- Remembered application routes that remain until the user deletes them.
- Physical-device volume sliders where Core Audio exposes a writable volume control.
- Headphone Override for sending all managed audio to one selected connected output, with clean restoration of display routing on disconnect.
- A native AppKit status item, SwiftUI popover and Settings scene, including application icons and right-click Enable/Disable.

## Requirements

- macOS 14.2 or later.
- Xcode 26, or another Xcode containing the macOS 14.2+ Core Audio process-tap SDK.
- A signed build so macOS can persist privacy permissions reliably.

## Build and test

Open `AudioOrbit.xcodeproj`, select the **AudioOrbit** scheme, and run the app. AudioOrbit appears in the menu bar rather than the Dock.

Run the automated suite from Xcode, or from Terminal:

```sh
xcodebuild -project AudioOrbit.xcodeproj -scheme AudioOrbit test
```

The suite currently contains 41 tests covering the real-time bridge, sample-rate conversion and drift correction, buffer health, display/window policy, concurrent route admission, persistence and schema migration, Core Audio error formatting, and helper-process association.

## Using AudioOrbit

1. Open **Settings…** from the menu-bar popover.
2. In **Displays**, choose a physical audio output for every display AudioOrbit should manage. Choose **Use System Default** to leave applications on that display untouched.
3. In **Permissions**, grant and recheck Accessibility. The first real route may also trigger macOS System Audio Recording permission.
4. Press **Enable** in the menu-bar popover, then play audio in an application with a visible window.
5. Move the window to another mapped display. After a short stable delay, its audio follows the new display.

Left-click the status item to open the popover. Right-click it for quick Enable/Disable and Quit actions. Route cards show the application, display and destination; the trash button removes both the live route and its remembered entry.

### Output volume

The popover shows one slider per physical output that advertises a public writable Core Audio volume scalar. HDMI, DisplayPort and hardware-managed outputs commonly expose a fixed level, so they intentionally have no slider.

### Headphone Override

In **Settings → General**, select a headphone output and enable **Headphone Override**. While that exact output UID is connected, all managed applications use it. Disconnecting the output cleanly restores normal display routing and clears override status; the preference stays armed so the same output can take over again when it reconnects.

## Routing and safety

Each route owns a private process tap, aggregate input, preallocated SPSC bridge, adaptive resampler and AUHAL renderer bound to its selected physical output. Capture and rendering are isolated so one route's failure does not intentionally stop healthy routes.

AudioOrbit prefers audible pass-through over silence. A failed setup tears down the tap. A disappearing mapped destination releases the affected tap so normal macOS playback resumes, while Headphone Override disconnect is treated as a clean policy handoff back to display routing.

Audio frames exist only in bounded volatile memory while being routed. AudioOrbit does not store, transmit, transcribe, fingerprint or analyze audio content, and it does not read window titles or screen pixels.

## Development signing

Debug builds use a project-specific local designated requirement so Accessibility approval survives normal Xcode rebuilds when no Apple Development certificate is installed. This is development-only; Developer ID signing, notarization and distribution validation remain release work.

After replacing an older ad-hoc build, remove the old AudioOrbit entry from **System Settings → Privacy & Security → Accessibility** once, then grant the current build access.

## Documentation

- [Project specification](PROJECT_SPEC.md)
- [Audio routing architecture decision](docs/ADR-001-audio-routing-engine.md)
- [Known limitations](KNOWN_LIMITATIONS.md)
