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

## Remote state — done

The group repo's `bootstrap/` root (regional-health-platform#12, Meron)
creates the S3 + DynamoDB state store `versions.tf`'s `backend "s3" {}`
block now actually uses. Correction to an earlier note here: this is
**not** something to coordinate across the group before running — every
person's LocalStack is their own local emulator instance, so running the
bootstrap only ever touches your own machine, never anyone else's.

```bash
tflocal init \
  -backend-config="bucket=devops-g1-ls-tfstate" \
  -backend-config="key=db-capacity-engineering-lab/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="dynamodb_table=devops-g1-ls-tflock" \
  -backend-config="access_key=test" \
  -backend-config="secret_key=test" \
  -backend-config="skip_credentials_validation=true" \
  -backend-config="skip_metadata_api_check=true" \
  -backend-config="skip_requesting_account_id=true" \
  -backend-config='endpoints={s3="http://localhost:4566",dynamodb="http://localhost:4566",sts="http://localhost:4566",iam="http://localhost:4566"}' \
  -backend-config="use_path_style=true"
```

The extra `access_key`/`skip_*`/`endpoints`/`use_path_style` flags beyond
what the bootstrap's own README documents are needed because `tflocal`
patches *provider* config automatically but not the S3 *backend* block —
without them, `init` fails with `STS: GetCallerIdentity ...
InvalidClientTokenId` before it ever gets to the modules. Verified
end-to-end (not just configured): a real apply/destroy cycle against this
backend, with the state file genuinely appearing in (and shrinking back
down in) the S3 bucket — see `evidence/01-iac/README.md`.

## Testing

- `tofu fmt` + `tofu validate` clean.
- **Not yet applied** — needs `app_ami_id` from a real CI build and a real
  Aiven service. Tracking as the next piece of work.
