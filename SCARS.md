# 🩹 Scar Log — Regional Health On-Call Lab

One-screen record per incident. Full evidence and capacity math in
[`LAB_JOURNAL.md`](./LAB_JOURNAL.md); raw artifacts in [`evidence/`](./evidence/).

---

## OPS-2201 — Missing index turned a common surname into a full table scan, and the oversized result also starved an "unrelated" endpoint

- **S — Symptom:** Patient search p95 hit **14.77s** under a 200-VU
  shift-change burst (baseline p95: 4.96ms — a ~2977x regression). `GET
  /api/patients/search?lastName=Smith` returned all **10,000** matching rows
  as a **3.6MB** JSON payload.
- **C — Cause:** No index on `patients.last_name` → MySQL full-scans all
  100,000 rows on every search (`EXPLAIN ANALYZE`: `Table scan ...
  rows=100000`). Adding the index alone barely helped (p95 stayed ~16s)
  because the *real* second bottleneck was shipping every one of 10,000
  matches as one giant JSON response, pinning the single Node event loop at
  171% CPU serializing it.
- **A — Action:** Added `KEY idx_patients_last_name (last_name)` **and**
  capped the search endpoint to `LIMIT 50` (newest-first). Both changes were
  needed — the index alone didn't fix it.
- **R — Result:** p95 14.77s → 181ms (**~82x**), RPS 19.7/s → 1233.8/s
  (**~63x**), payload 3.6MB → 18KB (**~199x**). 0% errors before and after.
- **Scar / lesson:** *An index fix that doesn't move the needle under load
  means you haven't found the real bottleneck yet — keep watching CPU per
  tier, not just the query plan.* Also: the ticket claimed "recent patients"
  was unaffected — it wasn't (10-14s stalls measured directly) — because it
  shared the same starved connection pool. Never trust "endpoint X is fine"
  without testing X *during* the incident, not in isolation. A p95-latency
  alert on `/api/patients/search` plus a `NO_INDEX_USED` slow-query alert
  would have caught this in staging.
- **Confirmed (Assignment 2):** replayed this exact load against the
  monitored stack with the fix reverted — `OPS2201_SearchLatencyHigh` fired
  for real (p95=19.36s), not just predicted. See
  `evidence/02-incident-replay/OPS-2201-alert-firing.json`.
- **Evidence:** `LAB_JOURNAL.md` § OPS-2201; `evidence/OPS-2201-explain.txt`,
  `evidence/OPS-2201-repro-output.txt`, `evidence/OPS-2201-fixed-output.txt`,
  `evidence/OPS-2201-fixed2-output.txt`,
  `evidence/OPS-2201-recent-during-search.txt` /
  `-AFTER.txt`; fix commits touch `data-seed/seed.sh` and `api/server.js`.

---

## OPS-2202 — A 2-connection pool queued every request in the app tier while the database sat idle

- **S — Symptom:** Under a 2000-VU registration surge, even the trivial
  `GET /api/patients/recent` (a `<5ms` indexed query) hit p95 **1.76s**.
  DBAs correctly reported the database as idle: **27% CPU**, both pool
  connections showing `Sleep` in `SHOW PROCESSLIST`.
- **C — Cause:** `connectionLimit: 2` in `api/database.js` — only 2 requests
  can ever be executing a query at once; everyone else queues **inside the
  Node process** (mysql2's internal wait queue), invisible to any DB
  dashboard. Little's Law: L≈2000, λ≈1164.7/s ⇒ W≈1.72s, matching the
  measured p95 almost exactly; the query only needed ~6 connections to clear
  that load without queueing — 2 was undersized by >100x.
- **A — Action:** First tried `connectionLimit: 20, queueLimit: 200` (bound
  the queue to fail fast) — **error rate jumped to 84.88%** (`"Queue limit
  reached."`), worse than the original silent-queueing behavior. Settled on
  `connectionLimit: 50, queueLimit: 2000`.
- **R — Result:** p95 1.76s → ~0.64-0.70s (**~2.5-2.7x**), error rate
  0.66-0.68% (bounded and small, vs. an unbounded-but-invisible 1.76s stall
  for 100% of requests before). DB CPU stayed ~28% throughout — confirmed the
  app's own event-loop CPU (130%+) is the next ceiling, not the database.
- **Scar / lesson:** *"The database is idle" is not the same as "the database
  is not the bottleneck" — check the app-tier connection pool before
  clearing the DB.* Also: **raising a limit without raising it *enough* can
  make error rate worse, not better** — a bounded queue only helps once
  capacity actually clears the offered load. A pool queue-depth/wait-time
  metric (which this app doesn't currently export) is the single alert that
  would have caught this before "DB CPU looks fine" sent the investigation
  the wrong way.
- **Confirmed (Assignment 2):** replayed with the pool unbounded again —
  `OPS2202_RecentEndpointLatencyHigh` fired for real (p95=1.89s, 0.00%
  errors — pure latency, exactly the ticket's own claim), not just
  predicted. See `evidence/02-incident-replay/OPS-2202-alert-firing.json`.
- **Evidence:** `LAB_JOURNAL.md` § OPS-2202; `evidence/OPS-2202-repro-output.txt`,
  `evidence/OPS-2202-mid-evidence.txt`, `evidence/OPS-2202-fixed-output.txt`
  (the worse attempt), `evidence/OPS-2202-fixed2-output.txt`; fix commit
  touches `api/database.js`.

---

## OPS-2203 — A 500ms external call inside a transaction turned a single hospital's admissions into a 2-per-second bottleneck

- **S — Symptom:** 500 concurrent admissions to the same hospital: **78.42%
  failed** with `ER_LOCK_WAIT_TIMEOUT` ("Lock wait timeout exceeded"), p95
  **50.76s**, only ~1.97 admits/sec actually succeeded.
- **C — Cause:** `POST /api/hospitals/:id/admit` ran
  `UPDATE ... WHERE id=?` (takes an exclusive row lock) then **awaited a
  simulated 500ms external call `notifyBedRegistry()` before `COMMIT`** —
  holding the lock for ~500ms instead of the <1ms the update needs.
  `sys.innodb_lock_waits` showed 47 concurrent waiters queued behind that one
  row, all timing out at `innodb-lock-wait-timeout=5`. Max throughput for one
  row = 1/W = 1/0.5s = 2/s, no matter how many callers piled on — confirmed:
  measured 1.97/s.
- **A — Action:** Moved `notifyBedRegistry()` to *after* `COMMIT`
  (fire-and-forget, logged on failure), then dropped the explicit
  `BEGIN`/`COMMIT` entirely since a single `UPDATE` is already atomic under
  autocommit (1 round trip instead of 3).
- **R — Result:** Error rate 78.42% → **0%**; successful throughput 1.97/s →
  264.5/s (**~134x**). p95 stayed ~2s — not a bug, but the hard ceiling of
  500 concurrent writers serializing on one row (Little's Law: L≈500,
  λ≈264.5/s ⇒ W≈1.89s, matches).
- **Scar / lesson:** *Never hold a database lock across an external network
  call.* The fix bought back two orders of magnitude of throughput just by
  shrinking the critical section — no schema change, no new hardware. The
  residual ~2s p95 is a reminder that single-row write concurrency has a
  hard physical ceiling that connection-pool or index tuning cannot fix; that
  needs an architectural change (sharded counters, async coalescing) if ever
  required. An alert on `db_errors_total{code="ER_LOCK_WAIT_TIMEOUT"}` would
  have caught this building up before the mass-casualty drill made it acute.
- **Confirmed (Assignment 2):** replayed with the notify-before-commit
  ordering restored — `OPS2203_AdmissionDbErrors` fired for real (78.42%
  failed, 429/547, `ER_LOCK_WAIT_TIMEOUT`), not just predicted. See
  `evidence/02-incident-replay/OPS-2203-alert-firing.json`.
- **Evidence:** `LAB_JOURNAL.md` § OPS-2203; `evidence/OPS-2203-repro-output.txt`,
  `evidence/OPS-2203-locks.txt` / `-locks-full.txt` (InnoDB lock-wait
  evidence), `evidence/OPS-2203-fixed-output.txt`,
  `evidence/OPS-2203-fixed2-output.txt`; fix commit touches `api/server.js`.

---

## OPS-2204 — Buffering the entire 100k-row export in memory OOM-killed the process on a single request

- **S — Symptom:** A **single** call to `GET /api/patients/export` crashed
  the service — `RestartCount` incremented immediately, memory spiked to
  123-158MB against a 160MB container limit, kernel `dmesg` confirmed a
  cgroup OOM-kill (`anon-rss:155908kB`). Because the whole process died,
  every other in-flight request died with it.
- **C — Cause:** `SELECT * FROM patients` buffered all 100,000 rows into JS
  objects, then `res.json()` built one ~36MB JSON string before writing
  anything to the socket — O(N) memory (table is only ~31MB on disk, but
  live memory hit ~5x that). `NODE_OPTIONS=--max-old-space-size=256` let V8
  believe it could grow past the container's real 160MB limit, so the kernel
  killed the process outright instead of V8 throttling gracefully.
- **A — Action (two attempts):** (1) Streamed rows to the response instead
  of buffering — stopped the crash, but one `res.write()` per row (100,000
  syscalls/export) under 50 concurrent callers collapsed throughput (p95
  ~2m7s, memory back up to 99% of the limit). (2) Batched 200 rows per
  `res.write()` **and** capped concurrent exports to 4 in-process
  (503 + Retry-After beyond that).
- **R — Result:** `RestartCount` stayed **0** across a full 50-VU/2-minute
  reproduction (vs. crashing on request #1 before). Memory held steady at
  **~78MB/49%** of the limit throughout. 236 real exports completed
  successfully; 36,678 excess requests got a clean, fast 503 (<5ms) instead
  of piling onto a process that would otherwise die.
- **Scar / lesson:** *"Stream it" is necessary but not sufficient — batch
  the writes too, or you trade an OOM crash for an event-loop stall that
  looks almost as bad.* And: an unbounded number of concurrent expensive
  operations is its own capacity problem, separate from any one operation's
  memory footprint — bounding concurrency explicitly (with a clear, fast
  rejection) is a legitimate fix, not a cop-out. A `nodejs_heap_size_used_bytes`
  threshold alert plus a restart-count alert would have paged on the first
  crash instead of a repeated-restart storm.
- **Confirmed (Assignment 2) — with a twist:** the proposed
  `nodejs_heap_size_used_bytes` threshold alert never fired across ~30
  rounds of continuous polling during replay — the OOM-kill happens faster
  than a single 5s Prometheus scrape can catch a sustained breach. Added a
  second alert, `OPS2204_TargetDown` (`up{job="capacity-api"}==0`), which
  treats the crash-loop's own unreachability as the signal instead of
  trying to sample the spike — confirmed firing for real (container
  `RestartCount` 20→39 over the replay). *Lesson: a plausible alert design
  can still miss the real failure if its `for:` window loses the race with
  the failure mode's own timescale — only replaying the actual incident
  against it proves that.* See
  `evidence/02-incident-replay/OPS-2204-alert-firing.json`.
- **Evidence:** `LAB_JOURNAL.md` § OPS-2204; `evidence/OPS-2204-dmesg-oom.txt`,
  `evidence/OPS-2204-single-request-memtrace.txt`,
  `evidence/OPS-2204-fixed-output.txt` (streaming-only attempt),
  `evidence/OPS-2204-fixed2-output.txt` (batched + capped, final); fix commit
  touches `api/server.js`.
