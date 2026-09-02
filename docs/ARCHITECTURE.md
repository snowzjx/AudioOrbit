# AudioOrbit Architecture

**Version:** 0.5.3 (build 27) · **Updated:** 2026-09-02
**Scope:** This is the single architecture document for AudioOrbit. It supersedes ADR-001 and the performance budgets document.

---

## 1. Overview

AudioOrbit is a macOS menu-bar application that routes each application's audio to the output device mapped to the display containing its window. Core chain:

window position (display) ──events / safety-net poll──▶ route decision state machine ──▶ Core Audio process tap ──▶ chosen output device

- **The system default output device is never changed**; each route only affects the tapped process.
- Captured audio passes through bounded, volatile in-memory buffers only — never persisted, never transmitted.
- Every failure converges back to normal playback (pass-through); no source is ever left silently muted.

---

## 2. Layering

AudioOrbit/
├── App/        AppModel (route decision state machine), UpdateManager (Sparkle), status item controller
├── UI/         MenuBarView (popover), FeasibilityLabView (five Settings tabs), Onboarding
├── Domain/     Pure policy layer (side-effect free, unit-testable)
├── Platform/
│   ├── Accessibility/  window evidence discovery + AX event monitor
│   ├── CoreAudio/      device/process discovery and monitors, property helpers
│   ├── Displays/       display discovery + reconfiguration events
│   └── Processes/      window-owner association resolver, LaunchAtLogin
├── Realtime/   process tap probe, C SPSC ring (AudioBridge.c), AUHAL renderer, health analyzer
└── Diagnostics/ bounded diagnostics recorder
AudioOrbitTests/  76 unit tests

**Dependency direction:** UI → App → Domain ← Platform/Realtime. The Domain layer holds pure-function policies (window selection, display assignment, recovery actions, concurrent admission, association rules); all of it is testable offline, and the App layer only orchestrates.

---

## 3. Audio engine (Realtime)

Each route is an isolated RouteSession owning the full tap → bridge → render chain:

1. **Private aggregate device + process tap:** CATapDescription (mutedWhenTapped, process mixdown). The tapped process's original output is suppressed only while the capture is actively consumed.
2. **Active reads:** the aggregate input IO proc pulls tap frames directly (no system forwarding).
3. **C SPSC ring:** a preallocated lock-free single-producer/single-consumer bridge (AudioBridge.c) joins the independently clocked capture and render callbacks.
4. **Per-route AUHAL renderer:** explicitly bound to the selected physical output device.
5. **Format:** Float32 mono/stereo; nominal-rate mismatches use preallocated linear-interpolation conversion.
6. **Clock drift:** proportional queue controller, correction bounded to ±0.5% around a ~43 ms source-frame target. Overflow drops the newest; underflow renders silence and re-primes.
7. **25 ms gain ramp**, plus double rebase on start and destination switches (before renderer start + at the first hardware callback) so external devices never play stale backlog.
8. **Teardown:** reverse-order and idempotent — stop reads and output first, then destroy the aggregate device and tap.
9. Multiple routes targeting one device currently rely on the system output path; a dedicated shared mixer is deferred until same-destination stress evidence justifies it.

---

## 4. Window → display → route decisions

### 4.1 Evidence pipeline

Each evidence refresh produces one WindowDisplayEvidence per playing source:

- **AX windows** (via Accessibility): role, position, size, stable identifier and minimized state of focused/main/standard windows. Safari identifiers are normalized to their UUID segment (stableAXIdentifier) because the IsSecure flag flips during navigation. The normalized AX UUID is preferred over the CG window number because the compositor can replace the latter during an ordinary drag.
- **CG surfaces:** same-PID, on-screen, layer-0, alpha>0 surfaces only, matched to AX windows by largest overlap (≥50%) — stable identities where AX lacks one. Fullscreen fallback accepts only unmatched surfaces that nearly cover one display.
- **WebKit renderer PID:** parsed from BrowserView?IsPageLoaded=…&WebViewProcessID=NNN — the authoritative signal for which window is actually playing. When the audio source is a WebContent process, its own PID seeds this identity before the first window anchor exists.
- **Ordered refresh batches:** AX queries run concurrently, but their results
  carry a generation. If a newer event starts another refresh, the older
  batch is discarded as a whole and cannot overwrite newer route state.
- **Precomputed evidence is direct-process only:** the short startup cache may
  accelerate the same application PID's first route; WebKit helpers never
  borrow it because their playback window can differ from the cached focus.

### 4.2 Window selection and display assignment

**The audio follows the window the video plays in — never focus.** The check runs
only when an event triggers it (AX event, Space change, display
reconfiguration, hardware reconciliation); the poll never re-judges.

- Selection order:
  1. **Fullscreen presentation** — a window reporting `AXFullScreen=true`
     (WebKit video fullscreen presents as an AXDialog at the fullscreen
     display's frame; the attribute lives on that dialog, not the browser
     window). It remains authoritative until the attribute clears or the
     presentation disappears. A matching renderer wins; a single unlabelled
     presentation may cover WebKit's temporary handoff. With exactly one
     relevant source for that Safari owner, one mismatched handoff dialog may
     also drive fullscreen; multi-source owners and multiple ambiguous
     presentations retain the established window/output.
  2. **Renderer-PID anchor window** — the window reporting the anchored
     WebViewProcessID, i.e. the window the video actually plays in.
  3. **Focus → main → largest visible** fallback.
- Display assignment: largest intersection area between the window frame
  and each display frame, deterministic tie-breaking, boundary hysteresis.
- **Surfaces never anchor:** one unmatched, near-fullscreen pure surface may
  drive the DISPLAY while the anchor is gone, but can never become the anchor.
  Surfaces resolving to multiple displays are ambiguous and keep the old route.
- The committed display change goes through the route-side debounce queue
  (§5.4): rapid A-B-A-B alternation is absorbed at the sink.

### 4.3 Anchor state machine (AppModel)

The anchor remembers **which window the video plays in**. It is the pair
**(renderer PID, current reporter window)** with exactly one writer in the
decision path (scheduleAutomaticRouteDecision); every other path may only
read it.

- **Sticky renderer PID:** seeded once at first adoption from the window
  selection picked at playback start, provided that window reports a
  renderer PID (WebViewProcessID). It is never overwritten afterwards —
  not by focus and not by the anchor window's own renderer. (The pre-0.5
  re-adoption block did overwrite it and polluted the anchor with the
  focused non-playing window's PID after fullscreen exit.)
- **Reporter re-pin:** every evidence refresh the anchor window re-pins to whichever
  window currently reports the anchored PID. A torn-off tab keeps its
  renderer, so the new window becomes the anchor; churn windows that
  transiently report the PID merely flip the display candidate, which the
  route-side debounce absorbs. If Safari transiently reports the same PID
  from multiple windows, the current reporter remains authoritative until it
  disappears; dictionary iteration order must never oscillate the anchor.
- **Same-pass renderer recovery:** non-fullscreen selection resolves the
  renderer before falling back to the old window identifier, so a drag or
  tab tear-off follows the new reporter immediately instead of waiting for a
  second AX event.
- **Long-gap release:** only when the anchored PID stays unreported for six
  seconds of monotonic time are the PID, the anchor window and the manual
  override cleared together. AX event bursts cannot accelerate this timeout.
- **Session boundaries do NOT release:** a stopped→running output
  transition records `playback-session-kept` and preserves the anchor;
  helper restarts, fullscreen churn and pause/resume are not new playback
  sessions.
- **Helper migration re-keys the whole state:** route ID, session source,
  renderer anchor, committed window/display and pending decision move together
  whether the old helper vanished or merely became silent.
- **Manual pin:** the user-pinned window suppresses automatic following
  until the long-gap release clears the override.
- Adoption updates the anchor only; the display consequence flows through
  the route-side debounce like every other change.
- **Helper-restart migration:** each vanished PID has one cancellable grace
  coordinator. Replacement selection ranks renderer PID and helper identity;
  equal best candidates are rejected so another Safari playback cannot capture
  the route.

### 4.4 Process ↔ window association

Four association paths: same process, regular parent chain (≤8 levels), unique exact bundle match, and system WebKit helpers (`com.apple.WebKit.GPU` and `com.apple.WebKit.WebContent`) whose executable resolves inside the system WebKit framework and whose name has a longest-unique application prefix. Ambiguous or unverifiable helpers stay pass-through.

---

## 5. Event-driven architecture (core update)

### 5.1 Event sources

| Event source | Notification | Handling |
|---|---|---|
| AudioDeviceMonitor | kAudioHardwarePropertyDevices list changes; per-route destination DeviceIsAlive | 100 ms coalescing → hardware reconciliation |
| AudioProcessActivityMonitor | **kAudioHardwarePropertyProcessObjectList changes** (a process establishing/tearing down its audio connection = playback start/stop/process churn) | 100 ms coalescing → reconciliation → evidence refresh |
| AccessibilityWindowEventMonitor | AXObserver: created / focused / main on the application element; moved / resized **on every AX window element** (AppKit forwards window notifications to app observers, Safari does not — per-window registration catches both). One AXObserver **per observed application** (`AXObserverCreate` takes the OBSERVED app's PID — a single getpid() observer silently failed with kAXErrorIllegalArgument and the app received no events for months). Window list re-synced on created events and every 2 s | **150 ms debounce** → selection check |
| DisplayMonitor | CGDisplayRegisterReconfigurationCallback (display attach/detach/topology) | immediate evidence refresh |
| NSWorkspace | **activeSpaceDidChangeNotification** (Space switches, fullscreen Spaces, Mission Control clicks — window frames do not move, so no AX event fires). A **trigger, not a judgment**: re-enumerate the tracked windows and run the selection check; the debounce absorbs the transition animation | window resync + selection check |
| NSApplication.didBecomeActive | app activation | re-check accessibility permission |
| CoreAudio process tap callbacks | per-route audio flow | health/clock analysis (real-time path: no allocation, no locks) |
| Sparkle delegate | appcast loaded / update found / aborted | About-page status |

**Empirically calibrated:** the process-list property is notifying (afplay appearing/disappearing fires immediately), while the per-process kAudioProcessPropertyIsRunningOutput property is NOT notifying (its value changes but no notification fires) — so the process monitor listens only on the system table and re-reads the whole snapshot when the event arrives.

### 5.2 Remaining polling (honest inventory)

Not zero-polling. Exactly three polling loops remain, all deliberate:

| Loop | Cadence | Why it must stay |
|---|---|---|
| **Observation loop** (ensureWindowObservation) | 250 ms while routes are active or sources are playing; 2 s otherwise | Maintains the display snapshot and accessibility check. Hardware reconciliation every 4/8 ticks also provides a 1–2 s window-evidence safety net for AX notifications Safari omits |
| Per-route health metrics | 1 s (only while a route runs) | buffer queue / clock drift monitoring; silence-suspend and silent-source migration counters |
| Gain-ramp completion wait | 2 ms (single shot, ≤250 ms, only during route start/stop) | transient startup/switch wait |

Every other Task.sleep is a one-shot timer (100 ms hardware coalescing, 150 ms AX debounce, follow-up reconcile series, vanish grace retries, commit retry) — timing, not polling. Sparkle's own scheduled background checks (daily by default) are third-party.

### 5.3 Energy budget and implementation

- Measured idle CPU **≈0%** (8–13% before optimization).
- Techniques: menu-bar icon update dedup (no per-tick re-render), adaptive tick cadence, 1 s TTL display snapshots with event-driven instant refresh, hardware reconciliation slowed to every 8 ticks while no routes exist, AX frames read once per window, and no per-event/per-window observer logging.
- The idle interval is the trade-off between new playback being picked up within ~2 s and wakeup count; playback start itself is already event-driven, so the poll is only the safety net.

### 5.4 Decision and commit: route-side debounce queue

**Upstream never filters.** Every event (moved, focused, created, destroyed,
Space change, process-table event) feeds the decision path unconditionally —
there are no gates, no suppression windows, no event-type discrimination.

**The route side absorbs flapping.** Each committed candidate display change
goes through a per-source queue with a trailing debounce:

- Every candidate change restarts a **500 ms timer**; the actual device
  switch fires only after the target display has held steady. Rapid
  A-B-A-B alternation (fullscreen churn, Space-swipe animation frames,
  Mission Control scaling) is absorbed at the sink.
- **First routes and forced decisions commit immediately** (zero delay).
- **A nil candidate never stops a route** — in every session state the
  established route is kept. An explicit System Default/pass-through mapping
  is a terminal user choice rather than missing evidence, so it safely tears
  down an existing route and restores normal macOS playback.
- **Transient target-resolution failure retries once after 500 ms** — after
  a drag ends no further events arrive, so a dropped commit would leave the
  drag permanently unfollowed.
- **Destination switching retries at most twice** (1 s, then 2 s). After the
  bound is reached the same candidate stays suppressed until the target
  changes or an explicit forced refresh occurs, preventing an error loop.
- Anchor adoption no longer bypasses the queue: adoption updates the anchor
  only, and the display consequence flows through the debounce like every
  other change.

Remaining time-based values (the complete list):

| Value | Purpose |
|---|---|
| 500 ms debounce | absorb rapid alternation at the sink |
| 1 s / 2 s switch retry | retry a transient device rebind without looping forever |
| 300/600/900/1500/2500/4000 ms follow-ups | detect launch-then-play output after the process-table event |
| 300/700/1500/3000 ms vanish grace | find a same-owner replacement before tearing a route down |
| 3 s / 5 s silence migration | move the route when the tap goes silent but a same-owner process plays (Safari swaps its media helper on fullscreen) |
| 60 s silence suspend | tear down silent routes so the Mac can sleep (anchor and destination retained) |
| 2-tick session silence | pause/resume boundary detection (anchor kept — diagnostic only) |
| 6 s monotonic anchor long-gap | renderer unreported ⇒ anchor release (closed tab) |


## 6. Key data flows

playback starts:  process-table event → follow-up reconciles (300/600/900/1500/2500/4000 ms) → playback detected → selection check → first route (immediate)
window dragged across displays:  AX moved (drag end) → selection check → candidate display change → 500 ms debounce → route migration (validate target → fade out → rebind → fade in)
tab torn out:  AX created → debounce → the new window reports the same WebViewProcessID → anchor re-pins to the new reporter → display follows through the debounce
fullscreen enter/exit:  Space change + AX window churn → selection check picks the AXFullScreen presentation (enter) or the anchor window (exit) → debounced commit; churn's transient windows cannot steal the anchor
Mission Control / Space swipe:  no judgment — the selection check runs on the Space-change trigger, and the 500 ms debounce absorbs the animation frames
window closed:  route stays on its display until the source process ends (vanish grace → migration → stop) or 60 s silence suspend
pause/resume:  process-table event → reconciliation → anchor is kept (`playback-session-kept`); only the 6 s monotonic long-gap rule releases it
helper restart:  process-table event → one vanish coordinator (300/700/1500/3000 ms) → unambiguous identity-ranked replacement migration
silent tap with a playing same-owner process:  route metrics → 3 s silence + every 5 s → silent-source migration

---

## 7. Persistence, permissions, diagnostics

- **Persistence:** MappingStore (versioned JSON: display mappings, remembered routes, ignored apps, headphone override; corrupt-file recovery). UserDefaults: follow-notification toggle, onboarding state. LaunchAtLogin via the system login items.
- **Permissions:**
  - **Accessibility:** required (window positions, Safari renderer-PID association, AX events). Note: **TCC grants follow the code signature — re-signing/reinstalling resets them.** Use Xcode Debug runs for day-to-day development; re-sign only for releases.
  - **Audio capture:** required by the process tap (NSAudioCaptureUsageDescription).
  - **Notifications:** optional, requested on demand for follow notifications.
- **Diagnostics:** bounded in-memory DiagnosticsRecorder (redacted — window
  titles, window identifiers, process IDs, device/display identities and web
  content are never recorded). Routine lifecycle activity stays in this
  bounded buffer and appears only in a user-generated support report; it is
  not persisted to the macOS unified log. The unified log receives only
  anonymous warning/error codes. Accessibility observers never log events,
  window membership, frames, titles or registration targets. Performance
  signposts contain fixed labels only (Hardware refresh / Route transition).

---

## 8. Updates and distribution

- **Sparkle 2.9.5** (SPM): SUFeedURL → the GitHub appcast tag asset; the EdDSA private key lives in the keychain (account ed25519) and the public key is embedded as SUPublicEDKey in Info.plist.
- **CI (triggered by v* tags):** test → archive (Developer ID) → re-sign Sparkle's nested components (Updater.app / Autoupdate / Downloader.xpc / Installer.xpc) → notarize + staple → zip → generate appcast upload → create Release.
- appcast generation notes: the input is a **directory** of archives (not a zip path); --download-url-prefix must end with / (otherwise the last path segment is replaced by the filename); sparkle:edSignature is only emitted when the archive's Info.plist declares SUPublicEDKey.
- Update UI for menu-bar apps: an LSUIElement app must temporarily switch to the .regular activation policy or Sparkle's windows never appear.

---

## 9. Performance budgets (release gates)

| Scenario | Budget on reference Apple-silicon hardware |
|---|---|
| Disabled, no routes | <1% average CPU, no high-frequency polling |
| Two routes / two outputs | <6% average app CPU |
| Four routes / mixed rates | <12% average app CPU |
| One-hour four-route run | <20 MB resident growth after warm-up |
| Real-time callbacks | no deadline misses from allocation/locks/logging/UI |
| Added wired latency | <100 ms end to end |
| Steady underflow/overflow | none recurring after the 3 s warm-up |
| Drift | queue stays bounded over a 30-minute mixed-rate run |

Bluetooth latency is reported separately (codec and radio buffering are outside our control). Measure with Instruments (Time Profiler / System Trace / Allocations / Audio); estimated-buffer-latency in the support report is for regression comparison only, not a loopback substitute. **Never attach captured audio to a support report.**

---

## 10. Testing strategy

- The Domain policy layer is pure functions covered by 76 unit tests (window selection, display assignment, recovery actions, concurrent admission, session boundaries, health analysis, error formatting).
- The real-time path is not unit-tested; it is gated by the performance budget table and a manual matrix (clicks, duplicated audio, pass-through recovery).
- Local testing note: when the repository sits inside an iCloud-synced location, the file provider stamps build products with com.apple.FinderInfo/provenance, which breaks the test bundle's ad-hoc codesigning. **Run tests with DerivedData under /tmp** (matching the clean CI environment).

---

## 11. Known limitations

- Multiple windows of one helper (e.g. Safari) cannot route to different outputs simultaneously — one renderer, one destination.
- No .pkg-style updates; Bluetooth output latency is subject to system codec behavior.
- Representative window-discovery validation for Electron and other app families is still pending (see PROJECT_SPEC's unchecked items).
- AX notifications are unreliable for some apps/scenarios, so the polling safety net cannot be removed (see §5.2).
