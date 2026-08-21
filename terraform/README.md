# Terraform root — capacity-api individual rehost

Wires the shared group platform modules from
[`nebyathhailu/regional-health-platform`](https://github.com/nebyathhailu/regional-health-platform)
to this specific service, per Assignment 2's individual-rehost checklist.
The group repo owns the reusable modules and the golden CI pipeline; this
root owns the composition + this service's specific values.

## What it stands up

- **`modules/data`** — Aiven MySQL connection details written into a Secrets
  Manager credential envelope. (Aiven itself is provisioned by hand — see
  `../README.md`'s Aiven setup steps once added — not by this Terraform.)
- **`modules/service`** — an EC2 instance running `capacity-api` behind a
  readiness-gated nginx, plus the ALB topology as IaC.

No `modules/network` here — `modules/data` doesn't need a VPC at all
(Aiven's external), and `modules/service` still does its own internal
VPC/subnet lookup (hasn't adopted `modules/network` yet).

## Module source pins

Both `source = "git::...?ref=<sha>"` lines in `main.tf` are pinned to a full
commit SHA, never a moving branch name — per the group repo's own
convention. Both currently point at the group repo's `main` HEAD as of
2026-08-21 (`c930bc6`, through PR #10). Re-pin periodically as the group repo
moves — `git log <old-sha>..origin/main --oneline` against a clone of
`nebyathhailu/regional-health-platform` shows what you'd be picking up, and
`git diff` on each module's `variables.tf` between the two SHAs shows whether
anything requires a change on this root's side (new required variables would;
new optional ones with defaults, like PR #9's `db_ca_cert`, don't).

## Before you can `plan`/`apply`

1. **Aiven MySQL** — sign up, create a free-tier service, copy host/port/
   password (see `modules/data`'s README in the group repo for the exact
   steps). Export as `TF_VAR_aiven_host`, `TF_VAR_aiven_port`,
   `TF_VAR_aiven_password` — never a tfvars file, never committed.
2. **`LOCALSTACK_AUTH_TOKEN`** — export it, and make sure whatever starts
   LocalStack passes it through (Hobby tier gates RDS/Secrets Manager/ECR
   etc. behind it — though this root doesn't use RDS or ECR anymore).
3. **`app_ami_id`** — the CI-tagged image (`localstack-ec2/app:ami-<sha12>`).
   No default; not yet produced by anything in this repo (CI wiring is a
   later piece of this rehost).
4. Run via **`tflocal`** (github.com/localstack/terraform-local), not
   `tofu`/`terraform` directly, when targeting LocalStack — it injects the
   endpoint overrides and dummy credentials LocalStack needs. `tofu fmt`/
   `tofu validate` are fine to run directly; they don't touch any endpoint.

## Known gaps (see `variables.tf`'s `app_env` docs for detail)

- **Mongo audit store** isn't part of Assignment 2's scope — `/api/audit/ping`
  will fail once deployed unless you separately stand up a reachable Mongo
  and set `MONGO_URI`/`MONGO_DB` via `app_env`.
- **Aiven's TLS CA cert** delivery to the instance isn't wired up from this
  root yet. `modules/service` (as of PR #9) now takes an optional
  `db_ca_cert` variable — pass the PEM content and it writes it to
  `/etc/app/db-ca.pem` on the instance and exports `DB_CA_CERT_PATH` in
  user-data itself, no CI-baked-AMI or fetch-at-boot logic needed on this
  side. Still open: get the actual PEM from Aiven's console and decide how
  it reaches this root (a `TF_VAR_db_ca_cert` env var, same discipline as
  `TF_VAR_aiven_password`, is the natural fit — never a tfvars file).

## Remote state

The group repo's `bootstrap/` root (added in PR #12) creates the shared
S3 + DynamoDB state store this root's commented-out `backend "s3" {}` block
(see `versions.tf`) is waiting on. It's run **once by hand** against
LocalStack, shared across the whole group — check with the group before
running it yourself in case someone already has. See its README in the group
repo for the exact `tflocal init -backend-config=...` invocation once it's
up.

## Testing

- `tofu fmt` + `tofu validate` clean.
- **Not yet applied** — needs `app_ami_id` from a real CI build and a real
  Aiven service. Tracking as the next piece of work.
