# Automated display-following tests

Status: first software smoke run passed on 2026-09-06 (macOS 26.6.2, Safari 26.6.2, built-in display/speakers and Studio Display XDR). See [the runnable framework and setup instructions](../tools/e2e/README.md). The live run verified initial playback on A, real A → B → A drags, actual HAL output binding with advancing audio counters, and playback remaining on A when a silent window on B received focus. The system default output stayed unchanged and teardown completed normally. This is one successful smoke run, not a long-run reliability or acoustic-quality result. The remaining sections describe the broader target design. Physical audio verification follows later.

The first implementation uses Python orchestration with a native Swift helper and private atomic JSON snapshots. The socket interface, complete event history, and expanded scenario matrix below remain planned.

## Outcome

One local command opens a known video in Safari, drags its window between connected displays, verifies that AudioOrbit's live audio renderer follows the playback window, and writes a pass/fail report. Subsequent suites exercise fullscreen video, tab tear-off, competing windows, and repeated transitions. A person grants permissions and configures the test machine once; each normal run is unattended while it owns the desktop.

The first version proves window movement, automatic routing, renderer device binding, and ongoing audio processing. It cannot prove that a speaker emitted sound, detect every audible click, or rule out duplicate playback on an unobserved output. Reports must state the verification level explicitly.

## Existing foundations and gaps

The current repository has 77 `test…` methods across 11 XCTest files, including nine direct audio-bridge tests. The README and architecture document's count of 76 is stale. Keep these fast tests in the existing CI job.

Useful integration points:

- `AudioOrbit/App/AppModel.swift`: route orchestration, playback anchors, pending decisions, and the 500 ms destination-switch debounce. Its private `RouteSession` owns the probe and metrics.
- `AudioOrbit/Platform/CoreAudio/ProcessTapProbe.swift`: current destination, tap lifecycle, and `metricsSnapshot()`.
- `AudioOrbit/Platform/CoreAudio/PhysicalOutputRenderer.swift`: binds the AUHAL renderer using `kAudioOutputUnitProperty_CurrentDevice`. Add an actual property readback; the existing stored destination is not sufficient verification.
- `AudioOrbit/Domain/AudioModels.swift`: existing callback, captured/rendered-frame, non-silent-frame, underflow, and overflow counters.
- `AudioOrbit/App/AudioOrbitApp.swift`: XCTest currently selects an isolated mapping file and sets `startsServices: false`. End-to-end runs need a separate launch mode that keeps the real services enabled.
- `AudioOrbit/Diagnostics/Diagnostics.swift`: existing reports intentionally omit identifying information and routine unified logging. Do not parse or expand production support reports for automation.

Missing pieces are a desktop driver, deterministic Safari media fixture, test-only observation interface, scenario runner, and report writer.

## Architecture

Use a small signed native Swift runner, launched from a shell wrapper. It controls ordinary Safari windows through Accessibility and Core Graphics, serves a local video fixture, observes AudioOrbit through a local test-only interface, and evaluates scenario assertions. Keeping orchestration in one process makes timestamps, cleanup, and timeouts easier to coordinate.

| Component | Responsibility |
| --- | --- |
| Desktop driver | Discover displays/windows; place and drag windows; click playback/fullscreen controls; read back actual geometry |
| Fixture server | Serve a bundled video and test page on loopback; collect playback-ready, time-progress, pause, and fullscreen state |
| AudioOrbit observer | Expose current route, actual renderer binding, audio counters, and ordered transition events |
| Scenario engine | Execute bounded steps; compare independently specified expectations with observed state |
| Reporter | Save results, transition timing, sanitized traces, and optional failure screenshots |

Do not use Safari WebDriver for native drag scenarios. Apple documents that its automation windows have a glass pane that intercepts mouse, keyboard, and resize interactions. Ordinary Safari windows preserve the behavior under test. WebDriver could be used separately for fixture-page tests. [Apple: About WebDriver for Safari](https://developer.apple.com/documentation/webkit/about-webdriver-for-safari)

For precise setup, check whether AX position/size attributes are settable, set them, and read them back. For the actual drag test, post mouse-down, a paced sequence of mouse-dragged events, and mouse-up on the window's title bar. Always release the mouse on cancellation. AX placement and an actual drag are separate scenario types; a placement-only result must not claim drag coverage. [Apple: AX attribute setting](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue), [Apple: CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent)

## Controlled Safari fixture

Bundle a short, generated, non-DRM H.264/AAC video with visible motion, a time marker, and a low-level known audio signal. Record its checksum. Serve it locally with correct MIME types and byte-range support; no ads, login, internet streaming, or network variability is needed for the core suite.

Use an actual HTML video element with an embedded audio track. A Web Audio oscillator alone may exercise a different Safari process path. Provide visible, accessible Play, Pause, and Fullscreen buttons. Playback and fullscreen begin through a real click to satisfy user-activation requirements. Verify that media time progresses, the element is unmuted, and volume is nonzero before measuring a route.

Each page has a unique run/fixture token and reports state to its own origin. Include a silent second page for focus tests. Scope every window action to windows created by this run; do not infer the playing window from whichever Safari window is focused. Safari's helper PIDs may migrate, so track the logical fixture across transitions rather than asserting a constant PID.

Treat native video fullscreen and browser-window fullscreen as separate cases. Verify the native presentation's actual display and playback continuation, including exit and Space changes. DOM fullscreen state alone is insufficient evidence that the native transition completed.

## Test-only observation interface

Add an explicit `AUDIOORBIT_E2E` compilation condition for a dedicated test build. Require an explicit launch flag as well. The distributed release must not contain this interface. Keep the routing engine identical to production: no injected window evidence, forced route commits, shorter debounces, or automatic retries added by the test hook.

Use a Unix-domain socket inside a per-run directory with owner-only permissions. A launch manifest supplies a run token, isolated mapping file, isolated preferences, and allowed fixture application. Use a short socket path to avoid Unix socket path-length limits. Expose versioned read-only snapshots and transition events; prepare mappings before launching the app. Optional test actions such as disabling routing should use the same app action as the normal UI.

Suggested snapshot contract:

| Field group | Required evidence |
| --- | --- |
| Freshness | Schema version, run ID, app instance ID, sequence, monotonic observation time |
| Routing | Enabled state, live/cached status, logical source, route generation, lifecycle state |
| Window decision | Playback anchor, selected window/display, pending target, committed target |
| Renderer | Requested destination UID, probe destination UID, actual AUHAL device UID read back, renderer started, binding error if any |
| Audio progress | Capture/render callbacks, captured/rendered/non-silent frames, queue, underflow/overflow counters |
| Environment | Current display topology, device availability, current default output UID |

Read renderer properties outside audio callbacks and serialize with renderer prepare/switch/teardown. Read bridge counters through the existing snapshot operation. Sample directly at a bounded test cadence (initially 10 Hz), rather than relying on the UI's one-second metrics cache. No file writes, locks, or IPC in real-time callbacks.

Events should cover candidate changes, switch start/completion/failure, route start/stop, and source migration. Give them ordered sequence numbers and monotonic timestamps; a snapshot includes its latest event sequence. Detect event loss, app restarts, and stale responses rather than accepting an old successful state. Unavailable property readback is a failed observation, not a match to the requested device.

Persist run-local aliases such as `display-A`, `output-B`, and `playing-window`. Raw UIDs/PIDs needed for correlation remain local to the run. Preserve production diagnostics' privacy behavior. Screenshots are optional and restricted to the fixture desktop/window; do not save captured application audio.

## First suite and assertions

The machine needs two active, non-mirrored displays mapped to two distinct live outputs. Discover layout dynamically, including displays above or left of the primary display and differing scale factors. Use one consistent global coordinate space and validate conversion with read-back geometry. Choose safe window bounds well inside each display for the initial suite; boundary cases come later.

The scenario's expected destination comes from the test manifest and intended fixture location. Do not calculate the expected display by invoking AudioOrbit's own selection policy; that would reproduce its mistakes in the assertion.

Initial smoke sequence:

1. Preflight permissions, topology, mappings, and exclusive desktop access. Record the system default output using an independent Core Audio query.
2. Launch the isolated AudioOrbit test build with normal services active. Open the fixture on display A and click Play.
3. Wait for advancing media time, then a live automatic route to output A. Verify renderer readback and increasing capture, render, and non-silent counters.
4. Perform a real title-bar drag to display B. Read back stable destination geometry; do not assume posting events succeeded.
5. Require a live running route whose actual renderer binding is output B and whose audio counters continue to advance. Require the result to stay valid for a stability interval.
6. Drag back to A and repeat. Add a separate silent Safari window on B, focus it, and require the established playback route to remain on A.
7. Confirm the system default output has stayed unchanged, close only fixture windows, stop the test app through normal cleanup, and write the report.

Use deltas from fresh snapshots, not lifetime counters greater than zero. Counters may reset on route recreation; restart the progress baseline for a new generation and report the migration. Require non-silent capture and rendered-frame progress during known active signal segments. This still does not establish non-silent physical output.

Starting timing values are test configuration, not measured performance promises: 15 s for first-route readiness, 5 s from stable destination geometry for ordinary moves, and 1 s of stable correct state. Also report total time from mouse release so slow geometry settling is visible. Give fullscreen and recovery cases separate deadlines. Calibrate these on the reference setup; report median, p95, maximum, and timeouts. Never expand deadlines automatically to make a failure pass.

Observe invariants throughout each step: no unexpected default-output change, no extra active route for the same single source after settling, and no late switch back during the hold interval. Sample the default independently and subscribe to change notifications. After a three-second audio warm-up, report underflow/overflow deltas separately from expected startup/switch transients. Silence/dropout durations and duplicate audible playback remain unverified until output measurement exists.

## Expansion matrix

| Priority | Scenario | Expected behavior |
| --- | --- | --- |
| First | Safari A → B → A, actual drag | Renderer follows the playing window each time |
| First | Focus silent Safari window on B | Playback stays on A |
| Next | Repeat 50 A/B moves | No stuck route; report latency distribution and every failure |
| Next | Native video fullscreen enter/exit on A and B | Route follows actual presentation, then returns to playback window |
| Next | Tear playing tab into a new window on B; transfer into an existing window | Anchor follows the renderer's new reporter |
| Next | Pause, change focus, resume | Playback anchor is retained |
| Next | Rapid A/B/A moves and boundary straddling | Final settled target wins without late oscillation |
| Next | Map B to System Default; disable routing | Tap is removed and software pass-through state is restored |
| Later | A second app playing to another output | Each supported source keeps its own destination |
| Later | Helper churn, close playing tab, prolonged pause | Recovery/lifecycle behavior matches the documented policy |
| Later | Output disconnect/reconnect, headphone override, sleep/wake | Recovery follows the configured policy within scenario-specific bounds |
| Later | Mixed sample rates and 30-minute playback | Queue stays bounded; report drift, resources, and counter deltas |

Test tab transfer and fullscreen with real native interactions. If a Safari version does not expose a needed control reliably, classify the scenario as unsupported with evidence; do not silently substitute a simpler action. Begin helper-restart coverage with deterministic injected policy tests; real helper termination requires reliably identifying a fixture-owned process in an isolated session.

Hardware disconnect and sleep/wake need dedicated runner capabilities, such as a controllable hub and a wake arrangement. A mock disconnect belongs to a policy suite and cannot be reported as a hardware test. Simultaneous Safari tabs can share an audio source; separate-output assertions apply only when source ownership supports them, consistent with the app's documented limitation.

## Running, isolation, and reporting

Target entry points (the current runner supports `preflight`, `run --suite safari-smoke`, and `--repeat`; the separate stress suite is planned):

```sh
./scripts/test-e2e.sh preflight --config /path/to/local-lab.json
./scripts/test-e2e.sh run --suite safari-smoke --config /path/to/local-lab.json
./scripts/test-e2e.sh run --suite safari-stress --repeat 50 --config /path/to/local-lab.json
```

The local manifest maps display UUIDs to output UIDs, includes deadlines and fixture settings, and is not committed with machine-specific identifiers. Preflight prints friendly display/output aliases and actionable missing prerequisites.

Use a logged-in, unlocked macOS session with the actual displays and outputs attached. Keep the desktop awake for ordinary suites and serialize runs with a lock. A dedicated macOS test account is preferable: Safari has application-wide state and should not compete with personal playback. On a personal desktop, use only runner-owned windows and stop if another AudioOrbit instance or competing playback would invalidate the test; do not terminate personal apps to obtain isolation.

Grant Accessibility to the app and runner and System Audio Recording to the app once. If Apple Events are used to launch/create Safari windows, their Automation permission is also required. Screenshot permission is only needed for optional screenshot capture. A missing grant produces a blocked preflight result; the runner must not try to bypass macOS permission prompts. Use stable signing identities and paths to reduce repeated permission setup.

Build with DerivedData in a temporary directory, as the existing architecture recommends. Isolate mappings, remembered routes, ignore rules, onboarding, and preference writes. Avoid enabling updates or launch-at-login in the test build. Do not launch under the existing XCTest environment flag, which disables services. Clean up on success, failure, interruption, and timeout: release mouse buttons, exit fixture fullscreen, close owned windows, stop taps/renderers through app cleanup, stop the fixture server, and release the desktop lock. A subsequent preflight should detect leftover test processes and artifacts after an uncatchable crash.

Each result directory contains a readable HTML report, machine-readable JSON, JUnit XML, and a bounded event trace. Record app revision/build, macOS/Safari versions, fixture checksum, topology aliases, verification level, action and route timelines, actual renderer binding, counter deltas, and cleanup outcome. Classify separately: passed software checks, routing failure, fixture/driver failure, blocked prerequisites, and unsupported capability. Never count skipped or blocked tests as passing. Preserve the first failure even if a diagnostic rerun succeeds.

The existing GitHub-hosted workflow runs 77 app XCTest checks and 19 Python framework checks. The live Safari smoke suite needs this lab's two displays, two distinct outputs, saved permissions, and an unlocked graphical session; hosted macOS VMs do not supply that hardware arrangement. GitHub Actions can orchestrate the same command on a dedicated self-hosted Mac. See [the CI coverage matrix and setup sequence](../tools/e2e/README.md#github-actions-coverage).

Keep the desktop job separate and manually dispatched initially, serialize runs, and execute only trusted revisions on the permissioned lab machine. No self-hosted runner or live-smoke release gate is configured by this change. Missing required smoke scenarios should prevent any future configured release gate from passing; hosted unit-test success alone must not claim multi-display coverage.

## Later: verify audio reaching the output

Keep output measurement behind a separate observer interface so the same drag scenarios can be reused. Measure a known coded test signal on the expected output and its absence on every monitored non-target output after a calibrated transition interval. Include the system default output when distinct, otherwise duplicate pass-through could go undetected.

Software loopback endpoints can prove delivery to those virtual endpoints, but do not prove HDMI, USB, Bluetooth, or speaker playback. Physical line-out loopback can measure the electrical path; microphones near speakers can measure acoustic output but require noise/crosstalk calibration. Specify which endpoint was actually observed in the report. Calibrate detector thresholds, timing, and transport latency before setting gap/leakage limits; missing required measurement channels yields incomplete coverage.

Do not use a second Safari process tap as proof of the final destination: it observes process audio, while the requirement concerns the output after routing. Apple's tap documentation describes process-output capture and muting, not proof of speaker emission. [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)

Analyze only the synthetic fixture signal in the separate test observer, in bounded memory. Store detection scores and timings rather than recordings. Leave the production app's no-recording behavior unchanged.

## Implementation order and acceptance

1. Add the gated observation interface and isolated E2E launch mode. Verify actual AUHAL readback and ensure the release build excludes the interface.
2. Add the fixture, native driver, preflight, cleanup, and A/B/A plus focus smoke suite. Exercise against real Safari on the reference setup.
3. Add fullscreen, tab transfer, pause/resume, and stress scenarios with reports and explicit capability handling.
4. Add a dedicated desktop CI runner and calibrate stable timing gates.
5. Add independent output measurement and reuse the same scenarios for end-to-end audio assertions.

The first milestone is complete when one command executes the smoke suite without intervention after setup, fails for a deliberately mismatched expected output, detects a stalled observation stream, reports actual renderer binding and audio progress, and cleans up after an interrupted run. The implementation is available in `tools/e2e`; the first native smoke run has passed. Deliberate native fault injection and extended repetition remain separate validation work.
