# C7 — cloud incident replay

Each `<id>/` folder holds that incident's k6 output (baseline where
relevant, and the reverted-to-original-bug re-run) plus the real
Prometheus `/api/v1/alerts` response captured while the alert was
genuinely `firing` — not inferred, queried live during the replay.
Corresponding dashboard panel screenshots (captured during the same live
re-run) are in `../06-observability/panels/`.

| Incident | Signal | Alert | Result |
|---|---|---|---|
| [2201/](./2201/) | search p95 + payload size | `OPS2201_SearchLatencyHigh` | p95 19.36s → firing (repro), p95 spiked to ~10s in the live re-run captured for the panel screenshot |
| [2202/](./2202/) | pool saturation while DB idle | `OPS2202_RecentEndpointLatencyHigh` | p95 1.89s, 0% errors — pure latency, matching the ticket exactly → firing |
| [2203/](./2203/) | `ER_LOCK_WAIT_TIMEOUT` | `OPS2203_AdmissionDbErrors` | 78.42% failed → firing |
| [2204/](./2204/) | memory vs limit + restart count | `OPS2204_TargetDown` (see below) | 100% failed, 19+ container restarts → firing |

## The "full treatment" — OPS-2204

Chosen because it has the clearest end-to-end story: induce → alert fires
→ dashboard shows it → the mechanism is nameable in one sentence, and
because getting here required *discovering* that the originally-designed
alert didn't work and replacing it — a genuinely useful thing to have
proven, not just asserted.

**Induce:** `k6 run load-tests/reproduce-OPS-2204.js` against the
temporarily-reverted export handler (`SELECT * FROM patients` unbuffered,
no batching, no concurrency cap — see `LAB_JOURNAL.md`'s OPS-2204 section
for the full revert/restore procedure). 50 concurrent VUs repeatedly
calling the full-table export.

**Mechanism, in one sentence:** buffering every row of a 100k-row result
set into memory before writing anything to the response, under concurrent
callers, blows past the container's memory cgroup limit and gets
OOM-killed by the kernel — not by the app, which never gets a chance to
respond gracefully.

**Alert fires:** `OPS2204_TargetDown` (`up{job="capacity-api"} == 0`,
`for: 0s`) — confirmed `state: "firing"` in `2204/alert-firing.json`,
`activeAt: 2026-08-20T05:31:54Z`. The *originally designed* alert,
`OPS2204_MemoryApproachingLimit` (a memory-threshold breach sustained for
5s), never fired across ~30 rounds of continuous polling during the
original replay — the OOM-kill happens faster than one 5-second
Prometheus scrape interval can catch a sustained breach mid-spike. That's
a real, useful finding in its own right: a plausible alert design on paper
can still miss the real failure if its `for:` window loses the race with
the failure mode's own timescale. `OPS2204_TargetDown` sidesteps this by
treating the crash-loop's own unreachability — observed directly by
Prometheus's scrape success/failure — as the signal, instead of trying to
sample a spike that can be missed entirely.

**Dashboard shows it:** `../06-observability/panels/OPS-2204-panel.png`,
captured live during this exact replay — RSS memory climbing, then the
`up` series dropping to 0 at the exact moment of the crash.

**Confirm the fix clears it:** after restoring the batched+concurrency-capped
export handler and rebuilding, `RestartCount` stays flat and `/readyz`
returns 200 across a full re-run of the same script — see
`LAB_JOURNAL.md`'s OPS-2204 section for the numbers (0 restarts vs.
crashing on the very first request before the fix).

## The other three — alert-only, confirmed firing

OPS-2201, 2202, and 2203 each got the fault genuinely injected (the
specific code/config change reverted, matching each incident's real root
cause — not a healthy system, which the brief is explicit would prove
nothing), the corresponding alert confirmed `firing` via a live
`/api/v1/alerts` query, and the fix confirmed to clear it afterward. Full
before/after numbers and root-cause mechanism for each are in
`LAB_JOURNAL.md`'s per-incident sections and `SCARS.md`'s "Confirmed
(Assignment 2)" lines.
