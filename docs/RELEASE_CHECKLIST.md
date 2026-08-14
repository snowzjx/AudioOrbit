# AudioOrbit release checklist

Do not distribute a build until every required row has evidence. Hardware-dependent rows cannot be satisfied by unit tests alone.

## 1. Automated preflight

- [ ] Debug unit tests pass.
- [ ] Release configuration builds with Hardened Runtime enabled.
- [ ] `git diff --check` passes and the release commit is tagged.
- [ ] The support-report redaction test passes.
- [ ] The app contains `NSAudioCaptureUsageDescription` and remains an `LSUIElement` at launch.
- [ ] Launching a second ordinary copy is refused so process taps cannot be managed by competing instances.

## 2. Core endurance

- [ ] Route two continuously playing applications to independently clocked outputs with different nominal rates for at least 30 minutes.
- [ ] Confirm no recurring underflow/overflow after warm-up and peak queue occupancy remains below 90%.
- [ ] Run at least four simultaneous process routes for one hour.
- [ ] Compare beginning/end support reports; resident-memory growth is below 20 MB after warm-up and counters remain bounded.
- [ ] Measure wired end-to-end latency; AudioOrbit-added latency is below 100 ms.
- [ ] Record Bluetooth latency separately.

## 3. Failure recovery

For every row, confirm normal macOS playback returns promptly and the source is not left silent.

- [ ] Disconnect a mapped output during preparation, stable playback and live switching.
- [ ] Disconnect/reconnect the Headphone Override device.
- [ ] Deny System Audio Recording on first request.
- [ ] Revoke Accessibility while routes are active.
- [ ] Quit normally with active routes.
- [ ] Force quit with active routes.
- [ ] Inject a crash in a development build with active routes.
- [ ] Sleep and wake with active routes.
- [ ] Log out or fast-user-switch where feasible.
- [ ] Hot-plug displays and audio devices repeatedly.

## 4. Window and application matrix

- [ ] Music or another native AppKit application.
- [ ] Safari normal playback and full-screen transitions.
- [ ] A Chromium/Electron application.
- [ ] One process with windows on different displays; focused/main/fallback selection is deterministic.
- [ ] Spaces, Stage Manager, hidden windows and minimized windows.
- [ ] Negative-origin and vertically stacked display arrangements.

## 5. User experience and accessibility

- [ ] First launch presents the welcome window once and its Settings button opens the Settings scene.
- [ ] Accessibility allow, deny, recheck and later revoke paths use understandable language and never loop prompts.
- [ ] VoiceOver can reach Enable/Disable, route state, route deletion, volume, display mappings, Headphone Override, permissions, support preview/export and Quit.
- [ ] Route state and permission state are understandable without color.
- [ ] Settings can be opened and closed repeatedly; the Dock icon appears only while a titled AudioOrbit window is open.
- [ ] Default, Dark and Mono app-icon appearances render correctly.

## 6. Signing and distribution

- [ ] Archive using the intended Developer ID Application identity and Team ID.
- [ ] Verify the signature, designated requirement and Hardened Runtime.
- [ ] Submit the ZIP with `notarytool`, wait for acceptance, staple the ticket and run Gatekeeper assessment.
- [ ] Install the stapled app on a clean test account and on the minimum supported macOS release.
- [ ] Confirm Accessibility and System Audio Recording permission behavior across relaunch and an app update.
- [ ] Publish known limitations and the exact minimum macOS version with the beta.

## Evidence record

| Date | Build | Mac / macOS | Outputs | Scenario | Result | Evidence |
| --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |
