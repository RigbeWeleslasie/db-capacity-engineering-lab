# Regional Health — Reliability On-Call Lab 

A hands-on "Lab-in-a-Box" for learning **database mechanics, performance tuning,
and capacity engineering** the way you actually learn them on the job: by picking
up an incident ticket, reproducing the symptom, and investigating until you find
the root cause.

You are the on-call engineer for the **Regional Health** platform — a healthcare
API backed by MySQL. There is an [incident queue](./incidents/README.md) of open
tickets. Each ticket is a symptom report from a user or another team. **No ticket
tells you the cause, and there is no answer key in this repo.** You diagnose it
from evidence: query plans, connection behaviour, locks, and memory, observed
through Prometheus and Grafana.

> This is a training environment seeded with realistic data and realistic
> problems. Treat it like production you've just been handed.

---

## The environment

| Component        | Tech                  | Port  | Role                                  |
|------------------|-----------------------|-------|---------------------------------------|
| `capacity-api`   | Node.js + Express     | 3000  | The application under investigation   |
| `mysql-db`       | MySQL 8.0             | 3306  | Primary relational store              |
| `mongo-db`       | MongoDB 6.0           | 27017 | Audit store                           |
| `prometheus`     | Prometheus            | 9090  | Metrics scraping                      |
| `grafana`        | Grafana               | 3001  | Dashboards                            |
| load generator   | k6                    | —     | Reproduces each incident's traffic    |

---

## Quick start (3 steps)

### 1. Start the environment
```bash
docker compose up -d --build
```
Wait ~30–60s for MySQL to become healthy (`docker compose ps`).

### 2. Seed realistic data (100,000 patients, 5 hospitals)
The seed script runs *inside* the API container:
```bash
docker compose exec capacity-api bash /usr/local/bin/seed.sh
```

### 3. Open the dashboards
- **Grafana:**    http://localhost:3001  (user `admin` / pass `admin`; anonymous admin is also enabled)
- **Prometheus:** http://localhost:9090
- **API health:** http://localhost:3000/health
- **API metrics:** http://localhost:3000/metrics

In Grafana, add Prometheus as a data source at `http://prometheus:9090`, then
chart `http_request_duration_seconds`, `http_requests_total`,
`db_errors_total`, and `nodejs_heap_size_used_bytes`. Suggested queries are in
[`LAB_JOURNAL.md`](./LAB_JOURNAL.md).

---

## Your job: work the incident queue

Open **[`incidents/README.md`](./incidents/README.md)** and pick a ticket.

The general loop for every incident:

1. **Baseline** the healthy system so you have a control group:
   ```bash
   k6 run load-tests/00-baseline.js
   ```
2. **Reproduce** the reported symptom using that ticket's script, e.g.:
   ```bash
   k6 run load-tests/reproduce-OPS-2201.js
   ```
   (Each `reproduce-OPS-XXXX.js` recreates the *traffic pattern* from ticket
   `OPS-XXXX` — it does not tell you the cause.)
3. **Investigate** with the tools below while the load runs.
4. **Diagnose, fix, and re-run** to prove the fix.
5. **Write it up** in [`LAB_JOURNAL.md`](./LAB_JOURNAL.md).

> No installed k6? Run it in Docker (Linux host networking):
> ```bash
> docker run --rm -i --network host grafana/k6 run - < load-tests/reproduce-OPS-2201.js
> ```

---

## Investigation toolbox

```bash
# Follow the application logs (crashes, errors, restarts)
docker compose logs -f capacity-api

# Live memory / CPU / restart counts per container
docker stats

# Open a MySQL shell to inspect plans, locks, and schema
docker compose exec mysql-db mysql -uroot -plabpassword capacity_lab
```

Inside the MySQL shell, techniques worth knowing:
`EXPLAIN ANALYZE <query>`, `SHOW CREATE TABLE <t>`, `SHOW ENGINE INNODB STATUS`,
and the `performance_schema` / `sys` views for locking. Which ones matter for a
given ticket is part of the exercise.

---

## Teardown
```bash
docker compose down -v
```

---

## Assignment 2 — LocalStack rehost & CI security gates

On top of the on-call lab above, this repo is rehosted onto the shared group
platform modules from
[nebyathhailu/regional-health-platform](https://github.com/nebyathhailu/regional-health-platform)
and wired into a 5-gate CI pipeline. Quick links for anyone grading this part:

| Deliverable | Where |
|---|---|
| Liveness / readiness endpoints | [`api/server.js`](./api/server.js) — `/healthz`, `/readyz` |
| DB creds resolved from Secrets Manager at boot (never hardcoded) | [`api/secrets.js`](./api/secrets.js) — `loadDbConfig()` |
| Terraform rehost onto the group's `modules/data` + `modules/service` | [`terraform/main.tf`](./terraform/main.tf) |
| CI pipeline (gitleaks → trivy config → zizmor → docker build → trivy image → tflocal apply) | [`.github/workflows/ci.yml`](./.github/workflows/ci.yml) — calls the group's reusable `golden-ci.yml` |
| C1 evidence (real `tflocal apply` against LocalStack, incl. the two documented LocalStack Hobby-tier limitations) | [`evidence/01-iac/README.md`](./evidence/01-iac/README.md) |
| **Three deliberately-insecure "red PRs," one per gate** — Dockerfile non-root `USER` dropped ([#5](https://github.com/RigbeWeleslasie/db-capacity-engineering-lab/pull/5), `trivy config`), a fake credential committed ([#16](https://github.com/RigbeWeleslasie/db-capacity-engineering-lab/pull/16), `gitleaks`), a workflow ref unpinned to `@main` ([#17](https://github.com/RigbeWeleslasie/db-capacity-engineering-lab/pull/17), `zizmor`) | [`evidence/05-gates/README.md`](./evidence/05-gates/README.md) — all three left open, unmerged, each genuinely failing its gate |
| Grafana dashboard + a panel per incident, real screenshots captured live during each replay | [`evidence/06-observability/`](./evidence/06-observability/) |
| All four OPS incidents replayed against the *monitored* stack, with proof the corresponding Prometheus alert actually fires (not just "should have") | [`evidence/07-incidents/`](./evidence/07-incidents/), summarized in [`LAB_JOURNAL.md`](./LAB_JOURNAL.md#assignment-2--closing-the-loop-did-the-alerts-i-proposed-actually-fire) and each `SCARS.md` entry's "Confirmed (Assignment 2)" line |
| `FIDELITY.md` — where LocalStack didn't reproduce real AWS faithfully | [`FIDELITY.md`](./FIDELITY.md) |
| `make up` / `make verify` — one-command stand-up and verification | [`Makefile`](./Makefile) |
| E2 — OIDC design (writing-only Extended deliverable) | [`docs/E2-oidc-design.md`](./docs/E2-oidc-design.md) |

Good luck, on-call. 
