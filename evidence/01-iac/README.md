# C1 — Terraform apply evidence

Two real `tflocal apply` runs against a locally-started LocalStack
instance (freemium/Hobby license): an earlier one on 2026-08-20
(`apply-output-earlier.txt`), and the current one on 2026-08-21
(`apply.log`, `plan-after-apply.txt`, `destroy.log`) — re-run after the
group's `modules/service` added a `create_alb` toggle
(regional-health-platform#11), which resolved the ALB blocker below
entirely rather than just documenting it.

## What actually stood up (real, verified)

| Resource | Result |
|---|---|
| `module.data.aws_secretsmanager_secret.db` | **Created** — real Secrets Manager secret |
| `module.data.aws_secretsmanager_secret_version.db` | **Created** — credential envelope written, real `GetSecretValue`-readable secret |
| `module.service.aws_security_group.app` | **Created** — real security group, ingress/egress rules as declared |

This is the core C3 (secrets) proof: the Aiven connection details actually
made it into a real Secrets Manager secret on a real LocalStack apply, not
just a `tofu plan`. `destroy.log` confirms all three were genuinely
tracked in state and cleanly destroyed ("Destroy complete! Resources: 3
destroyed.") — not a fluke or drift.

## Resolved since the earlier run: the ALB blocker

The 2026-08-20 run hit `aws_lb`/`aws_lb_target_group`/`aws_lb_listener`
failing outright (`the elbv2 service is not included within your
LocalStack license`). `modules/service`'s owner added a `create_alb`
variable (default `false`) specifically for this — the ALB resources stay
declared and scanned by `trivy`/`zizmor` as real IaC, but are no longer
even *attempted* against LocalStack. Re-pinning to that fix and re-running
the apply confirms it: `plan` now shows exactly 4 resources for a fresh
apply (secret, secret version, security group, instance) — zero ALB
resources — and the ALB-specific error is gone entirely from `apply.log`.

## Still blocked, and why (a genuine environment limitation, not a code bug)

### EC2 instance — Docker-backed AMI discovery doesn't register the image

```
Error: collecting instance settings: couldn't find resource
```

Followed LocalStack's documented convention exactly: built the app image,
tagged it `localstack-ec2/capacity-api:ami-<sha12>` (per
https://docs.localstack.cloud/aws/services/ec2/), and referenced the bare
`ami-<sha12>` id in `aws_instance.ami`. LocalStack never registers it as a
discoverable AMI:

- `docker images` confirms the tagged image is genuinely present
- `docker ps` confirms the LocalStack container has `/var/run/docker.sock` mounted
- `aws ec2 describe-images --filters Name=tag:ec2_vm_manager,Values=docker` returns empty
- Tried: a fresh LocalStack restart after the image already existed (rules out timing)
- Tried: explicit `EC2_VM_MANAGER=docker` (rules out a wrong default)

None of these changed the result, on either the 2026-08-20 or the
2026-08-21 run (different LocalStack container instances, same result
both times). This looks like a genuine gap in this LocalStack version
between the documented behavior and actual behavior — see `FIDELITY.md`
for the full writeup — not something fixable by changing this repo's
Terraform or app code. Because the instance never enters state,
`plan-after-apply.txt` is honestly **not empty** (it proposes creating the
instance again, every time) — see that file's own header note.

## Separately, real bugs found and fixed along the way (all merged upstream)

1. **`modules/service`'s `app_ami_id` validation accepted the full
   docker-tag string, but `aws_instance.ami` passed it through
   unmodified** — fixed in regional-health-platform#8 (strips to the bare
   `ami-<sha12>` id).
2. **`golden-ci.yml`'s `aiven_host`/`aiven_port` never resolved** when
   passed as `vars` context cross-repo — fixed in
   regional-health-platform#7 (moved to `secrets:`).
3. **`modules/service` never delivered the Aiven CA cert to the
   instance**, despite `api/secrets.js` already expecting
   `DB_CA_CERT_PATH` — fixed in regional-health-platform#9 (`db_ca_cert`
   variable, written to `/etc/app/db-ca.pem` in user-data).
4. **The ALB blocked the whole apply on LocalStack's Hobby-tier license**
   — fixed in regional-health-platform#11 (`create_alb`, defaults `false`).
