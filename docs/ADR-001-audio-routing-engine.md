# ADR-001: Audio routing engine

**Status:** Accepted for the integrated MVP; converter, shared-output mixing and distribution choices remain provisional
**Date:** 2026-08-13

## Context

macOS has no public API that directly assigns another application's output to an arbitrary physical device. AudioOrbit must capture one process, suppress its normal path only while capture is actively consumed, bridge independently clocked callbacks, and render to a selected output. Any failure must converge to normal macOS playback without disturbing unrelated routes.

The key risks were tap lifecycle safety, output binding, independent-clock drift, external-device startup latency, multi-route isolation, helper-process correlation and hot-plug recovery.

## Decision

AudioOrbit's integrated MVP uses the following architecture:

1. One isolated route session per audio-producing process.
2. A private `CATapDescription` using `mutedWhenTapped` and a private aggregate device containing that tap.
3. A direct aggregate-device input IO procedure that actively reads tap frames.
4. A preallocated C SPSC bridge between capture and render callbacks.
5. One AUHAL renderer per route, explicitly bound to the selected physical output device.
6. Float32 mono/stereo as the accepted bridge input, with preallocated linear interpolation for nominal-rate conversion.
7. Bounded adaptive queue correction to compensate for independent capture/output clocks.
8. A 25 ms gain ramp, fresh resampler priming and first-hardware-callback rebase for start and destination changes.
9. Atomic callback/buffer counters sampled outside the real-time path.
10. Reverse-order, idempotent teardown that stops reads and output before destroying the aggregate device and tap.

This design uses public Core Audio APIs and never changes the system default output device. Audio buffers are bounded, volatile and never persisted or transmitted.

## Route ownership and concurrency

Each process route owns its tap, aggregate input, bridge, resampler, renderer, health analyzer, switch lifecycle and recovery state. This gives clear failure isolation and already supports multiple processes routed to distinct outputs concurrently.

The current implementation also permits multiple route renderers to target one device, relying on the system's output path. A dedicated shared per-device mixer is deferred until same-destination stress and latency evidence justify its complexity.

## Clocking, buffering and switching

Capture and physical-output devices are treated as independently clocked even when their nominal rates match. The renderer consumes through a proportional queue controller, with correction bounded to ±0.5% around an approximately 43 ms source-frame target.

The bridge uses drop-newest overflow behavior and renders silence/re-primes on underflow. On startup and live switching, the consumer is rebased immediately before renderer start and once more in the first real hardware callback. The second rebase prevents delayed USB, display and other external devices from playing stale captured backlog.

Destination switching validates the new device first, fades the committed renderer to zero, disposes it, binds a replacement AUHAL instance, rebases and primes from fresh frames, then fades to unity. If validation fails, the committed route remains. If replacement fails after the old renderer stops, the tap is torn down so the source returns to pass-through.

An overlapping two-device crossfade was rejected for the current architecture because one SPSC buffer must not have competing consumers. Sequential ramp/rebind is simpler, bounded and hardware-tested.

## Window and application association

Display geometry uses public Core Graphics display UUIDs and `CGDisplayBounds`. Accessibility supplies focused/main/standard-window state without reading titles. Selection uses focused window, main window, then largest eligible visible window; display choice uses largest intersection with deterministic ties and boundary hysteresis.

AudioOrbit reconciles window state every 250 ms while enabled and audio-process state every second. A candidate display dwells for 500 ms, and established routes retain their last display while a full-screen or Space transition temporarily hides normal window evidence.

The visible application and audio-producing process may differ. Association is allowed through the same process, a regular parent chain, a unique exact bundle match, or the validated system WebKit helpers' client-qualified LaunchServices identity — both the GPU media helper (`com.apple.WebKit.GPU`) and the per-tab WebContent renderers (`com.apple.WebKit.WebContent`, which host WebRTC and WebAudio media) associate through the longest-unique application-name prefix. Ambiguous helpers remain pass-through. When the running-app lookup fails transiently during Safari's helper restarts, the Apple-signed bundle identifier alone is trusted. This supports Safari while avoiding arbitrary name-prefix capture.

When the audio source is a helper process, its first selected owner window becomes a playback-window anchor. Public Core Graphics window numbers provide stable identity where Accessibility lacks one. Later focus changes within the owner application do not replace the anchor; moving the anchored window still follows display routing, while a temporarily missing anchor retains its last committed output. A stopped-to-running output transition is a playback-session boundary, but the release is verified against the renderer identity: a pause/resume of the same tab keeps the anchor, and only a genuinely new renderer releases it for re-selection. This reduces false Safari route changes without claiming per-tab audio identity or allowing multiple windows from one helper route to target different outputs. The renderer identity is authoritative: the window reporting the anchored renderer is the playback window; when the anchor window and a fresh window both report it, the fresh window wins (the anchor's BrowserView stays stale until its active tab navigates). Only when the renderer is gone does the anchor fall back to the unique media-indicator window or the freshest media window, each behind a continuity dwell with transient-Accessibility tolerance. Safari window identifiers embed volatile page state (`SafariWindow?IsSecure=…&UUID=…`), so fallback identities are normalized to the stable UUID. During a full-screen transition the anchored window becomes invisible without a replacement, so the route holds its last committed display and freezes re-pinning until the window returns. When Safari restarts a WebKit helper mid-playback, the route migrates to the replacement source process instead of stopping. The manual re-anchor action pins the anchor authoritatively until the session restarts or the pinned window disappears.

## Persistence and policy overlays

Display mappings persist stable display UUID → device UID intent. Remembered application routes and ignored applications persist by the visible application's bundle identifier, never PID or helper-process identity. Removing a route replaces remembered intent with an ignore rule; the rule excludes that application and its associated audio helpers from route creation, restoration and Headphone Override until the user explicitly allows it again. Runtime Core Audio IDs, taps and buffers are never persisted.

Headphone Override is a temporary policy overlay. It switches live routes to one explicitly selected connected device UID but does not overwrite their remembered display destinations. Disconnect tears down override routes first and immediately recalculates normal display routing; reconnect may reactivate the armed preference.

## Failure behavior

- A partial setup failure destroys created objects in reverse order and leaves or restores pass-through.
- Stop and quit cancel and await any in-flight destination switch before teardown; the probe also revalidates callback-object identity after every suspension point.
- HAL object IDs and callback contexts are retained when destruction fails. The route stays visible, retries cleanup automatically, and offers a manual retry until cleanup completes.
- Automatic reconciliation treats starting, switching, stopping and reconnecting routes as busy; it retries the decision instead of replacing an in-flight route.
- A normal mapped-output disconnect releases the affected muting tap and preserves the destination UID for same-device recovery.
- A Headphone Override disconnect is a clean policy handoff, not a missing-device warning.
- Global disable and normal quit stop every active session.
- One route's failure is isolated from other route sessions.
- Configuration corruption is quarantined and replaced with safe disabled defaults.

## Evidence

- [x] Signed macOS app with `NSAudioCaptureUsageDescription` builds and runs.
- [x] `mutedWhenTapped` suppresses normal playback while AudioOrbit actively reads and renders the tap.
- [x] Captured audio renders to a nondefault physical output without changing the system default.
- [x] Multiple independent applications route concurrently.
- [x] Matching and mismatched nominal rates pass deterministic bridge tests.
- [x] External-device startup and live destination switching use fresh first-callback priming.
- [x] Adaptive correction removed the observed sustained buffer-pressure failure on the tested external device.
- [x] Music, Safari helper audio and Safari full-screen transitions have been exercised successfully.
- [x] Safari tab tear-off and dragged playing tabs follow the renderer identity (WebViewProcessID) to the destination window, including tearing a tab into a new window on another display, with freshness arbitration while the source window's BrowserView entry is still stale.
- [x] Working in a non-playing Safari window never moves established audio; the renderer identity is authoritative over the focus-driven audio indicator.
- [x] Routes migrate to a replacement WebKit helper process when Safari restarts its media helpers, preserving session, anchor and destination.
- [x] Normal output hot-plug recovery and Headphone Override connect/disconnect have been exercised.
- [x] Sixty automated tests cover bridge, health, route recovery, permission revocation, diagnostics redaction, onboarding persistence, window and playback-affinity policy, media-target selection, Safari identifier normalization, configuration migration, persistent ignore policy, association and admission behavior.
- [x] Privacy-safe support reports expose resource, latency and buffer-health evidence without application, device, display, PID, UID, window-title or path identity.
- [ ] Complete a continuous 30-minute multi-rate run after the latest correction changes.
- [ ] Complete a one-hour four-route CPU/memory/wakeup/deadline run.
- [ ] Measure end-to-end wired and Bluetooth latency on the release hardware matrix.
- [ ] Validate Electron, Stage Manager, sleep/wake, permission revocation, force quit and injected crash.
- [ ] Validate the minimum supported macOS release and the intended Developer ID/notarized distribution.

## Consequences

### Positive

- Uses only public APIs and preserves the system default output.
- Keeps real-time work bounded and avoids Swift concurrency in callbacks.
- Isolates route failures and supports concurrent destinations.
- Handles external-device startup, sample-rate mismatch and clock drift without unbounded buffering.
- Keeps UI, persistence and Accessibility work outside the audio data plane.

### Tradeoffs

- Per-route AUHAL clients cost more resources than a shared per-device mixer.
- Linear interpolation favors bounded, inspectable behavior over final conversion quality.
- Sequential switching has a short intentional fade rather than a true crossfade.
- Periodic window reconciliation is less energy-efficient than complete observer coverage.

## Follow-up decisions

Create additional ADRs or amend this record before changing any of these:

- production-quality converter and final buffer/latency budgets;
- shared per-device mixing architecture;
- sandbox, Developer ID, notarization and update strategy;
- any expansion beyond public process taps, including a virtual driver;
- helper-process correlation rules that broaden the current conservative trust boundary.
