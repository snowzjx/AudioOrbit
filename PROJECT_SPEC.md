# AudioOrbit — Project Specification

**Document status:** Living product and implementation specification — integrated MVP, hardening in progress
**Target:** Native macOS menu-bar application
**Minimum OS:** macOS 14.2
**Primary language/UI:** Swift and SwiftUI, with Core Audio interop where required
**Last updated:** 2026-08-13

## 1. Product summary

AudioOrbit routes each application's audio to the output device mapped to the display that contains that application's active or primary window.

Example:

- A browser's active window is on the Studio Display, which is mapped to Studio Display Speakers.
- A music player's active window is on a television, which is mapped to the HDMI output.
- Both applications play simultaneously through their respective mapped devices.

### Mandatory v1 boundary

> **AudioOrbit v1 routes per application/process, not per individual window.** If one process owns multiple windows on different displays, all audio emitted by that process is routed together using the process's selected active/primary window. AudioOrbit must not claim or attempt to route two windows from the same process to different devices.

On macOS there is no public one-call API that sets an arbitrary output device for another application. AudioOrbit uses a Core Audio process tap to capture and suppress a process's normal output, then explicitly renders that audio to the selected hardware output. The current bridge is accepted for the integrated MVP in ADR-001; long-run, latency and distribution evidence remain release gates.

## 2. Product goal

Create a reliable, low-friction utility that makes an application's sound appear to follow its window between displays while allowing different applications to use different outputs at the same time.

The MVP succeeds when a user can:

- Grant the required permissions through a guided flow.
- Map each connected display to an available audio output device.
- Enable routing globally.
- Play audio from two independent applications on two displays through two distinct output devices simultaneously.
- Move one application's active/primary window to another display and hear its audio transfer after a short, stable delay.
- Understand and recover from missing permissions, disconnected displays, and unavailable audio devices.

## 3. Non-goals

The following are explicitly outside v1:

- Per-window routing for two windows owned by the same process.
- Per-tab, per-document, per-audio-stream, or per-browser-tab routing.
- Input-device or microphone routing.
- Audio effects, equalization, spatial processing, software per-route gain, volume normalization, recording, or exporting captured audio. Public physical-device volume control is supported where the device exposes it.
- Network audio, AirPlay orchestration, or synchronized multi-room playback.
- Combining multiple output devices into one user-visible route.
- Supporting iOS, iPadOS, Windows, or Linux.
- Managing the macOS default output device as the primary routing mechanism.
- Using private frameworks, kernel extensions, or undocumented APIs.
- Installing a custom virtual audio driver unless a separately approved post-spike architecture requires one.
- Guaranteed routing for protected/DRM audio or processes that the public tap APIs cannot capture.
- Per-application fixed-output overrides. Remembered route identity and the global Headphone Override policy do not replace display-to-output mapping as the normal route decision.

## 4. Definitions

- **Process:** A running macOS process identified at runtime by PID and, where available, persistently by bundle identifier.
- **Process audio object:** Core Audio's representation of a process connected to the Hardware Abstraction Layer (HAL).
- **Tracked window:** A normal, user-facing window considered by the window-selection policy.
- **Selected window:** The focused, main, or fallback primary window that determines a process's display.
- **Candidate display:** The display derived from the latest stable selected-window geometry.
- **Committed display:** The display currently used for routing after debounce and hysteresis.
- **Mapped device:** The output audio device assigned to a display.
- **Route:** The relationship `process -> selected window -> display -> audio device`.
- **Pass-through:** The process uses its normal macOS output path because AudioOrbit is disabled, lacks permission, or has no usable mapped destination.
- **Tap:** A Core Audio process tap created with `CATapDescription`.

## 5. Platform and engineering constraints

- Set the deployment target to macOS 14.2 or later because Core Audio process taps require macOS 14.2+.
- Build a native menu-bar utility using public Apple APIs.
- Do not change the system-wide default output device to simulate per-process routing.
- Never perform allocation, locking, logging, file I/O, Swift actor hops, or other unbounded work on a real-time audio callback.
- Use stable identifiers for persistence:
  - Display: `CGDisplayCreateUUIDFromDisplayID` UUID, with descriptive metadata only as a recovery aid.
  - Audio device: Core Audio device UID from `kAudioDevicePropertyDeviceUID`.
  - Application: bundle identifier; PID is runtime-only.
- Expect `AudioObjectID`, `CGDirectDisplayID`, and PID values to change between launches or reconnects.
- Treat output devices as independently clocked. The bridge must tolerate sample-rate mismatch and drift rather than assuming identical clocks.
- Never capture, persist, transmit, or analyze audio content beyond the in-memory buffers required to route it.
- Debug builds may use a stable local designated requirement for TCC continuity. Developer ID, App Sandbox, hardened runtime, notarization, update behavior and the intended distribution path must be validated before release.

## 6. MVP scope

### Required

- [x] Menu-bar app with routing on/off control and status.
- [ ] First-run onboarding for Accessibility and System Audio Recording permission.
- [x] Enumeration of connected displays and eligible output audio devices.
- [x] Persistent display-to-device mapping.
- [x] Window observation and deterministic selected-window/display resolution.
- [x] Per-process audio capture, suppression of the original path, and rendering to the mapped output.
- [x] Concurrent routing of at least two independent audio-producing processes to two distinct devices.
- [x] Debounced rerouting when the selected window changes display.
- [x] Safe fallback when the destination device or display disappears.
- [ ] Diagnostics view and exportable text report containing metadata and events, never audio.
- [ ] Unit, integration, and manual hardware tests.

### Implemented product extensions

- [x] Remember application routes by bundle identifier until the user deletes them.
- [x] Physical-device volume controls for outputs with a writable public Core Audio scalar.
- [x] User-selected Headphone Override with automatic display-route restoration on disconnect.
- [x] Conservative Safari/WebKit helper association and established-route retention through full-screen transitions.
- [x] Layered Icon Composer app icon with Default, Dark and Mono appearances and generated legacy-macOS artwork.

### Optional only after required behavior is stable

- [ ] Launch at login.
- [ ] Per-application exclude/pass-through list.
- [ ] Configurable debounce duration in an Advanced settings section.
- [x] Menu-bar display of live and remembered routes with application icons.

## 7. User experience

### 7.1 First launch target

The dedicated onboarding flow is the next product milestone. Until it is implemented, permission remediation and mapping are available in Settings.

1. Explain the product in one sentence and show a short route example.
2. Request Accessibility permission using a user-initiated action. Explain that it is used only to read window focus, position, and size.
3. Request System Audio Recording permission by starting the minimum process-tap operation required to trigger the system prompt. Explain that audio remains on the Mac and is not recorded to disk.
4. Recheck permission status when the app becomes active; do not imply that opening System Settings granted permission.
5. Enumerate displays and outputs.
6. Require the user to select an output for every display they want AudioOrbit to manage. Offer **System Default (pass-through)** as the safe initial choice, not as a per-process routed destination.
7. Run an optional test tone on a selected destination. The test tone is generated by AudioOrbit and must not require a process tap.
8. Enable routing only after at least one valid display-to-device mapping exists and the required permissions are confirmed.

### 7.2 Normal operation

The menu-bar icon communicates global state:

- **Active:** at least one process is routed.
- **Idle:** routing is enabled but no eligible process is currently producing audio.
- **Paused:** routing is disabled by the user.
- **Needs attention:** permission, device, or engine failure needs action.

The menu-bar popover shows:

- Explicit global **Enable/Disable** control.
- Current and remembered routes, formatted as `Application -> Display -> Output`, with application icons.
- A concise reason for any degraded route.
- Physical-output volume sliders when supported by the device.
- A SwiftUI `SettingsLink` and a button-styled **Quit AudioOrbit** action.

Right-clicking the status item exposes quick Enable/Disable and Quit actions without displaying a checkbox tick.

### 7.3 Moving a window

- Continue rendering to the committed destination while the window crosses a display boundary.
- Commit a new route only after the candidate satisfies the debounce/hysteresis rules.
- On commit, transfer using the accepted sequential 25 ms fade-out, renderer rebind, fresh priming and fade-in sequence. Avoid clicks and sustained playback on both destinations.
- If the user drags back before the dwell timer expires, cancel the candidate and keep the existing route.

### 7.4 Multiple windows in one process

Choose exactly one window per process using the policy in Section 10. All of the process's audio follows that one window. Surface this limitation in Help and onboarding; do not present independent window routes in the UI.

## 8. High-level architecture

```text
AppKit / Accessibility                 Core Audio HAL
          |                                  |
          v                                  v
   WindowTracker                      ProcessAudioMonitor
          |                                  |
          +--------------+-------------------+
                         v
                    AppModel / route policy
                  /          |           \
                 v           v            v
         DisplayDiscovery  MappingStore  ProcessTapProbe
                                             |       |
                                       process tap   |
                                       + C SPSC bridge
                                       + resampler   |
                                                     v
                                           per-route AUHAL
                                                     |
                                                     v
                                             output device
                         |
                         v
       AppKit status item + SwiftUI popover / Settings
```

### Ownership rules

- `AppModel` is the current sole owner of route decisions, session coordination and user-visible snapshots.
- Each `ProcessTapProbe` owns its tap, private aggregate device, IO procedure, converter/bridge state and physical-output renderer.
- `AudioBridge.c` owns the allocation-free real-time queue, gain and adaptive-rate data plane; Swift control code never runs inside its callbacks.
- UI reads immutable snapshots and sends commands; it does not manipulate HAL objects directly.
- Persistence stores user intent, not transient runtime identifiers or live engine state.
- `AppModel` is main-actor isolated; the real-time data plane is isolated from Swift concurrency.

## 9. Module breakdown

The names below describe logical responsibilities. Current concrete types include `AppModel`, `AudioDiscovery`, `DisplayDiscovery`, `AccessibilityWindowDiscovery`, `ProcessWindowAssociationResolver`, `ProcessTapProbe`, `PhysicalOutputRenderer`, `MappingStore`, and the C `AudioBridge`.

### `AppShell`

- Defines the SwiftUI `App` and `Settings` scene plus an AppKit `NSStatusItem`/`NSPopover` shell for distinct left- and right-click behavior.
- Owns top-level `AppState` snapshots for UI presentation.
- Uses `LSUIElement` behavior at launch, temporarily adopts regular-app activation while the Settings window is open so its app icon appears in the Dock, and returns to accessory activation when that window closes.

### `PermissionManager`

- Checks Accessibility trust with `AXIsProcessTrustedWithOptions`.
- Drives the user-initiated system-audio permission prompt through a minimal tap test.
- Publishes `unknown`, `notDetermined`, `denied`, and `granted`-style product states even if the underlying APIs expose different details.
- Provides deep-link/open-System-Settings actions where public APIs permit.
- Never polls aggressively or treats prompt display as success.

### `DisplayManager`

- Enumerates online, active displays using Core Graphics and correlates them with `NSScreen`.
- Publishes display UUID, current `CGDirectDisplayID`, name, frame, scale, built-in/external state, and connection state.
- Observes display reconfiguration and invalidates geometry immediately.
- Resolves a window rectangle to a display using Section 10.

### `WindowTracker`

- Uses the macOS Accessibility API for focused/main window and window attributes.
- Registers `AXObserver` notifications for focused-window changes, window movement, resizing, creation, destruction, and minimization when supported by the target application.
- Uses bounded periodic reconciliation because Accessibility notifications are not perfectly uniform across applications.
- Uses `CGWindowListCopyWindowInfo` only for correlation/fallback metadata when necessary; it is comparatively expensive and must not be the high-frequency primary loop.
- Normalizes Accessibility and Core Graphics coordinate systems in one tested utility.
- Filters out AudioOrbit, hidden apps, minimized windows, off-screen/zero-area windows, desktop elements, transient menus, sheets/panels where identifiable, and nonstandard windows that cannot produce a meaningful route.

### `AudioDeviceManager`

- Enumerates output-capable devices from the HAL.
- Publishes UID, current object ID, display name, transport type, channel count, nominal/available sample rates, alive/running state, and whether it is the current default.
- Observes device-list, alive-state, sample-rate, and default-device changes through Core Audio property listeners.
- Resolves a persisted device UID to the current `AudioObjectID`.
- Excludes input-only and unusable devices.
- Reads and writes the public physical-output volume scalar when the device reports that property as writable.

### `ProcessAudioMonitor`

- Observes HAL audio-process objects and maps them to PID and bundle identifier.
- Uses `AudioHardwareSystem.process(for:)` or `kAudioHardwarePropertyTranslatePIDToProcessObject` as appropriate for the installed SDK.
- Publishes whether a process is running output audio.
- Handles the race where an app exists before its HAL process object appears, or its HAL object disappears before the app terminates.

### `MappingStore`

- Stores display UUID to audio-device UID mappings and user settings.
- Validates references against current hardware without deleting temporarily unavailable mappings.
- Performs versioned, atomic migrations.

### `RoutingCoordinator`

- Joins window, display, process-audio, mapping, permission, and device snapshots.
- Applies candidate selection, debounce, hysteresis, fallback, and state transitions.
- Issues idempotent `start`, `switch`, and `stop` commands to the audio engine.
- Coalesces redundant events and prevents stale asynchronous work from overwriting newer route intent by attaching a monotonically increasing route generation.

### `AudioRoutingEngine`

- Creates and destroys process taps and private aggregate devices.
- Reads tapped audio, performs channel mapping/sample-rate conversion as required, and renders to physical outputs.
- Maintains bounded lock-free or real-time-safe ring buffers between independently clocked capture and output callbacks.
- Uses isolated per-route AUHAL renderers today. A shared per-device mixer remains a possible hardening change after same-destination stress tests.
- Applies gain ramps during start, stop, and switch.
- Publishes control-plane health metrics without logging in callbacks.
- Guarantees teardown restores normal process output behavior.

### `DiagnosticsCenter`

- Receives structured events and sampled counters from all modules.
- Uses `OSLog` categories and signposts outside the real-time callback.
- Produces a redacted support report.

This logical component is not implemented yet. Current health metrics are internal and covered by tests; raw feasibility counters are intentionally not exposed to end users.

## 10. Window and display selection policy

### 10.1 Selected window for a process

Evaluate in this order:

1. The process's focused window, if eligible.
2. The process's main window, if eligible.
3. The eligible normal window with the greatest visible area on all active displays; break ties by front-to-back window order, then stable window identifier.
4. If no eligible window exists, retain the last valid selected window/display for a grace period of 1 second.
5. After the grace period, stop AudioOrbit routing for that process and return it to pass-through.

An eligible window must:

- Belong to the process.
- Be visible, not minimized, and have nonzero bounds.
- Intersect an active display by a meaningful area.
- Represent a normal app surface rather than a menu, tooltip, popover, desktop element, or transient system surface where role/subrole data makes that distinction possible.

### 10.2 Display for a selected window

1. Intersect the window frame with every active display frame.
2. Select the display with the largest intersection area.
3. If areas tie, prefer the currently committed display.
4. If still tied, prefer the display containing the window center.
5. If still tied, use the stable lexical order of display UUIDs.

Use full display `frame`, not `visibleFrame`, when deciding which display contains a window. Menu-bar and Dock occupancy must not change routing geometry.

### 10.3 Full-screen, Spaces, hidden, and minimized behavior

- Observe active Space changes and reconcile all tracked processes.
- A full-screen window follows the display containing its full-screen surface.
- A hidden or minimized application's route enters the 1-second grace period, then pass-through unless another eligible window from that process is selected.
- Do not route solely from stale windows on another Space unless Accessibility reports them as the selected eligible window and geometry can be validated.

## 11. Display-to-audio-device mapping

### Mapping model

```swift
struct DisplayAudioMapping: Codable, Equatable {
    let displayUUID: UUID
    var displayNameHint: String
    var audioDeviceUID: String?
    var audioDeviceNameHint: String?
    var behavior: Behavior // .routeToDevice or .passThrough
}
```

Rules:

- A display may map to exactly one output device.
- Multiple displays may map to the same output device.
- `audioDeviceUID == nil` is valid only for `.passThrough`.
- Mapping to **System Default** means pass-through in v1. It must not create a tap that simply chases the mutable default device.
- Preserve a mapping when its display or device is disconnected; show it as unavailable and reactivate it when the same stable UID returns.
- If macOS cannot provide a stable display UUID, keep the mapping unresolved and ask the user to confirm. Do not silently match only by display name.
- Never persist an `AudioObjectID` or `CGDirectDisplayID`.

### Device disappearance fallback

When a routed destination disappears:

1. Mark the route degraded and immediately stop feeding the missing device.
2. Tear down or deactivate the muting tap promptly so the source returns to its normal macOS path.
3. Do not silently route to a different physical output.
4. Show a nonmodal needs-attention state.
5. If the same device UID returns, wait for it to become alive and stable, then restore the route after normal debounce.

Headphone Override is a policy overlay rather than a normal remembered destination. If its selected device disappears, tear down override routes before missing-device recovery can begin, clear override-specific route text, and immediately recalculate normal display mappings. Keep the override preference armed for the same UID to reconnect later.

## 12. Per-process audio routing design

### 12.1 Required technical approach

For each actively routed process, or for an equivalent safely grouped implementation:

1. Resolve PID to a Core Audio process object.
2. Create a private `CATapDescription` targeting that process.
3. Initially use `CATapMuteBehavior.mutedWhenTapped`, so original output is suppressed only while AudioOrbit is actually reading the tap. Validate behavior under crash, engine stall, and device removal. Use `.muted` only if tests prove teardown and failure safety.
4. Create a private aggregate audio device containing the tap, following Apple's process-tap sample architecture.
5. Register an input IO procedure on the aggregate device and start it.
6. Transfer frames into a preallocated real-time-safe buffer associated with the destination device.
7. Mix routes sharing a destination, convert formats outside unsafe paths or through a real-time-safe preconfigured converter, and render with a HAL output Audio Unit or device IO procedure bound to that physical output.
8. Monitor underflow, overflow, discontinuity, drift, device liveness, format, and callback timing.
9. On route switch, prime the new destination, perform a bounded ramp, advance the route generation, then release the old destination.
10. On stop or failure, stop reading before destroying callbacks, destroy the aggregate device and tap, release buffers, and verify that normal source output resumes.

### 12.2 Data-plane requirements

- Use a canonical internal format selected during Milestone 0, initially 32-bit float, noninterleaved stereo at the destination's working sample rate where practical.
- Downmix or map channels deterministically. Preserve stereo for the MVP; document behavior for mono and multichannel sources.
- Use a bounded single-producer/single-consumer ring buffer per route or an equivalent proven design.
- Size buffers from measured device periods and conversion latency; do not use arbitrary large latency to hide drift.
- Compensate for independent device clocks using an asynchronous sample-rate converter or adaptive resampling strategy validated in the spike.
- Preallocate audio buffers and converter state before callbacks start.
- Audio callbacks may only copy/mix bounded buffers, update atomic counters, and invoke proven real-time-safe audio primitives.
- Keep the engine valid when two or more routes share an output device. The current implementation uses isolated AUHAL clients; a dedicated shared per-device mixer remains a hardening decision.
- Keep AudioOrbit's own test tones and output rendering outside captured process scopes to avoid feedback.

### 12.3 Route identity

Runtime route identity is PID plus process start identity/generation, not PID alone. Persistent labels use bundle identifier and localized application name. Protect against PID reuse.

### 12.4 Unsupported or protected sources

If a process cannot be tapped, produces an unsupported format, or returns silence while HAL reports active output:

- Do not leave the process muted.
- Transition to `failedPassThrough`.
- Show a concise diagnostic reason and OSStatus where available.
- Continue routing other processes.

## 13. Route state machine

Each process has one route state:

| State | Meaning | Allowed next states |
|---|---|---|
| `unmanaged` | No eligible window, mapping is pass-through, app is excluded, or global routing is off. | `candidate`, `preparing` |
| `candidate` | A display/device decision is waiting for debounce/hysteresis. | `preparing`, `unmanaged`, `routed` |
| `preparing` | Tap, aggregate device, buffers, and output path are being created and primed. Original output must remain safe. | `routed`, `failedPassThrough`, `tearingDown` |
| `routed` | Audio is being read from the tap and rendered to the committed destination. | `switchCandidate`, `degraded`, `tearingDown` |
| `switchCandidate` | A different destination is stable enough to evaluate but not yet committed. | `switching`, `routed`, `degraded` |
| `switching` | The new output path is primed and a bounded transfer/ramp is in progress. | `routed`, `degraded`, `failedPassThrough` |
| `degraded` | Current destination or engine is unhealthy; teardown/pass-through is underway. | `preparing`, `failedPassThrough`, `unmanaged` |
| `failedPassThrough` | Routing failed and normal macOS playback has been restored. | `candidate`, `preparing`, `unmanaged` |
| `tearingDown` | IO is stopping and HAL resources are being destroyed. | `unmanaged`, `candidate`, `failedPassThrough` |

### Invariants

- At most one committed destination exists per process.
- A stale generation cannot commit after a newer route intent.
- `routed` requires granted permissions, a live destination UID, an active tap read, and a healthy output renderer.
- Any fatal data-plane error converges to audible pass-through, not indefinite mute.
- Global disable tears down every tap and restores pass-through.
- Route operations are idempotent.

## 14. Debounce and hysteresis

Use these initial values as named configuration constants, not scattered literals:

```text
windowEventCoalesce       = 100 ms
displayChangeDwell        = 500 ms
noEligibleWindowGrace     = 1000 ms
deviceReconnectDwell      = 1000 ms
minimumAreaAdvantage      = 10 percentage points
boundaryInset             = 48 points
routeGainRamp             = 25 ms (tune during spike)
```

Commit a new candidate display when either condition remains true for the full `displayChangeDwell`:

1. The candidate contains at least 60% of the window's intersected on-screen area; or
2. The window center lies at least `boundaryInset` inside the candidate display.

If neither condition is satisfied, keep the committed display. For a newly observed process with no committed display, choose the largest-intersection display after the standard dwell even when neither strong condition applies.

Additional rules:

- Coalesce rapid AX move/resize events before recalculation.
- Reset dwell only when the candidate display changes, not on every same-candidate geometry update.
- Focus changes within the same process use the same dwell policy if they imply a different display.
- Display disconnect bypasses normal dwell and immediately enters degraded safe teardown.
- Device reconnect uses its own dwell to avoid flapping.
- Make timing injectable for deterministic tests.

## 15. Relevant macOS APIs

| Area | Primary APIs | Purpose and notes |
|---|---|---|
| Process taps | `CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareDestroyProcessTap`, `AudioHardwareTap` | Capture selected outgoing process audio and control mute behavior. Requires macOS 14.2+. |
| Aggregate device | `AudioHardwareCreateAggregateDevice`, `AudioHardwareDestroyAggregateDevice`, `kAudioAggregateDevicePropertyTapList` / tap composition keys | Expose tap audio as an input source for IO. Use private aggregate devices. |
| HAL objects | `AudioHardwareSystem`, `AudioHardwareProcess`, `AudioHardwareDevice`, `AudioObjectGetPropertyData`, `AudioObjectAddPropertyListenerBlock` | Discover processes/devices and observe state. Use newer typed wrappers where deployment SDK behavior is verified; keep low-level wrappers isolated. |
| Device IO | `AudioDeviceCreateIOProcID`, `AudioDeviceStart`, `AudioDeviceStop`, HAL Output Audio Unit (`kAudioUnitSubType_HALOutput`) | Read aggregate tap input and render to a chosen physical device. Apple's documentation advises C for IO procedures; keep callbacks minimal and real-time safe. |
| Format conversion | `AudioConverter`, `AVAudioConverter`, or Audio Unit conversion selected by spike | Channel mapping and asynchronous sample-rate/drift conversion. Do not instantiate or reconfigure inside callbacks. |
| App/process lifecycle | `NSWorkspace`, `NSRunningApplication`, workspace launch/terminate/activate notifications | Correlate PID, bundle ID, app name, activation, and lifetime. Reconcile because some background/agent apps are not covered by every notification. |
| Accessibility | `AXUIElement`, `AXObserver`, `AXIsProcessTrustedWithOptions`, focused/main window and position/size attributes | Determine selected window and geometry. Handle unsupported attributes and per-app AX failures. |
| Window correlation | `CGWindowListCopyWindowInfo` | Optional bounded fallback/correlation for window IDs, bounds, owner PID, and front-to-back order. It is not the primary high-frequency tracker. |
| Displays | `CGGetOnlineDisplayList`, `CGDisplayRegisterReconfigurationCallback`, `CGDisplayCreateUUIDFromDisplayID`, `NSScreen` | Enumerate displays, persist stable UUIDs, observe topology, and obtain frames/names. |
| Menu-bar UI | AppKit `NSStatusItem`/`NSPopover`, SwiftUI `Settings`, `SettingsLink` | AppKit distinguishes left/right status-item clicks; SwiftUI supplies the popover content and native Settings scene. |
| Persistence | `Codable`, `UserDefaults` or an atomically replaced Application Support JSON file | Store small versioned settings. Prefer a JSON file if diagnostics/migration clarity outweighs `UserDefaults` convenience. |
| Logging | `OSLog`, `Logger`, `OSSignposter` | Structured metadata/events and performance intervals. Never log from the real-time callback. |

## 16. Permissions and privacy

### Accessibility

- Required to reliably inspect other applications' focused/main windows and geometry.
- Check with `AXIsProcessTrustedWithOptions`.
- Prompt only from a clear onboarding action.
- If denied or revoked, stop automatic route changes, safely tear down active muting taps, and show remediation.

### System Audio Recording

- Required for Core Audio process taps.
- Add `NSAudioCaptureUsageDescription` to `Info.plist` with a plain-language explanation.
- The first actual read/start involving a process tap triggers the system permission flow.
- If denied or revoked, do not attempt repeated background prompts. Restore pass-through and show remediation.

### Screen Recording

Do not request broader Screen Recording access merely to capture pixels; AudioOrbit does not capture pixels. If testing shows the chosen fallback window metadata path causes a separate OS privacy requirement, eliminate that fallback if possible or document and justify the additional permission before expanding the MVP permission set.

### Privacy commitments

- Audio remains in volatile memory and is discarded immediately after rendering.
- No waveform, transcript, fingerprint, or audio payload is written to logs or diagnostics.
- No analytics or network transmission is required for MVP operation.
- Support reports contain application identifiers/names, device/display metadata, timings, counters, states, and errors only. Provide a preview before export.

## 17. Menu-bar UI

### Status-item popover

- Use an AppKit status item hosting SwiftUI content so left-click opens the popover and right-click exposes Enable/Disable and Quit actions.
- Status header with icon, global state, and an explicit Enable/Disable button rather than a checkbox-style toggle.
- Current Routes section with one row per routed/degraded process:
  - App icon and name.
  - Display name.
  - Destination output name.
  - State indicator and short issue text if applicable.
- Empty state explaining either "No applications are currently playing" or the actionable missing prerequisite.
- Remember inactive application routes until the user explicitly deletes them.
- Show physical-output volume sliders only for devices that advertise a public writable Core Audio volume scalar.
- Footer actions: native SwiftUI **SettingsLink** and a visibly button-styled **Quit AudioOrbit**.

### Settings window

Tabs or sections:

1. **Displays** — one full-width card/row per display with output picker and connection state. A generated test tone remains future work.
2. **General** — remembered routes and Headphone Override configuration.
3. **Permissions** — current permission state, explanations, recheck, and open-settings actions.

Raw process selection, buffer counters, manual feasibility controls, and OSStatus details are not exposed in the end-user Settings window. A separately gated support-report flow may expose redacted diagnostics in a later milestone.

### Accessibility and polish

- Keep `AppIcon.icon` as the authoritative app-icon source. Artwork is separated into orbit, destination, audio-core and waveform SVG layers so Icon Composer—not flattened source artwork—owns the Liquid Glass material and platform rendering.
- All icons require labels/tooltips and VoiceOver descriptions.
- Do not communicate health by color alone.
- Use localized user-facing strings.
- Keep technical OSStatus values behind a details disclosure; lead with a recovery action.
- Preserve selections when hardware temporarily disconnects.

## 18. Persistence

Use a versioned root model:

```swift
struct PersistedConfiguration: Codable {
    var schemaVersion: Int
    var mappings: [DisplayAudioMapping]
    var routingEnabled: Bool
    var cachedRoutes: [CachedApplicationRoute]
    var headphoneOverrideEnabled: Bool
    var headphoneOverrideDeviceUID: String?
}
```

Requirements:

- The current schema is version 2 and migrates version 1 display mappings and routing state.
- Perform decoding and migration off the real-time path.
- Validate ranges and enum values; preserve a backup of the last readable configuration before migration.
- Write atomically.
- If the configuration is corrupt, move it aside, load safe defaults with routing disabled, and inform the user without crashing.
- Never persist permission assumptions, PIDs, `AudioObjectID`s, tap IDs, aggregate-device IDs, or audio buffers.
- Persist user mappings even while their hardware is absent.
- Persist remembered application intent by bundle identifier, never by PID.
- Headphone Override stores one explicitly selected output UID and becomes active only while that exact output is alive.
- Headphone Override never replaces an application's remembered display destination; its route labels and temporary destinations are cleared on disconnect.

## 19. Error handling and recovery

### Principles

- Prefer audible pass-through over silence.
- Isolate failure to the affected process or output device.
- Make cleanup safe to call repeatedly and from partial setup states.
- Preserve user mappings through transient hardware failures.
- Rate-limit identical UI alerts and log events.

### Required cases

| Failure | Required behavior |
|---|---|
| Accessibility denied/revoked | Stop tracking changes, safely dismantle muting routes, return all processes to pass-through, show permission action. |
| System audio permission denied/revoked | Do not tap/mute; return to pass-through and show permission action. |
| Tap creation fails | Leave source normal output intact, record OSStatus/context, mark only that process `failedPassThrough`. |
| Aggregate-device creation/start fails | Destroy partial objects in reverse order, verify tap is inactive/destroyed, pass through. |
| Output device disappears | Stop its renderer, release affected tap reads promptly, pass affected processes through, preserve mapping. |
| Sample rate or format changes | Rebuild/retune conversion at a safe control-plane boundary; use pass-through if the transition cannot be made safely. |
| Ring-buffer underflow | Render silence for missing frames, increment atomic counter, attempt bounded recovery; degrade after threshold. |
| Ring-buffer overflow | Drop the oldest or newest frames according to the spike's measured policy, count it, and resynchronize; never block callback. |
| Window data temporarily unavailable | Retain last committed route for 1-second grace, then pass through. |
| Process exits | Stop IO, tear down route idempotently, remove runtime state. |
| AudioOrbit terminates normally | Stop all tap reads and destroy all taps/aggregate devices before exit. |
| AudioOrbit crashes/gets killed | Rely on private HAL object ownership and `mutedWhenTapped` behavior so macOS resumes normal output; verify in hardware tests. |
| Configuration corrupt | Quarantine file, start disabled with defaults, offer diagnostics. |

Wrap `OSStatus` in a typed error that includes operation, four-character-code rendering when printable, numeric value, route generation, and non-sensitive object metadata.

## 20. Logging and diagnostics

### Log categories

- `app.lifecycle`
- `permissions`
- `window.tracking`
- `display.discovery`
- `device.discovery`
- `routing.decision`
- `audio.control`
- `audio.health`
- `persistence`

### Structured event fields

- Monotonic timestamp and wall-clock timestamp.
- Route generation.
- Bundle identifier and PID for runtime diagnostics; allow names/identifiers to be redacted on export.
- Display UUID/name hint.
- Audio device UID/name hint.
- Previous/new route state and reason code.
- OSStatus operation/value where applicable.
- Debounce candidate start/commit/cancel.
- Sample rate, channel count, buffer size, and latency metadata.
- Sampled underflow, overflow, discontinuity, and late-callback counters.

### Real-time metrics bridge

Audio callbacks update only preallocated atomics/counters. A non-real-time sampler reads and logs aggregates no more frequently than once per second. Never format strings or call `Logger` in an audio callback.

### Support report

Export a UTF-8 text or JSON report containing:

- App/build/macOS versions.
- Permission states.
- Connected displays and outputs.
- Persisted mapping summary.
- Current route state snapshot.
- Recent bounded event buffer.
- Audio health counters and configuration.

Exclude audio data, window titles by default, user document paths, and unrelated process lists.

## 21. Testing strategy

### 21.1 Unit tests

- [x] Window eligibility and focused/main/fallback selection.
- [ ] Coordinate conversion between AX, Core Graphics, and `NSScreen` spaces.
- [x] Largest-intersection display selection, ties, negative coordinates and vertically stacked displays.
- [ ] Debounce/hysteresis timing using a virtual clock.
- [ ] Route state transitions, invariants, stale-generation rejection, and idempotency.
- [x] Display/device UID mapping, schema migration, validation and corrupt persistence recovery.
- [x] Typed OSStatus formatting.
- [x] Ring-buffer behavior using a non-real-time test harness, including wraparound, underflow and overflow policy.
- [x] Sample-rate conversion, adaptive correction, startup priming and switch-backlog rebasing.
- [x] Conservative process/window association, including Safari/WebKit helpers and ambiguity rejection.

### 21.2 Integration tests with fakes

Define protocols around window, display, HAL discovery, tap, renderer, time, and persistence boundaries. Test:

- [ ] App starts audio before its window is discovered.
- [ ] Window moves repeatedly across a boundary and ends on the original display.
- [ ] Focus changes between two windows of the same process on different displays.
- [x] Two processes resolve independent mapped targets and duplicate-process routes are rejected.
- [ ] Two processes share one output and are mixed correctly.
- [ ] Destination disappears during preparation, active routing, and switching.
- [ ] Permission is revoked while routed.
- [ ] PID is reused after an application exits.
- [ ] Old asynchronous preparation completes after a newer route generation.
- [ ] Global disable during every state restores pass-through.

### 21.3 Audio-engine tests

- [x] Deterministic frame sources verify copying, gain ramps, priming and rate conversion.
- [ ] Measure end-to-end latency and jitter for built-in, USB, Bluetooth, DisplayPort/HDMI, and aggregate-like devices when available.
- [ ] Run two outputs with different nominal sample rates for at least 30 minutes; verify drift control and bounded buffer occupancy.
- [ ] Run at least four process routes for one hour; verify no unbounded memory/counter growth.
- [ ] Force callback underflow/overflow and confirm no deadlock or crash.
- [ ] Verify route switching does not click and does not produce sustained duplicate audio.

### 21.4 Manual system matrix

Test on the minimum OS and the latest supported macOS release with:

- Built-in display plus one external display.
- Two external displays where available.
- Built-in speakers, USB audio, HDMI/DisplayPort audio, Bluetooth, and devices with volume controls where available.
- Common native apps, a browser, an Electron app, media players, and a process with multiple windows.
- Full-screen windows, Spaces, Stage Manager if enabled, minimized/hidden apps, sleep/wake, fast user switching where feasible, display hot-plug, and audio-device hot-plug.
- Permission allow, deny, later allow, later revoke, app update/re-sign, and app relaunch.

Automated tests must not assume particular hardware names or UIDs.

The current automated suite contains 41 passing tests. Checked items above mean deterministic coverage exists in this repository; unchecked hardware and failure-injection items remain required even when related behavior has been exercised manually.

## 22. Milestones

### Milestone 0 — Feasibility spike and architecture decision record

Core feasibility is complete and ADR-001 accepts the current architecture for the integrated MVP. Remaining unchecked items are release evidence, not permission to weaken pass-through safety.

- [x] Create a minimal signed macOS 14.2+ app with `NSAudioCaptureUsageDescription`.
- [x] Tap one chosen process, actively read its audio, and prove `mutedWhenTapped` suppresses the original destination only while read.
- [x] Render the captured audio to a nondefault physical output.
- [x] Route two independent processes to two different outputs simultaneously.
- [ ] Measure latency, CPU use, buffer health, and clock drift for at least 30 minutes.
- [ ] Prove safe recovery after destination unplug, permission denial/revocation where testable, normal quit, force quit, and crash.
- [ ] Validate Accessibility window discovery for representative AppKit, browser, and Electron apps.
- [ ] Validate signing, hardened runtime, sandbox choice, permission prompts, relaunch behavior, and intended distribution path.
- [x] Record the chosen IO architecture, internal format, converter, drift strategy, buffer sizing and known unsupported cases in `docs/ADR-001-audio-routing-engine.md`; distribution remains provisional.

**Gate:** one process can be moved between two physical outputs without changing the system default; two processes can play through different outputs concurrently; failures do not leave a source silently muted. If this cannot be achieved using public APIs with acceptable reliability, stop and document the blocker before considering a virtual driver or revising product scope.

### Milestone 1 — Project foundation and discovery

- [x] Create app target, test target, module boundaries and dependency root. A hosted CI workflow remains future work.
- [x] Implement display and audio-device enumeration with stable IDs and listeners.
- [ ] Implement permission manager and onboarding skeleton.
- [x] Implement versioned mapping, remembered-route and Headphone Override persistence with migration and corrupt-file recovery.

### Milestone 2 — Window tracking and route decisions

- [x] Implement AX window tracking and bounded reconciliation.
- [x] Implement display geometry normalization and deterministic display selection.
- [x] Implement deterministic selected-window policy and conservative helper-process association.
- [ ] Implement route state machine, generations, debounce, hysteresis, and fake-backed tests.

### Milestone 3 — Production audio engine

- [x] Isolate the Swift control plane from the preallocated C real-time bridge and test their boundaries.
- [ ] Complete the per-process tap lifecycle and output architecture; isolated AUHAL renderers work, while shared per-device mixing remains undecided.
- [x] Implement conversion, bounded drift control, ramps, health counters and idempotent teardown.
- [ ] Pass concurrency, hot-plug, long-run, and failure-injection tests.

### Milestone 4 — Integrated MVP UI

- [x] Connect route decisions to the accepted MVP engine.
- [x] Build the AppKit status item, SwiftUI popover, mapping/general/permission Settings and permission remediation. Test tone remains open.
- [x] Add degraded states and user-facing recovery actions; complete VoiceOver review remains open.

### Milestone 5 — Diagnostics, hardening, and release candidate

- [ ] Add structured logs, signposts, counters, redaction, and support report export.
- [ ] Complete the hardware/OS/manual test matrix.
- [ ] Profile CPU, memory, wakeups, audio latency, and callback deadlines.
- [ ] Verify signing/notarization/update behavior and permission persistence.
- [ ] Resolve all acceptance-criteria failures and document known limitations.

## 23. Acceptance criteria

### Functional

- [x] On a Mac with two active displays and two live output devices, the user can map each display to a different device.
- [x] With App A's selected window on Display A and App B's selected window on Display B, simultaneous audio from A and B is audible only on Device A and Device B respectively, subject to measured negligible bleed during bounded switching ramps.
- [x] Moving App A's selected window to Display B commits after the stable candidate dwell and moves App A's audio without changing App B's route.
- [x] Rapidly oscillating a window across a display boundary does not repeatedly switch outputs under the deterministic hysteresis policy.
- [x] Two windows from the same process never appear as separate audio routes; the documented selected-window policy determines the one process route.
- [x] Global disable returns all managed processes to normal macOS output and destroys active taps.
- [x] Relaunch restores display mappings by stable UID.

### Reliability and safety

- [x] Unplugging a routed output never leaves the source indefinitely muted; normal mapped outputs enter safe recovery and Headphone Override cleanly restores display routing.
- [ ] Denied or revoked permissions produce pass-through, not silence or a prompt loop.
- [ ] Normal quit, force quit, and injected crash testing demonstrate that original process output resumes.
- [x] One route's runtime ownership and recovery are isolated from healthy routes.
- [x] No private API, system-default-device flipping, or required custom audio driver is present in the MVP.

### Audio quality and performance

Set final numeric budgets from Milestone 0 measurements and target hardware, then enforce them in tests. Initial release targets:

- [ ] No audible clicks during stable start/stop/switch in the manual test matrix.
- [ ] No sustained duplicate output before or after a route switch.
- [ ] No unbounded drift, memory growth, or ring-buffer growth during a one-hour run.
- [ ] Under steady two-process/two-device playback on reference hardware, no recurring underflow/overflow and no missed real-time deadlines attributable to allocation or locks.
- [ ] Added routing latency is measured, displayed in diagnostics, and judged acceptable during the spike; target less than 100 ms for wired outputs. Bluetooth latency is reported separately and is not held to the wired target.
- [ ] Idle mode with no routed audio avoids high-frequency polling and excessive energy use.

### Privacy and usability

- [x] Permission explanations state exactly why window metadata and system audio access are needed.
- [x] No audio content is stored or transmitted.
- [ ] Exported diagnostics are previewable and exclude audio, window titles, and document paths by default.
- [ ] All main controls and route states are usable with VoiceOver and without color-only cues.

## 24. Implementation guidance for Codex

### Working method

1. Read this entire specification before editing code.
2. Inspect the repository, existing tests, build settings, and local `AGENTS.md` instructions.
3. Maintain a short implementation plan mapped to the current milestone.
4. Keep implementation choices consistent with accepted ADR-001 and record new architecture decisions before changing real-time ownership.
5. Make small, reviewable changes. Do not combine a real-time engine rewrite with unrelated UI work.
6. Add or update tests with each behavior change.
7. Build and run the relevant tests after every module-level change.
8. Preserve existing user changes and avoid destructive repository operations.
9. When an Apple API's behavior is unclear, build the smallest instrumented experiment and record the result; do not invent behavior.
10. Keep a `KNOWN_LIMITATIONS.md` file current as hardware/application exceptions are discovered.

### Current repository shape

```text
AudioOrbit/
├── App/
├── Domain/
├── Platform/
│   ├── Accessibility/
│   ├── CoreAudio/
│   ├── Displays/
│   └── Processes/
├── Realtime/
└── UI/
AudioOrbitTests/
Config/
docs/
└── ADR-001-audio-routing-engine.md
PROJECT_SPEC.md
KNOWN_LIMITATIONS.md
```

Add new boundaries only when a milestone needs them; do not reorganize working real-time code solely for cosmetic structure.

### Coding rules

- Wrap Core Audio C APIs behind narrow typed interfaces and centralize property-address/OSStatus handling.
- Use dependency injection for time, permissions, discovery, persistence, tap creation, and output rendering.
- Mark UI state/main-thread types appropriately; do not let `@MainActor` leak into audio callbacks.
- Prefer value-type immutable snapshots across module boundaries.
- Use cancellation and route generations for control-plane work.
- Write C or a minimal C/C++ shim for IO procedures if needed for demonstrable real-time safety, consistent with Apple's guidance.
- Document callback thread assumptions and ownership beside each real-time entry point.
- Avoid `fatalError`, forced casts, and force unwraps in permission, hardware, routing, and persistence paths.
- Make teardown explicit and idempotent; test every partially initialized stage.
- Store tuning constants in one validated configuration type.
- Add comments for why a Core Audio sequence or ordering constraint exists, not for obvious syntax.

### Pull-request checklist

- [ ] Change belongs to the active milestone and does not silently expand scope.
- [ ] Public API availability is guarded for the 14.2 deployment target.
- [ ] No allocations, locks, logging, file/network I/O, or actor hops were added to real-time callbacks.
- [ ] Failure restores or preserves pass-through.
- [ ] New async work is protected from stale route generations.
- [ ] Tests cover success, partial setup failure, teardown, and cancellation.
- [ ] User-visible errors include a recovery path.
- [ ] Logs are structured, rate-limited, and redacted.
- [ ] Build, unit tests, integration tests, and relevant manual audio checks pass.
- [ ] Documentation/ADR/known limitations reflect behavior.

## 25. Open hardening and release questions

- Should multiple routes sharing one physical output retain isolated AUHAL clients or move to one per-device renderer/mixer? Compare lifecycle complexity, latency, mixing and failure isolation with evidence.
- Which production-quality converter should replace or validate the current adaptive linear interpolator?
- What buffer sizes meet stability and wired-latency targets across built-in, USB, HDMI, and Bluetooth devices?
- Does `mutedWhenTapped` provide the safest audible failover under every tested teardown and crash path?
- Which signing/sandbox/distribution configuration preserves all required public API behavior?
- Which applications or protected content types cannot be routed, and how can they be detected without false claims?
- Which additional trusted helper families, if any, can be correlated without broadening capture to unrelated processes?

Do not silently answer these questions in production code. Record evidence and decisions in an ADR.

## 26. Official references

- [Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/CoreAudio/capturing-system-audio-with-core-audio-taps)
- [`CATapMuteBehavior`](https://developer.apple.com/documentation/coreaudio/catapmutebehavior)
- [`AudioHardwareTap`](https://developer.apple.com/documentation/coreaudio/audiohardwaretap)
- [`AudioHardwareAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwareaggregatedevice)
- [`AudioHardwareSystem`](https://developer.apple.com/documentation/coreaudio/audiohardwaresystem)
- [`AudioHardwareProcess`](https://developer.apple.com/documentation/coreaudio/audiohardwareprocess)
- [`AudioDeviceCreateIOProcIDWithBlock`](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:))
- [`CGWindowListCopyWindowInfo`](https://developer.apple.com/documentation/coregraphics/cgwindowlistcopywindowinfo(_:_:))
- [`AXIsProcessTrustedWithOptions`](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)
- [`NSStatusItem`](https://developer.apple.com/documentation/appkit/nsstatusitem)
- [SwiftUI `Settings`](https://developer.apple.com/documentation/swiftui/settings)
- [SwiftUI `SettingsLink`](https://developer.apple.com/documentation/swiftui/settingslink)
