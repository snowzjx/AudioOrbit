# Safari display-following smoke tests

This first version automates real Safari title-bar drags A → B → A, verifies AudioOrbit's actual AUHAL output binding and advancing audio counters, then checks that focusing a silent Safari window on B leaves playback on A. `--repeat 50` repeats the moves. It never changes the system default output and independently watches for default-output changes.

A live smoke run passed on macOS 26.6.2 / Safari 26.6.2 with built-in speakers and Studio Display XDR on 2026-09-06. All four checks and cleanup passed in 35 seconds. Buffer overflow was recorded during switching; the current assertions verify routing and continuing audio progress, not dropout-free playback.

Software verification does **not** prove that speakers emitted sound or exclude duplicated audible playback. Fullscreen, tab tear-off, disconnect, and physical output measurement are future suites; the current smoke suite does not claim that coverage.

## Build once

Requires macOS 14.2+, Xcode with the process-tap SDK, and Python 3.9+ (standard library only).

```sh
./scripts/test-e2e.sh build
```

Intermediate build products live in `/tmp/AudioOrbitE2E` by default (`AUDIOORBIT_E2E_BUILD_DIR` overrides this). The build installs both test apps in `~/Applications/AudioOrbit Tests`, and the runner always uses those installed copies. Use `AUDIOORBIT_E2E_APPS_DIR` to override the installed location; keep it stable for permissions. `./scripts/test-e2e.sh install` reinstalls existing build products without recompiling. The build produces a signed native driver, a separate `me.snowzjx.AudioOrbit.E2E` app, and a generated six-second H.264/AAC fixture. It decodes the fixture's audio to validate duration, sample count, and non-silent signal level. No media download or additional encoder installation is needed.

The default signing identity is ad hoc, with a stable designated requirement scoped to each local E2E bundle. Build products are signed before installation, and installed copies retain the exact same executable and requirement; the installer no longer changes the signing identity between the two locations. A certificate identity can instead be supplied through `AUDIOORBIT_E2E_SIGN_IDENTITY`. This changes only the local test apps; production signing is unchanged. If dependencies are already cached, set `AUDIOORBIT_E2E_PACKAGES_DIR` to a complete Xcode `SourcePackages` directory to avoid package resolution over the network. Ordinary Debug/Release builds do not compile the test observation interface.

## One-time setup

Use a dedicated macOS test account if possible. Runs need exclusive use of the foreground desktop: do not move the mouse or interact with Safari while a test is running.

1. Attach two non-mirrored displays with distinct working outputs. Configure the desired mappings in normal AudioOrbit.
2. Copy those mappings into a local, untracked test configuration:

   ```sh
   ./scripts/test-e2e.sh configure --config build/e2e-lab.json
   ```

   This reads the existing configuration without modifying it. For a different pair or more than two mapped displays, use `inventory` and copy `lab.example.json` with the desired UUIDs/UIDs. The order defines A and B.

3. In System Settings → Privacy & Security → Accessibility, add and enable both:

   - `~/Applications/AudioOrbit Tests/AudioOrbit E2E Driver.app`
   - `~/Applications/AudioOrbit Tests/AudioOrbit E2E.app`

   In the Add dialog, press **⌘⇧G**, enter `~/Applications/AudioOrbit Tests/`, and select the app. If clicking does not select it, use the arrow keys to select it, then click Open. Use these installed apps instead of the temporary build copies; the E2E app now has its own visible name.

   If the switches are on but preflight still rejects access after upgrading from an earlier harness build, remove **only AudioOrbit E2E and AudioOrbit E2E Driver** from this list and re-add these installed copies once. Earlier builds signed temporary and installed copies differently, which could leave a saved permission that fails macOS code-requirement validation. Do not remove normal AudioOrbit or reset the entire permission database.

   The runner launches the installed apps through macOS LaunchServices so their own permissions apply. The launching terminal does not need the test apps’ Accessibility grants.

4. Quit the normal AudioOrbit instance and pause other playback. The runner refuses to compete with an existing instance or already-playing processes.
5. On the first run, macOS may request Automation access to Safari and System Audio Recording access for the E2E app. Grant those, then rerun if the bounded test times out. Permission prompts cannot be approved by the runner.

## Run

```sh
./scripts/test-e2e.sh preflight --config build/e2e-lab.json
./scripts/test-e2e.sh run --config build/e2e-lab.json
./scripts/test-e2e.sh run --repeat 50 --config build/e2e-lab.json
```

The test opens only its own local fixture windows. It verifies the actual window frame after a paced drag and requires a settled route with continuing non-silent capture and rendered-frame progress. Mappings, remembered routes, and preferences are isolated from normal AudioOrbit. The test mode keeps normal routing services and timing active; it does not force route decisions.

Each run prints the path to a private temporary result directory containing `report.html`, `report.json`, `junit.xml`, `trace.json`, and `app.log`. Reports use run-local display/output aliases. The private app log may contain system diagnostic details; inspect it locally before sharing. No audio or screenshots are recorded. Transient snapshots and mapping files are removed during cleanup.

Exit codes: `0` passed software checks; `1` routing/driver failure or interruption; `2` blocked setup. Blocked tests are JUnit errors, never passes. Reports preserve all successful steps before the failure. Failed cleanup changes an otherwise passing run to a driver failure.

The runner releases the mouse, closes only windows whose recorded Safari ID and current fixture URL still match, and terminates the E2E app through its normal cleanup path. A private stop request asks the app to shut down normally; terminating the LaunchServices waiter alone would not stop the app. The app and managed driver commands also quit if their runner dies. Forced termination is reported as incomplete cleanup. After a hard crash, check for leftover fixture windows or test processes before rerunning; the runner never closes arbitrary personal windows or kills the production app.

## Validate the framework

```sh
python3 -m unittest discover -s tools/e2e/tests -v
xcodebuild -project AudioOrbit.xcodeproj -scheme AudioOrbit \
  -derivedDataPath /tmp/AudioOrbitUnitTests test
```

The runner tests also cover explicit driver completion despite a spurious LaunchServices exit code, rejecting incomplete responses, cancelling timed-out driver commands before removing their private directories, and refusing to kill a reused PID. They cover wrong actual output despite a correct requested output, stalled or non-silent counters, stale/wrong-run observations, route migration, invalid topology, blocked reports, and the fixture HTTP range/telemetry path. They run in ordinary hosted CI alongside XCTest. They do not replace validation of the native Safari interactions on a permissioned multi-display desktop.

## GitHub Actions coverage

The existing workflow in `.github/workflows/ci.yml` runs the 77 app tests and the 19 Python framework checks on `macos-26`. The framework checks exercise assertions, fixture serving, and launch/cancellation behavior with mocked app launches. They do not open Safari, move windows, or verify a physical output device. The workflow has been updated locally; a remote Actions run of this change has not yet been observed.

| Environment | Supported coverage | Status |
| --- | --- | --- |
| GitHub-hosted macOS | App XCTest and Python framework checks | Included in the existing CI workflow |
| Local Mac with two displays and outputs | Real Safari A → B → A and silent-window focus | One live smoke run passed |
| Dedicated self-hosted Mac with the same hardware | The same live smoke command, started by GitHub Actions | Possible; runner/workflow not configured |
| Loopback inputs or microphones | Independent proof of destination sound and leakage/dropouts | Future work |

GitHub documents its standard macOS runners as fresh virtual machines. They do not provide this lab's attached displays and audio outputs, so the current hardware smoke suite is not a suitable hosted-runner job. That is a requirement of this suite, not a claim that all macOS UI tests are impossible in hosted CI. [GitHub-hosted runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)

To add desktop CI later:

1. Register a dedicated Mac as a [self-hosted GitHub Actions runner](https://docs.github.com/en/actions/how-tos/manage-runners/self-hosted-runners/add-runners), with a custom label such as `audioorbit-desktop`. Use the same logged-in test account that owns the Accessibility, Automation, and audio-capture grants. Run the runner in that account's unlocked graphical session; do not assume that starting a background service creates a usable desktop.
2. Attach two non-mirrored displays and distinct outputs. Complete the one-time setup above and pass one local smoke run. Store the lab configuration outside the checkout, for example `$HOME/AudioOrbitLab/lab.json`, so checkout cleanup cannot delete it. Keep installed app paths and signing identity stable between jobs.
3. Start with a separate, manually dispatched workflow targeting `[self-hosted, macOS, audioorbit-desktop]`, with a finite job timeout and serialized runs (`cancel-in-progress: false`). Run only reviewed, trusted revisions on this permissioned desktop; do not attach it to arbitrary fork pull requests. GitHub notes that self-hosted runners are persistent machines whose security and maintenance you manage. [Self-hosted runner model](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners)
4. Execute the same commands used locally:

   ```sh
   ./scripts/test-e2e.sh build
   ./scripts/test-e2e.sh preflight --config "$HOME/AudioOrbitLab/lab.json"
   ./scripts/test-e2e.sh run --config "$HOME/AudioOrbitLab/lab.json"
   ```

5. Preserve the smoke command's nonzero exit status and collect its printed result directory even on failure. Upload only `report.html`, `report.json`, `junit.xml`, and `trace.json`; keep the private app log and machine configuration local. A blocked preflight must fail the job, not turn into a successful skipped smoke test. If a job is forcibly killed, inspect leftover test processes/windows before the next run.

No self-hosted runner is registered by the build scripts, and no live desktop workflow or release gate is enabled in this change. Add scheduled or release-gating runs only after the dedicated lab has demonstrated reliable unattended operation.

## Verified reference run

The 2026-09-06 reference run used macOS 26.6.2, Safari 26.6.2, built-in speakers, and Studio Display XDR. It completed in 35.26 seconds with no cleanup errors and no system-default-output change.

| Check | Result | Assertion interval |
| --- | --- | --- |
| Initial playback on A | Passed | 12.64 s |
| Drag A → B | Passed | 2.53 s |
| Drag B → A | Passed | 2.51 s |
| Focus silent window on B; playback remains on A | Passed | 2.47 s |

These intervals include observation and stability checks; they are not measurements of audible switching latency. The complete checks finished 3.42 s and 3.34 s after mouse release for the two moves. The actual HAL output UID matched each expected device, with advancing capture, render, and non-silent counters. The run recorded 4,608 overflow frames during switching and zero underflow frames at the reported checkpoints. The smoke test therefore verifies destination following, not glitch-free audio quality.

One successful run does not establish long-run reliability. Extended repetition, deliberately injected native failures, fullscreen, and physical audio measurement remain unverified. The local HTML/JSON/JUnit/trace artifacts are kept in ignored `build/e2e-results/2026-09-06-smoke/`; machine-specific configuration and generated media are not committed.

## Implementation notes

- Python handles orchestration, the loopback-only HTTP server, assertions, and reports; a signed Swift helper handles macOS APIs. This keeps the first milestone dependency-free and easy to test.
- The E2E app publishes atomic JSON snapshots at 10 Hz into an owner-only run directory. Snapshots carry a run ID, instance ID, and increasing sequence. A local read-only socket and complete transition-event history from the broader design are deferred. The trace is sampled state, so sub-sample transitions are not claimed as observed.
- Actual device readback and audio snapshots are taken only when a route is running and has no switch task, avoiding access during asynchronous renderer teardown. Nothing is added to real-time callbacks.
- Safari window matching uses unique fixture titles, and cleanup checks fixture URLs. The fixture uses up to 1000 pixels of width to leave usable toolbar space. The drag point is chosen from empty space between live toolbar controls and verified with an accessibility hit test. This supports compact Safari toolbars whose address field occupies the old fixed drag point. A layout that does not respond to that drag fails geometry verification instead of falling back to placement and claiming success.
- Initial timing budgets are configurable: 15 seconds for initial routing, 5 seconds after geometry settling for moves, and 1 second of stable correct output with continuing audio progress. Reports also include elapsed time from the drag's mouse release. These are starting test budgets, not measured product performance guarantees.
