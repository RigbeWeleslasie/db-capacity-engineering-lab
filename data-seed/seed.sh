#!/usr/bin/env bash
# =============================================================================
# seed.sh
# -----------------------------------------------------------------------------
# Seeds the capacity_lab MySQL database with representative production-scale
# data so the local environment behaves like the real service:
#   * patients : 100,000 rows
#   * hospitals: 5 rows
#
# Intended to be executed from INSIDE the capacity-api container, which has the
# mysql client installed and can resolve `mysql-db` on the compose network:
#
#     docker compose exec capacity-api bash /usr/local/bin/seed.sh
#
# Re-runnable: it DROPs and recreates the tables each run.
# =============================================================================
set -euo pipefail

MYSQL_HOST="${MYSQL_HOST:-mysql-db}"
MYSQL_PORT="${MYSQL_PORT:-3306}"
MYSQL_USER="${MYSQL_USER:-root}"
MYSQL_PASSWORD="${MYSQL_PASSWORD:-labpassword}"
MYSQL_DATABASE="${MYSQL_DATABASE:-capacity_lab}"
ROW_COUNT="${ROW_COUNT:-100000}"

# Disable SSL for this local/lab-only traffic on the compose network (not a
# real production connection -- that's Aiven-over-TLS, handled separately by
# secrets.js's DB_CA_CERT_PATH). MySQL 8.0 auto-generates a self-signed cert
# and enables SSL by default; without disabling it the client's own default
# verification then fails with "Certificate verification failure: The
# certificate is NOT trusted."
#
# The FLAG for "disable SSL" isn't the same across client builds, and this
# broke silently once before: the Oracle MySQL client (5.7+) uses
# `--ssl-mode=DISABLED`; a MariaDB-flavored client (which `apk upgrade` can
# pull in on Alpine, exactly what happened here) rejects that as "unknown
# variable" and instead wants `--skip-ssl`. Detect which one this client
# actually supports rather than hardcoding either.
if mysql --help --verbose 2>/dev/null | grep -q -- '--ssl-mode='; then
  SSL_DISABLE_FLAG="--ssl-mode=DISABLED"
else
  SSL_DISABLE_FLAG="--skip-ssl"
fi
MYSQL=(mysql -h "${MYSQL_HOST}" -P "${MYSQL_PORT}" -u "${MYSQL_USER}" "-p${MYSQL_PASSWORD}" "${SSL_DISABLE_FLAG}")

echo ">> Waiting for MySQL at ${MYSQL_HOST}:${MYSQL_PORT} ..."
until "${MYSQL[@]}" -e "SELECT 1" >/dev/null 2>&1; do
  echo "   ...still waiting"
  sleep 2
done
echo ">> MySQL is up."

echo ">> Creating schema and loading ${ROW_COUNT} patient rows (this may take a minute) ..."
"${MYSQL[@]}" <<SQL
CREATE DATABASE IF NOT EXISTS ${MYSQL_DATABASE};
USE ${MYSQL_DATABASE};

DROP TABLE IF EXISTS patients;
DROP TABLE IF EXISTS hospitals;

CREATE TABLE patients (
  id           INT AUTO_INCREMENT PRIMARY KEY,
  first_name   VARCHAR(64)  NOT NULL,
  last_name    VARCHAR(64)  NOT NULL,
  email        VARCHAR(128) NOT NULL,
  diagnosis    VARCHAR(255) NOT NULL,
  notes        TEXT         NOT NULL,
  created_at   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP,
  -- OPS-2201 fix: GET /api/patients/search filters on last_name. Without an
  -- index this is a full table scan (100,000 rows examined per request; see
  -- evidence/OPS-2201-explain.txt). Under shift-change concurrency, competing
  -- scans saturate DB CPU/buffer-pool latching and back up the app's 2-slot
  -- connection pool, stalling *every* endpoint sharing it (see
  -- evidence/OPS-2201-recent-during-search.txt) -- not just search, contrary
  -- to the ticket's claim that other endpoints are unaffected.
  KEY idx_patients_last_name (last_name)
) ENGINE=InnoDB;

CREATE TABLE hospitals (
  id             INT AUTO_INCREMENT PRIMARY KEY,
  name           VARCHAR(128) NOT NULL,
  available_beds INT          NOT NULL DEFAULT 1000
) ENGINE=InnoDB;

INSERT INTO hospitals (name, available_beds) VALUES
  ('General Hospital',        1000000),
  ('St. Mary Medical Center', 1000000),
  ('Lakeside Clinic',         1000000),
  ('Mountain View Hospital',  1000000),
  ('Riverside Health',        1000000);

-- Bulk-generate patients with a recursive CTE. Last names are drawn from a
-- fixed pool so common names (e.g. 'Smith') match many rows, as in real data.
SET SESSION cte_max_recursion_depth = ${ROW_COUNT};

INSERT INTO patients (first_name, last_name, email, diagnosis, notes)
WITH RECURSIVE seq (n) AS (
  SELECT 1
  UNION ALL
  SELECT n + 1 FROM seq WHERE n < ${ROW_COUNT}
)
SELECT
  ELT(1 + (n % 8), 'Alice','Bob','Carol','David','Eve','Frank','Grace','Heidi'),
  ELT(1 + (n % 10), 'Smith','Johnson','Williams','Brown','Jones','Garcia','Miller','Davis','Rodriguez','Martinez'),
  CONCAT('patient', n, '@example.com'),
  ELT(1 + (n % 5), 'Hypertension','Diabetes','Asthma','Fracture','Migraine'),
  REPEAT(CONCAT('Clinical note for patient ', n, '. '), 6)
FROM seq;

SELECT CONCAT('patients rows: ', COUNT(*)) AS seeded FROM patients;
SELECT CONCAT('hospitals rows: ', COUNT(*)) AS seeded FROM hospitals;
SQL

echo ">> Seed complete."
