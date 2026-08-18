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
convention. **`modules/data`'s pin is temporary**: it points at the Aiven
rewrite's branch commit, not `main`, because that PR hasn't merged in the
group repo yet as of this writing. Re-pin to the post-merge commit on `main`
once it lands (the SHA doesn't change when a PR merges without a rebase/
squash, so check whichever the group repo actually did).

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
- **Aiven's TLS CA cert** delivery to the instance isn't solved yet — the CA
  cert isn't secret, so it doesn't belong in Secrets Manager, but *how* it
  gets onto the instance (baked into the CI-built AMI, fetched from Aiven's
  public URL at boot, etc.) is still an open decision. `DB_CA_CERT_PATH` in
  `app_env` is ready to be set once that's decided.

## Testing

- `tofu fmt` + `tofu validate` clean.
- **Not yet applied** — needs `app_ami_id` from a real CI build and a real
  Aiven service. Tracking as the next piece of work.
