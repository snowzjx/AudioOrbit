# AudioOrbit performance budgets

These are release gates, not claims about every Mac or output. Record the Mac model, macOS version, output transports and sample rates with every result. Bluetooth latency is reported separately because its codec and radio buffering are outside AudioOrbit's control.

## Audio

| Measurement | Release budget |
| --- | --- |
| Added wired routing latency | Less than 100 ms, measured end to end |
| Stable-route underflow/overflow | No recurring faults after the 3-second warm-up |
| Steady peak queue occupancy | Below 90% after warm-up |
| Route switch | No sustained duplicate audio and no audible click in the manual matrix |
| Drift | Queue remains bounded during the 30-minute different-rate run |

The support report's `estimated-buffer-latency` is the target queue depth divided by the output sample rate. It is useful for regression comparison but does not replace loopback measurement of total acoustic/electrical latency.

## Resources

| Scenario | Release budget on reference Apple-silicon hardware |
| --- | --- |
| Disabled, no routes | Less than 1% average CPU and no high-frequency polling |
| Two routes / two outputs | Less than 6% average app CPU |
| Four routes / mixed rates | Less than 12% average app CPU |
| One-hour four-route run | Less than 20 MB resident-memory growth after initial warm-up |
| Real-time callbacks | No deadline misses attributable to allocation, locks, logging or UI work |

Use Instruments' Time Profiler, System Trace, Allocations and Audio templates where available. AudioOrbit emits `Hardware refresh` and `Route transition` signposts in the `me.snowzjx.AudioOrbit` subsystem. The in-app support report includes process CPU time, resident memory and per-route buffer counters.

## Recording a result

For each run, retain:

- A support report from the beginning and end.
- The `.trace` recording when profiling is required.
- The exact build number and code-signing identity.
- Pass/fail notes for audible clicks, duplicate audio and pass-through recovery.

Never attach captured audio to a support report. If a loopback recording is needed for engineering measurement, store and share it separately with explicit consent.
