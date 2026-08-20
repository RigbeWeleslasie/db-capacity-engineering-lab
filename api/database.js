'use strict';

/**
 * database.js
 * -----------------------------------------------------------------------------
 * Connection factories for MySQL and MongoDB.
 */

const mysql = require('mysql2/promise');
const { MongoClient } = require('mongodb');
const { loadDbConfig } = require('./secrets');

// ---------------------------------------------------------------------------
// Environment configuration
//
// Connection identity (host/user/password/database/ssl) is resolved once at
// first use, by loadDbConfig() — from Secrets Manager when deployed
// (DB_SECRET_ARN set), from local env vars when not (see secrets.js). Only
// the pool *tuning* below is a static default; it isn't service-shaped or
// secret, so it stays a plain constant.
// ---------------------------------------------------------------------------
const POOL_TUNING = {
  // OPS-2202: connectionLimit: 2 meant only 2 requests could ever be "in
  // service" at once -- everything else queued *in the app tier* (mysql2's
  // internal waiter queue), not at the DB. Measured: with 2000 concurrent
  // callers hitting a <5ms indexed query, DB CPU stayed at 27% and both
  // connections showed "Sleep" in SHOW PROCESSLIST, while p95 latency hit
  // 1.76s purely from queueing (see evidence/OPS-2202-mid-evidence.txt).
  // Little's Law check: L (in-flight) ~= 2000, measured throughput
  // lambda ~= 1164 req/s => W = L/lambda ~= 1.72s, matching the observed p95.
  // At the query's real service time (~5ms), lambda=1164 req/s only needs
  // ceil(1164 * 0.005) ~= 6 concurrent connections to avoid queueing -- 2 was
  // undersized by >100x for this workload.
  //
  // First attempt: connectionLimit 20 / queueLimit 200. Worse: error rate
  // JUMPED to 84.88% (evidence/OPS-2202-fixed-output.txt) once in-flight
  // requests exceeded 20 + 200 = 220, all failing fast with mysql2's
  // "Queue limit reached." (confirmed in container logs). Bounding the
  // queue turns overload into *errors* instead of *latency* -- an
  // improvement only if capacity is actually enough to clear the offered
  // load. 220 wasn't, for a closed-loop 2000-VU surge with no client think
  // time.
  //
  // Settled on connectionLimit 50 / queueLimit 2000: p95 641ms (vs 1.76s
  // before), error rate 0.66% (vs the 84.88% first attempt), DB CPU stayed
  // at ~28% and Threads_running stayed at 2 throughout (evidence/
  // OPS-2202-fixed2-*), confirming MySQL still has slack -- capacity-api's
  // own event-loop CPU (130%+, >1 core) is the next bottleneck, not the
  // pool or the DB. That's the ceiling for a single app instance; going
  // past ~50 here buys nothing further without also scaling app replicas.
  // 50 is well under max_connections=151, leaving room for a second replica
  // and for OPS-2201's costlier search queries on the same server.
  // Restored to the fixed value for OPS-2203's test specifically — a small
  // connectionLimit bottlenecks at the pool level before requests even
  // reach MySQL's row lock, masking OPS-2203's actual mechanism. Already
  // captured OPS-2202's evidence with connectionLimit: 2 above.
  waitForConnections: true,
  connectionLimit: 50,
  queueLimit: 2000,
  connectTimeout: 10_000,
  maxIdle: 50,
  idleTimeout: 60_000,
  enableKeepAlive: true,
};

const MONGO_URI = process.env.MONGO_URI || 'mongodb://mongo-db:27017';
const MONGO_DB_NAME = process.env.MONGO_DB || 'capacity_lab';

// ---------------------------------------------------------------------------
// MySQL pool (singleton, lazily created)
//
// Async because resolving connection identity may mean a Secrets Manager
// round trip (loadDbConfig). Concurrent first-callers share one in-flight
// creation via poolPromise rather than racing to create the pool twice.
// ---------------------------------------------------------------------------
let pool;
let poolPromise;

async function getPool() {
  if (pool) return pool;
  if (!poolPromise) {
    poolPromise = (async () => {
      const config = await loadDbConfig();
      pool = mysql.createPool({ ...config, ...POOL_TUNING });
      return pool;
    })();
  }
  return poolPromise;
}

// ---------------------------------------------------------------------------
// Readiness check — used by /readyz, not /healthz. A cheap round trip that
// proves the pool can actually reach MySQL right now, distinct from "the
// process is up" (liveness). Bounded by its own short timeout so a hung DB
// doesn't hang readiness checks indefinitely.
// ---------------------------------------------------------------------------
async function pingMysql(timeoutMs = 2000) {
  const dbPool = await getPool();
  await Promise.race([
    dbPool.query('SELECT 1'),
    new Promise((_, reject) => setTimeout(() => reject(new Error('readiness ping timed out')), timeoutMs)),
  ]);
}

// ---------------------------------------------------------------------------
// MongoDB client (singleton, lazily connected)
// ---------------------------------------------------------------------------
let mongoClient;
let mongoDb;

async function getMongo() {
  if (!mongoDb) {
    mongoClient = new MongoClient(MONGO_URI, {
      maxPoolSize: 5,
      serverSelectionTimeoutMS: 5_000,
    });
    await mongoClient.connect();
    mongoDb = mongoClient.db(MONGO_DB_NAME);
  }
  return mongoDb;
}

// ---------------------------------------------------------------------------
// Graceful shutdown helpers
// ---------------------------------------------------------------------------
async function closeAll() {
  if (pool) {
    try { await pool.end(); } catch (_) { /* ignore */ }
    pool = undefined;
  }
  if (mongoClient) {
    try { await mongoClient.close(); } catch (_) { /* ignore */ }
    mongoClient = undefined;
    mongoDb = undefined;
  }
}

module.exports = {
  MONGO_URI,
  MONGO_DB_NAME,
  getPool,
  pingMysql,
  getMongo,
  closeAll,
};
