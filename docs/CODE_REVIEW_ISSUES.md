# Code Review Findings: Route Lifecycle Races (Issues 1–3)

**Status:** Resolved and verified by the 58-test automated suite
**Source:** Code review of the AudioOrbit 0.2.0 source tree
**Scope:** The three highest-severity findings. All three concern the same area: the
route control plane (AppModel + ProcessTapProbe) can tear down a probe whose
destination switch is still in flight, and a failed teardown has no recovery path.

| # | Title | Severity |
| - | ----- | -------- |
| 1 | Use-after-free: probe teardown can destroy the bridge while `switchDestination` is suspended | Critical |
| 2 | Automatic routing decisions stop routes that are mid-switch | High |
| 3 | A failed tap teardown can leave the source application muted with no recovery UI | High |

## Resolution (2026-08-15)

All three findings were confirmed. Issue 3 understated one detail in the original
implementation: failed HAL destruction cleared object IDs, so teardown was not
actually retryable after every partial failure.

- **Issue 1:** route sessions now retain the in-flight switch task. Stop and quit
  cancel and await it before teardown. `ProcessTapProbe` also checks that the same
  bridge and renderer are still active before every bridge access following an
  asynchronous suspension.
- **Issue 2:** automatic display following and Headphone Override now use an
  explicit reconciliation policy. Starting, switching, stopping, reconnecting,
  and cleanup-retry sessions are treated as busy and revisited instead of stopped.
- **Issue 3:** failed cleanup retains the still-live Core Audio IDs and callback
  contexts, keeps the route visible, retries automatically, and exposes a manual
  retry button. Normal-playback restoration is reported separately from final
  resource cleanup.

Three deterministic tests cover the new reconciliation policy. The full 58-test
suite passes both normally and under Thread Sanitizer. Hardware timing and forced
HAL-failure injection remain part of the manual release matrix because the
production Core Audio objects are not injected in the current AppModel architecture.

---

## Issue 1 — Use-after-free race between `switchDestination` and probe teardown

**Severity:** Critical
**Affected components:** `ProcessTapProbe`, `AppModel` route control plane

### Locations

- `AudioOrbit/Platform/CoreAudio/ProcessTapProbe.swift:157-210` — `switchDestination(to:)`
- `AudioOrbit/Platform/CoreAudio/ProcessTapProbe.swift:291-300` — `waitForGainRamp(on:)`
- `AudioOrbit/Platform/CoreAudio/ProcessTapProbe.swift:212-262` — `tearDown()` (destroys the C bridge at line 236-239)
- `AudioOrbit/App/AppModel.swift:613-619` — `stopRoute` calls `session.probe.stop()`
- `AudioOrbit/App/AppModel.swift:688-696` — `quit()` calls `try? session.probe.stop()` for every session
- `AudioOrbit/App/AppModel.swift:824-843` — `relinquishDisconnectedHeadphoneOverride()` stops headphone-override routes

### Description

`switchDestination(to:)` is the **only** asynchronous method in the probe lifecycle.
It ramps the bridge gain to zero and then awaits `waitForGainRamp(on:)`, which
suspends on `Task.sleep` every 2 ms until the render thread publishes a completed
ramp (deadline 250 ms).

While the switch is suspended, the main actor is free to run other work. Any of the
following can execute `probe.stop()` → `tearDown()` → `AOAudioBridgeDestroy(bridge)`
during that window:

- `stopRoute` — trash button / ignore route (user action)
- `quit()` — application quit
- `relinquishDisconnectedHeadphoneOverride()` — headphone override device unplugged
  during a switch (hardware-driven, no user action needed)

`probe.isRunning` is still `true` during a switch (the tap IO proc is alive until
teardown), so `stopRoute`'s guard at `AppModel.swift:613` does not protect it.
`RouteSession` stores no handle to the in-flight switch task, so `stopRoute` can
neither wait for nor cancel it.

When the suspended switch resumes, its captured `OpaquePointer` now points to freed
memory:

1. `AOAudioBridgeRead(bridge)` reads freed memory (`waitForGainRamp`, line 294).
2. The catch path calls `AOAudioBridgeBeginGainRamp(bridge, …)` on freed memory (line 174).
3. If the ramp "completes", the switch proceeds to build and **start a brand-new HAL
   output unit** whose render callback pulls from the freed bridge, and
   `AOAudioBridgeConfigureOutputSampleRate` writes into freed memory (line 196).

### Reproduction

1. Start a route on a mapped display.
2. Begin a destination switch (move the window to another mapped display, or trigger
   a headphone-override switch).
3. Within the gain-ramp window (typically tens of ms, bounded by the 250 ms deadline):
   - press the trash button on the route row (ignore), or
   - quit the app, or
   - unplug the headphone-override device, which forces an immediate hardware
     reconciliation and stops the override routes.

Expected: crash or heap corruption (deterministic under ASan/TSan; intermittent in
release builds).

### Root cause

Main-actor re-entrancy at the `await` point inside `switchDestination` combined
with teardown that neither waits for the in-flight switch nor is detected by it.
The bridge pointer captured by the switch has no lifetime guard.

### Recommended fix

Apply both layers:

1. **Primary — serialize teardown with the switch.** Store the switch task on the
   session, e.g. `var switchTask: Task<Void, Never>?` on `RouteSession`. Have
   `stopRoute`, `quit()`, and `relinquishDisconnectedHeadphoneOverride()` await
   `switchTask?.value` (or cancel it and await) before calling `probe.stop()`.
2. **Defense in depth — identity revalidation inside the probe.** After every
   `await` in `switchDestination`, re-verify that the probe was not torn down,
   e.g. `guard self.bridge == bridge, self.outputRenderer === outputRenderer,
   isRunning else { throw … }`. The existing callers
   (`switchRoute`'s catch path, the safe-pass-through recovery) already converge a
   thrown error to pass-through, so this converts the use-after-free into a clean
   failure.

### Suggested tests

- A state-machine unit test on `RouteSession`/AppModel-level ordering: assert that a
  stop requested while a switch is in flight is deferred until the switch settles.
- Run `AudioBridgeTests` and a route lifecycle test under Thread Sanitizer.
- Manual matrix: quit / ignore / unplug-override during each of the switch phases
  (ramp-down, renderer stop, replacement prepare, replacement start).

---

## Issue 2 — Automatic routing decisions stop routes that are mid-switch

**Severity:** High
**Affected components:** `AppModel` automatic routing (`commitAutomaticRoute`,
`applyHeadphoneOverride`)

### Locations

- `AudioOrbit/App/AppModel.swift:1224-1230` — `commitAutomaticRoute` stops any
  non-`.running` session
- `AudioOrbit/App/AppModel.swift:1062-1065` — `applyHeadphoneOverride` stops any
  non-`.running` session
- `AudioOrbit/App/AppModel.swift:644-649` — `switchRoute` only accepts
  `.running` sessions

### Description

`switchRoute` sets the session state to `.switching` for the entire duration of
the destination switch. The automatic-routing decision paths above treat every
non-`.running` state as "stale" and call `stopRoute(routeID,
preserveAutomaticMode: true)`. A decision that lands while a switch is in flight
therefore **destroys the route entirely** instead of waiting for the switch to
finish or re-targeting it.

This is easy to hit in normal use:

- A window is moved quickly across two mapped displays. The first move commits a
  switch; a second decision (the 500 ms dwell task or a
  `forceImmediate` refresh from a hardware change) fires during the switch.
- A hardware reconciliation triggered by plugging/unplugging any audio device calls
  `refreshAutomaticWindowEvidence(forceImmediate: true)`
  (`AppModel.swift:808-814`) while a display-follow switch is in flight.

The user-visible result is an audible dropout: the source falls back to the system
default output and the route has to be recreated from scratch on a later tick.
It also widens the reachable window of Issue 1, because the stop path runs
`probe.stop()` while the switch is suspended.

### Root cause

The state machine collapses "switching in flight" into "not running". The decision
code cannot distinguish a route that is actively transitioning from one that is
stale or failed.

### Recommended fix

Treat `.switching` as busy, not stale:

- In `commitAutomaticRoute`: when the session state is `.switching`, re-schedule
  the decision with a short retry delay instead of stopping, mirroring the existing
  control-plane-busy retry at `AppModel.swift:1255-1264`
  (`state.hasCandidate = false` + `scheduleAutomaticRouteDecision(…, force: true,
  requestedDelay: .milliseconds(250))`).
- In `applyHeadphoneOverride`: skip the route for this tick (the next 250 ms poll
  retries) rather than stopping it.
- Keep `switchRoute`'s `.running`-only guard — it is what prevents two
  overlapping switches on the same route today.

### Suggested tests

- Unit tests for the new "busy → retry" decision path in
  `commitAutomaticRoute`/headphone-override handling (the pure decision logic can
  be extracted and tested without Core Audio).
- Manual test: rapidly drag a playing window across three mapped displays and verify
  no route teardown occurs mid-switch (route should settle on the final display).

---

## Issue 3 — Failed tap teardown can leave the source application muted

**Severity:** High
**Affected components:** `ProcessTapProbe` tap lifecycle, `AppModel` route
removal and recovery paths

### Locations

- `AudioOrbit/Platform/CoreAudio/ProcessTapProbe.swift:53` —
  `description.muteBehavior = .mutedWhenTapped`
- `AudioOrbit/Platform/CoreAudio/ProcessTapProbe.swift:212-262` — `tearDown()`
  (collects the first error but continues; the tap destroy is the final step)
- `AudioOrbit/App/AppModel.swift:601-621` — `stopRoute` reports the failure via
  `lastError` and **removes the session from the UI anyway**
- `AudioOrbit/App/AppModel.swift:1465-1492` — `enterSafeRecovery` records
  `session.error` but offers no retry action

### Description

`.mutedWhenTapped` means the tapped process's normal output stays muted for as
long as the tap exists. Tear-down restores normal playback only when the final step,
`AudioHardwareDestroyProcessTap`, succeeds.

`tearDown()` is correctly written to attempt every cleanup step even after an
earlier failure. But if the **tap-destroy call itself** fails:

- `stopRoute` sets `lastError` and continues: the session is removed from
  `sessions`, `routeOrder`, and the published route list. There is no visible
  route, no retry mechanism, and the user has no way to know which app is still
  muted or to trigger another teardown attempt.
- `enterSafeRecovery` keeps the session but marks it `.waitingForDestination`
  with a notice about the *device* — the mute state is misrepresented and there is
  no "retry cleanup" affordance.
- `quit()` swallows the error with `try?`, which is acceptable only because the
  HAL destroys taps of dead clients at process exit.

This is the worst possible failure mode for an audio utility: a silently muted
application and no recovery UI. It is rare (only the final destroy call failing
produces it), but rare × severe is exactly what a safe-pass-through design is meant
to defend against.

### Recommended fix

1. **Never remove a session whose teardown failed.** In `stopRoute`, if
   `probe.stop()` throws, keep the session in a `.failed` state with an error
   like "Normal playback could not be restored. Retrying…" and schedule a retry
   (e.g. re-run `probe.stop()` after 1 s; `tearDown()` is already idempotent and
   safe to re-run because it clears each field as it goes).
2. **Expose a retry action in the route row** for sessions stuck in this state
   (the `ProbeRouteSnapshot` already carries `state` and `error`; a small
   button wired to a retry method is enough).
3. Optionally verify after teardown that the tap no longer exists (query the tap
   object ID or simply rely on the retry loop).

### Suggested tests

- Unit test for the `stopRoute` failure branch: with a probe stub whose `stop()`
  throws, assert the session remains visible in `.failed` state, a retry is
  scheduled, and the route is not removed from the UI.
- Manual test: inject a teardown failure (e.g. a debug-only fault hook in
  `tearDown`) and verify the UI shows the failure with a working Retry button, and
  that a successful retry restores pass-through audio.

---

## Related notes

- Issue 1 is the only crash-class defect among the three; fixing it first also
  shrinks the practical window for Issue 2's trigger.
- All three fixes stay within the existing architecture (no new real-time paths,
  no new Core Audio objects); they only reorder control-plane waits and add a
  failed-state recovery path.
- After the fixes, re-run the expanded 58-test suite and add the suggested
  lifecycle tests; consider enabling `SWIFT_STRICT_CONCURRENCY = complete` and
  Thread Sanitizer for the test action.
