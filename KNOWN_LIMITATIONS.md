# Known limitations

AudioOrbit is an integrated MVP under product and release hardening. The following limitations are current and intentional unless noted otherwise.

Only one ordinary AudioOrbit instance is allowed at a time so two copies cannot compete for the same process taps. Quit an older Debug build before launching a newly built copy.

## Routing model

- Routing is per audio-producing process/application, not per window, tab, document or individual stream. Multiple windows owned by one process share one audio route.
- Audio helpers are associated conservatively. Regular parent applications, unique exact bundle matches and the validated system WebKit media service are supported; unresolved or ambiguous helpers remain on normal macOS playback.
- Multiple independent routes may target the same output, but a shared per-device mixer and same-destination stress matrix have not been completed.
- Protected/DRM content and processes that reject public Core Audio taps may remain pass-through.

## Window tracking

- Window state is reconciled at a bounded 250 ms interval while enabled; audio-process state is reconciled once per second. Full per-application `AXObserver` coverage is not implemented.
- Safari/WebKit full-screen surfaces can disappear from the standard Accessibility list during a Space transition. Established routes retain their last valid display during that transition. Broader validation across Safari/WebKit releases, Stage Manager, Spaces and Electron apps remains open.
- Accessibility reads roles, focus, minimization and geometry only. AudioOrbit intentionally does not read window titles or screen pixels.

## Audio engine

- The real-time bridge accepts 32-bit floating-point mono or stereo process-tap PCM. Other source layouts fail safely to pass-through.
- Sample-rate mismatch and clock drift use preallocated linear interpolation with bounded adaptive queue correction. This is stable in current hardware tests but is not a final high-fidelity converter decision.
- Destination switching uses sequential 25 ms fade-out, renderer replacement, fresh priming and fade-in rather than an overlapping two-device crossfade.
- Buffer capacity is currently fixed at 16,384 source frames. Final latency/buffer budgets require broader measurements.
- Long-run testing still needs a continuous 30-minute multi-rate run and a one-hour four-route run across built-in, USB, HDMI/DisplayPort and Bluetooth outputs.

## Devices and settings

- Physical volume control is available only when the output publishes a writable Core Audio scalar. Fixed-level HDMI/DisplayPort and hardware-managed devices do not show a slider.
- Headphone Override targets one explicitly selected device UID. It does not infer headphones from a product name or connector jack state.
- Headphone Override is temporary policy: disconnect restores display routing, while reconnecting the same UID activates the still-armed preference.
- Display mappings, remembered application routes and Headphone Override use persistence schema version 2. Version 1 migration and corrupt-file recovery are covered by tests.

## Product and release work

- The first-run welcome flow is implemented, but the native System Audio Recording prompt is intentionally deferred until the first real route. A standalone test tone, Launch at Login and per-application exclude/pass-through rules are not implemented yet.
- Privacy-safe support-report preview/export, coded unified logs and performance signposts are implemented. A completed hands-on VoiceOver review remains a release gate; raw feasibility controls remain absent from the end-user UI.
- Debug signing is designed for local TCC continuity only. Developer ID signing, hardened-runtime distribution behavior, notarization, updates and permission persistence across shipped upgrades still require validation.
- Permission revocation, force quit, injected crash, sleep/wake, fast user switching and the full minimum/latest-macOS hardware matrix remain release gates.

No claim is made yet that every release-candidate acceptance criterion in `PROJECT_SPEC.md` passes.
