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

The visible application and audio-producing process may differ. Association is allowed through the same process, a regular parent chain, a unique exact bundle match, or the validated system WebKit media service's client-qualified LaunchServices identity. Ambiguous helpers remain pass-through. This supports Safari while avoiding arbitrary name-prefix capture.

## Persistence and policy overlays

Display mappings persist stable display UUID → device UID intent. Remembered application routes persist by bundle identifier, never PID. Runtime Core Audio IDs, taps and buffers are never persisted.

Headphone Override is a temporary policy overlay. It switches live routes to one explicitly selected connected device UID but does not overwrite their remembered display destinations. Disconnect tears down override routes first and immediately recalculates normal display routing; reconnect may reactivate the armed preference.

## Failure behavior

- A partial setup failure destroys created objects in reverse order and leaves or restores pass-through.
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
- [x] Normal output hot-plug recovery and Headphone Override connect/disconnect have been exercised.
- [x] Forty-one automated tests cover bridge, health, policy, persistence, migration, association and admission behavior.
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
