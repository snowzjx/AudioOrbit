# AudioOrbit Architecture

**Version:** 0.3.11 (build 15) · **Updated:** 2026-08-17
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
AudioOrbitTests/  60 unit tests

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

- **AX windows** (via Accessibility): role, position, size, stable identifier and minimized state of focused/main/standard windows. Safari identifiers are normalized to their UUID segment (stableAXIdentifier) because the IsSecure flag flips during navigation.
- **CG surfaces:** same-PID, on-screen, layer-0, alpha>0 surfaces only, matched to AX windows by largest overlap (≥50%) — stable identities where AX lacks one.
- **Media indicator:** a uniquely matching playback marker in window chrome (mute/speaker/playing/audio and common CJK variants; depth ≤6; titles and web content are never read) can override focus selection.
- **WebKit renderer PID:** parsed from BrowserView?IsPageLoaded=…&WebViewProcessID=NNN — the authoritative signal for which window is actually playing.

### 4.2 Window selection and display assignment

- Selection order: **route anchor > unique media-indicator window > focused window > main window > largest visible window**.
- Display assignment: largest intersection area between the window frame and each display frame, deterministic tie-breaking, boundary hysteresis.

### 4.3 Anchor state machine (AppModel)

- **Renderer PID first:** once anchored, the window reporting the anchored renderer PID is the playback window; focus changes never replace the anchor; moving the anchored window across displays migrates the route.
- **Session boundary:** a stopped→running output transition is a new playback session (anchor released for re-selection), but the release is verified against renderer identity — pausing/resuming the same tab keeps the anchor (pendingSessionRelease), only a genuinely new renderer releases it.
- **Time constants:** candidate dwell 3 ticks; temporarily missing anchor tolerance 6 ticks; staleness re-pin at 16 ticks; fullscreen/Space transitions keep the last output (anchorIsTemporarilyInvisible).
- **Helper-restart migration:** when a WebKit helper vanishes and a same-owner replacement exists, the route migrates to the replacement instead of falling back.

### 4.4 Process ↔ window association

Four association paths: same process, regular parent chain (≤8 levels), unique exact bundle match, and the system WebKit helpers (com.apple.WebKit.GPU and com.apple.WebKit.WebContent via longest-unique application-name prefix, with Apple-signed identity as fallback). Ambiguous helpers stay pass-through.

---

## 5. Event-driven architecture (core update)

### 5.1 Event sources

| Event source | Notification | Handling |
|---|---|---|
| AudioDeviceMonitor | kAudioHardwarePropertyDevices list changes; per-route destination DeviceIsAlive | 100 ms coalescing → hardware reconciliation |
| AudioProcessActivityMonitor | **kAudioHardwarePropertyProcessObjectList changes** (a process establishing/tearing down its audio connection = playback start/stop/process churn) | 100 ms coalescing → reconciliation → evidence refresh |
| AccessibilityWindowEventMonitor | AXObserver: window moved / resized / created / destroyed / focused / main (registered for the tracked window-owner PID set) | **150 ms debounce** → evidence refresh |
| DisplayMonitor | CGDisplayRegisterReconfigurationCallback (display attach/detach/topology) | immediate evidence refresh |
| NSApplication.didBecomeActive | app activation | re-check accessibility permission |
| CoreAudio process tap callbacks | per-route audio flow | health/clock analysis (real-time path: no allocation, no locks) |
| Sparkle delegate | appcast loaded / update found / aborted | About-page status |

**Empirically calibrated:** the process-list property is notifying (afplay appearing/disappearing fires immediately), while the per-process kAudioProcessPropertyIsRunningOutput property is NOT notifying (its value changes but no notification fires) — so the process monitor listens only on the system table and re-reads the whole snapshot when the event arrives.

### 5.2 Remaining polling (honest inventory)

Not zero-polling. Exactly three polling loops remain, all deliberate:

| Loop | Cadence | Why it must stay |
|---|---|---|
| **Observation loop** (ensureWindowObservation) | 250 ms while routes are active or sources are playing; 2 s otherwise | **Safety net:** ① dragging a tab into an existing window emits no AX event at all; ② some apps never emit window notifications; ③ fullscreen/Space edge cases. The 250 ms active cadence preserves drag-following feel |
| Per-route health metrics | 1 s (only while a route runs) | buffer queue / clock drift monitoring |
| Gain-ramp completion wait | 2 ms (single shot, ≤250 ms, only during route start/stop) | transient startup/switch wait |

Every other Task.sleep is a one-shot timer (100 ms hardware coalescing, 150 ms AX debounce, reconnect dwell, cleanup retry) — timing, not polling. Sparkle's own scheduled background checks (daily by default) are third-party.

### 5.3 Energy budget and implementation

- Measured idle CPU **≈0%** (8–13% before optimization).
- Techniques: menu-bar icon update dedup (no per-tick re-render), adaptive tick cadence, 1 s TTL display snapshots with event-driven instant refresh, hardware reconciliation slowed to every 8 ticks while no routes exist.
- The idle interval is the trade-off between new playback being picked up within ~2 s and wakeup count; playback start itself is already event-driven, so the poll is only the safety net.

---

## 6. Key data flows

playback starts:  process-table event → 100 ms coalesce → hardware reconciliation (full snapshot) → evidence refresh → 3-tick dwell → route creation
window crosses displays:  AX moved → 150 ms debounce → evidence refresh → display assignment change → route migration (validate target → fade out → rebind → fade in)
tab torn out:  AX created → debounce → new window + same WebViewProcessID → anchor follows the new window
tab dragged into existing window:  no event exists → 2 s safety-net poll → PID↔window mapping recomputed
pause/resume:  process-table event → reconciliation → renderer identity check (same renderer keeps the anchor / new renderer releases and re-selects)
helper restart:  process-table event → vanished-source detection → migration to the same-owner replacement

---

## 7. Persistence, permissions, diagnostics

- **Persistence:** MappingStore (versioned JSON: display mappings, remembered routes, ignored apps, headphone override; corrupt-file recovery). UserDefaults: follow-notification toggle, onboarding state. LaunchAtLogin via the system login items.
- **Permissions:**
  - **Accessibility:** required (window positions, Safari renderer-PID association, AX events). Note: **TCC grants follow the code signature — re-signing/reinstalling resets them.** Use Xcode Debug runs for day-to-day development; re-sign only for releases.
  - **Audio capture:** required by the process tap (NSAudioCaptureUsageDescription).
  - **Notifications:** optional, requested on demand for follow notifications.
- **Diagnostics:** bounded ring DiagnosticsRecorder (redacted — window titles and web content are never recorded). The support report includes process CPU, memory and per-route buffer counters; the me.snowzjx.AudioOrbit subsystem emits signposts (Hardware refresh / Route transition).

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

- The Domain policy layer is pure functions covered by 60 unit tests (window selection, display assignment, recovery actions, concurrent admission, session boundaries, health analysis, error formatting).
- The real-time path is not unit-tested; it is gated by the performance budget table and a manual matrix (clicks, duplicated audio, pass-through recovery).
- Local testing note: when the repository sits inside an iCloud-synced location, the file provider stamps build products with com.apple.FinderInfo/provenance, which breaks the test bundle's ad-hoc codesigning. **Run tests with DerivedData under /tmp** (matching the clean CI environment).

---

## 11. Known limitations

- Multiple windows of one helper (e.g. Safari) cannot route to different outputs simultaneously — one renderer, one destination.
- No .pkg-style updates; Bluetooth output latency is subject to system codec behavior.
- Representative window-discovery validation for Electron and other app families is still pending (see PROJECT_SPEC's unchecked items).
- AX notifications are unreliable for some apps/scenarios, so the polling safety net cannot be removed (see §5.2).

