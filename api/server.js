'use strict';

/**
 * server.js
 * -----------------------------------------------------------------------------
 * Express API for the Regional Health admissions & patient-lookup service.
 *
 * Endpoints:
 *   GET  /api/patients/recent        Recent patients widget
 *   GET  /api/patients/search        Patient lookup by last name
 *   POST /api/hospitals/:id/admit    Admit a patient (decrement bed count)
 *   GET  /api/patients/export        Full patient export for the analytics team
 *   GET  /api/audit/ping             Mongo audit-store health probe
 *   GET  /metrics                    Prometheus metrics
 */

const express = require('express');
const client = require('prom-client');
const { getPool, pingMysql, getMongo } = require('./database');

const app = express();
app.use(express.json());

const PORT = Number(process.env.PORT || 3000);

// ---------------------------------------------------------------------------
// Prometheus metrics
// ---------------------------------------------------------------------------
const register = new client.Registry();
register.setDefaultLabels({ app: 'capacity-api' });

// Default process/GC/heap metrics.
client.collectDefaultMetrics({ register, gcDurationBuckets: [0.001, 0.01, 0.1, 1, 2, 5] });

const httpRequestDuration = new client.Histogram({
  name: 'http_request_duration_seconds',
  help: 'Duration of HTTP requests in seconds',
  labelNames: ['method', 'route', 'status_code'],
  buckets: [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10],
  registers: [register],
});

const httpRequestsTotal = new client.Counter({
  name: 'http_requests_total',
  help: 'Total number of HTTP requests',
  labelNames: ['method', 'route', 'status_code'],
  registers: [register],
});

const dbErrorsTotal = new client.Counter({
  name: 'db_errors_total',
  help: 'Total number of database errors by type',
  labelNames: ['route', 'code'],
  registers: [register],
});

// Per-request timing + counting middleware
app.use((req, res, next) => {
  const end = httpRequestDuration.startTimer();
  res.on('finish', () => {
    const route = req.route ? req.baseUrl + req.route.path : req.path;
    const labels = { method: req.method, route, status_code: res.statusCode };
    end(labels);
    httpRequestsTotal.inc(labels);
  });
  next();
});

// ---------------------------------------------------------------------------
// Liveness vs. readiness (Assignment 2, C4) — two different questions.
//
// Liveness: is the process alive, or hung and in need of a restart? Answering
// this never touches the DB — a slow/down DB is a readiness problem, not a
// reason to kill and restart an otherwise-healthy process.
//
// Readiness: can this instance serve a request right now? A cold instance is
// alive (it's listening) well before its DB connection/secret resolution is
// ready — pingMysql() is what tells the caller (modules/service's nginx
// auth_request) the difference. /health is kept as a back-compat alias of
// /healthz for existing local tooling/docs.
// ---------------------------------------------------------------------------
app.get('/health', (_req, res) => res.json({ status: 'ok' }));
app.get('/healthz', (_req, res) => res.json({ status: 'ok' }));

app.get('/readyz', async (_req, res) => {
  try {
    await pingMysql();
    res.json({ status: 'ready' });
  } catch (err) {
    // 503, not 500 — this is "not ready yet / not ready right now", not an
    // application error. modules/service's nginx maps this straight through
    // so probes see real state, and gates all other traffic behind it.
    res.status(503).json({ status: 'not_ready', reason: err.message });
  }
});

app.get('/metrics', async (_req, res) => {
  res.set('Content-Type', register.contentType);
  res.end(await register.metrics());
});

// ---------------------------------------------------------------------------
// Recent patients widget
// ---------------------------------------------------------------------------
app.get('/api/patients/recent', async (_req, res) => {
  try {
    const pool = await getPool();
    const [rows] = await pool.query(
      'SELECT * FROM patients ORDER BY id DESC LIMIT 50'
    );
    res.json({ count: rows.length, data: rows });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/recent', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Patient lookup by last name
//
// OPS-2201: indexing last_name (see data-seed/seed.sh) fixes the DB-side cost
// (full table scan -> index lookup) but does NOT fix shift-change latency on
// its own -- a common surname still matches ~10,000 rows, and shipping every
// match as a ~3.6MB JSON payload pins the single Node event loop (measured
// 170%+ CPU) serializing/writing the response, long after MySQL has the rows.
// Capping the result set bounds both the rows MySQL has to touch (LIMIT lets
// the index lookup stop early) and the bytes the app has to serialize.
// ---------------------------------------------------------------------------
const MAX_SEARCH_RESULTS = 50;

app.get('/api/patients/search', async (req, res) => {
  const lastName = req.query.lastName || '';
  const limit = Math.min(Number(req.query.limit) || MAX_SEARCH_RESULTS, MAX_SEARCH_RESULTS);
  try {
    const pool = await getPool();
    const [rows] = await pool.query(
      'SELECT * FROM patients WHERE last_name = ? ORDER BY id DESC LIMIT ?',
      [lastName, limit]
    );
    res.json({ count: rows.length, lastName, data: rows });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/search', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Admit a patient to a hospital (decrement available beds).
//
// OPS-2203: this used to call notifyBedRegistry() (a simulated 500ms network
// round trip) *before* COMMIT, inside the same transaction as the UPDATE.
// The UPDATE takes an exclusive row lock (X, REC_NOT_GAP on the PRIMARY
// index -- see evidence/OPS-2203-locks.txt) that MySQL can't release until
// COMMIT/ROLLBACK, so every admit to the same hospital held that lock for
// ~500ms instead of the <1ms the UPDATE itself needs. Concurrent admits to
// the same row serialize on that lock (InnoDB enforces it to give
// transactions repeatable, isolated writes -- this is 2PL row locking, not a
// bug in InnoDB), so max throughput for one hospital was bounded by
// 1 / (lock hold time) =~ 1 / 0.5s = 2 admits/sec no matter how many callers
// piled on. With innodb-lock-wait-timeout=5 (docker-compose.yml) and 500
// concurrent callers well beyond that ceiling, most waiters exceeded 5s and
// failed with ER_LOCK_WAIT_TIMEOUT ("Lock wait timeout exceeded; try
// restarting transaction") -- confirmed count: 507 in
// evidence/OPS-2203-repro-output.txt. Measured successful throughput was
// ~1.97 admits/sec (118 succeeded / 60s), matching the 2/s prediction.
//
// Fix: shrink the critical section to just the UPDATE, and notify the
// registry outside it so the row lock is held for the write alone.
// Trade-off: the registry notification is no longer pre-commit-atomic with
// the bed decrement -- if notifyBedRegistry() fails or the process dies
// right after, the registry can miss an update. A production fix would make
// that notification durable (outbox table + async retry) rather than
// best-effort; here we log so on-call can see it.
//
// A single UPDATE is already atomic in MySQL under autocommit, so we also
// drop the explicit BEGIN/COMMIT: `pool.query` needs one round trip instead
// of three (BEGIN, UPDATE, COMMIT), shaving the remaining lock-hold time
// further. Measured: this single change raised same-row throughput from
// ~221.6/s to ~264.5/s, 0 errors either way (evidence/OPS-2203-fixed2-
// output.txt) -- p95 latency is still ~2s because 500 concurrent writers to
// ONE row cannot beat 1/W_lock no matter how small W_lock gets; this is the
// fundamental ceiling of single-row 2PL, not a leftover bug.
// ---------------------------------------------------------------------------
app.post('/api/hospitals/:id/admit', async (req, res) => {
  const hospitalId = Number(req.params.id);
  const pool = await getPool();
  try {
    await pool.query(
      'UPDATE hospitals SET available_beds = available_beds - 1 WHERE id = ?',
      [hospitalId]
    );
    res.json({ status: 'admitted', hospitalId });

    // Best-effort, outside the critical section: the row lock is already released.
    notifyBedRegistry(hospitalId).catch((err) => {
      // eslint-disable-next-line no-console
      console.error(`bed registry notify failed for hospital ${hospitalId}:`, err.message);
    });
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/hospitals/:id/admit', code: err.code || 'UNKNOWN' });
    res.status(500).json({ error: err.code || 'ERROR', message: err.message });
  }
});

// Stand-in for the external registry client used by the admit flow.
function notifyBedRegistry(_hospitalId) {
  return new Promise((r) => setTimeout(r, 500));
}

// ---------------------------------------------------------------------------
// Full patient export for the analytics/ETL team.
//
// OPS-2204: `pool.query('SELECT * FROM patients')` buffers every row of the
// result set into JS objects, then res.json() builds one giant string from
// all of them and hands it to the socket in one shot. Measured: a SINGLE
// export call pushed capacity-api's RSS to ~155MB (dmesg cgroup OOM-kill log
// in evidence/OPS-2204-dmesg-oom.txt: "anon-rss:155908kB") against the
// 160MB container limit, and killed the process -- confirmed by
// RestartCount incrementing and a fresh "listening on :3000" line in
// container logs. The table itself is only ~31MB on disk (100,000 rows,
// information_schema.TABLES DATA_LENGTH+INDEX_LENGTH), so the buffered
// request/response path multiplies that ~5x in live heap (parsed row
// objects + the full JSON string + Node's unstreamed HTTP write buffer, all
// resident at once) -- O(N) memory that scales with table size and stacks
// per concurrent caller, not O(1).
//
// Fix (attempt 1): stream rows from MySQL straight to the HTTP response as
// they arrive instead of buffering the whole result set. That alone stopped
// the OOM-kill (RestartCount stayed 0 across a full reproduce-OPS-2204.js
// run -- evidence/OPS-2204-fixed-output.txt) but under the ticket's 50
// concurrent callers memory still sat at 158.5MiB/160MiB (99%, see
// conversation evidence) and p95 latency exploded to ~2m7s with 57% client
// timeouts: one res.write() call per row means 100,000 syscalls per export,
// and 50 concurrent streams doing that saturates the single event loop --
// we'd traded an OOM crash for a throughput collapse.
//
// Fix (attempt 2, kept): batch EXPORT_BATCH_SIZE rows into one res.write()
// call (cuts syscalls ~200x) AND cap MAX_CONCURRENT_EXPORTS in-process, so
// peak memory is bounded by (concurrent exports x batch size) instead of
// scaling with either table size or caller count. A real nightly ETL job
// needs one export, not fifty in parallel; a burst past the cap gets a fast
// 503 + Retry-After instead of silently competing for the same limited
// memory/event-loop budget as everyone else. See evidence/OPS-2204-fixed2-*
// for the re-run with both changes in place.
// ---------------------------------------------------------------------------
const EXPORT_BATCH_SIZE = 200;
const MAX_CONCURRENT_EXPORTS = 4;
let activeExports = 0;

app.get('/api/patients/export', async (_req, res) => {
  if (activeExports >= MAX_CONCURRENT_EXPORTS) {
    res.set('Retry-After', '5');
    return res.status(503).json({
      error: 'EXPORT_BUSY',
      message: `Too many concurrent exports in flight (limit ${MAX_CONCURRENT_EXPORTS}); retry shortly.`,
    });
  }
  activeExports += 1;

  const pool = await getPool();
  let conn;
  try {
    conn = await pool.getConnection();
    // mysql2/promise wraps the callback-style connection; that raw
    // connection is what exposes .query(sql).stream().
    const queryStream = conn.connection
      .query('SELECT * FROM patients')
      .stream({ highWaterMark: 500 });

    res.setHeader('Content-Type', 'application/json');
    res.write('{"data":[');

    let count = 0;
    let wroteAny = false;
    let batch = [];

    const flushBatch = () => {
      if (batch.length === 0) return true;
      const ok = res.write((wroteAny ? ',' : '') + batch.join(','));
      wroteAny = true;
      batch = [];
      return ok;
    };

    await new Promise((resolve, reject) => {
      queryStream.on('data', (row) => {
        batch.push(JSON.stringify(row));
        count += 1;
        if (batch.length >= EXPORT_BATCH_SIZE && !flushBatch()) {
          queryStream.pause();
          res.once('drain', () => queryStream.resume());
        }
      });
      queryStream.on('end', () => {
        flushBatch();
        resolve();
      });
      queryStream.on('error', reject);
    });

    res.end(`],"count":${count}}`);
  } catch (err) {
    dbErrorsTotal.inc({ route: '/api/patients/export', code: err.code || 'UNKNOWN' });
    if (!res.headersSent) {
      res.status(500).json({ error: err.code || 'ERROR', message: err.message });
    } else {
      // Already streaming a 200 -- can't change status now; just end the
      // response so the client doesn't hang on a truncated body forever.
      res.end();
    }
  } finally {
    if (conn) conn.release();
    activeExports -= 1;
  }
});

// ---------------------------------------------------------------------------
// Mongo audit-store health probe
// ---------------------------------------------------------------------------
app.get('/api/audit/ping', async (_req, res) => {
  try {
    const db = await getMongo();
    const result = await db.command({ ping: 1 });
    res.json({ mongo: result });
  } catch (err) {
    res.status(500).json({ error: 'MONGO_ERROR', message: err.message });
  }
});

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------
app.listen(PORT, () => {
  // eslint-disable-next-line no-console
  console.log(`capacity-api listening on :${PORT} (metrics at /metrics)`);
});
