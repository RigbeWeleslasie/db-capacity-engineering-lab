# C1 — Terraform apply evidence

Real `tflocal apply` run against a locally-started LocalStack instance
(freemium/Hobby license), on 2026-08-20. Raw output: `apply-output.txt`.

## What actually stood up (real, verified)

| Resource | Result |
|---|---|
| `module.data.aws_secretsmanager_secret.db` | **Created** — `arn:aws:secretsmanager:us-east-1:000000000000:secret:regional-health/db-xbIZvk` |
| `module.data.aws_secretsmanager_secret_version.db` | **Created** — credential envelope written, real `GetSecretValue`-readable secret |
| `module.service.aws_security_group.app` | **Created** — `sg-8d4bb32a08e4336e6` |

This is the core C3 (secrets) proof: the Aiven connection details actually
made it into a real Secrets Manager secret on a real LocalStack apply, not
just a `tofu plan`.

## What's blocked, and why (genuine environment limitations, not code bugs)

### ALB (`aws_lb`, `aws_lb_target_group`, `aws_lb_listener`) — LocalStack license

```
Error: reading ELBv2 Load Balancer (devops-g1-ls-rigbe-alb): ... api error
InternalFailure: Sorry, the elbv2 service is not included within your
LocalStack license, but is available in an upgraded license.
```

ELBv2 is not included in LocalStack's free Hobby ("freemium") tier at all —
confirmed via the container's own logs, not just the apply error. This
matches `modules/service`'s own documented design ("ALB topology as IaC;
nginx carries the real traffic") — the module already anticipated ALB might
not be gate-able on LocalStack, though the actual failure mode (can't even
be *created*, not just can't health-check) is stronger than what its README
describes.

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

None of these changed the result. This looks like a genuine gap in this
LocalStack version (`2026.7.1`)/environment between the documented behavior
and actual behavior — worth reporting to LocalStack and/or the trainer, not
something fixable by changing this repo's Terraform or app code.

## Separately, two real bugs found and fixed along the way

1. **`modules/service`'s `app_ami_id` validation accepts the full docker-tag
   string (`localstack-ec2/<name>:ami-<sha12>`), but `aws_instance.ami`
   passes it through unmodified** — LocalStack expects the bare `ami-<sha12>`
   id. The validation regex's own `:ami-[0-9a-f]{12}$` branch implies the
   full-tag form should work; it doesn't, without an extraction step the
   module doesn't have. Flagged to Nebyat (module owner).
2. **`golden-ci.yml`'s `aiven_host`/`aiven_port` inputs never resolved**
   when passed as `vars` context into the reusable workflow from a different
   repo — fixed by moving them to `secrets:` instead (see
   `fix/golden-ci-aiven-secrets`, merged).

## Teardown

`destroy-output.txt` shows `0 destroyed` — not a bug. Between the apply above and
the destroy attempt, LocalStack was restarted twice (chasing the AMI issue),
which wipes all state server-side by design ("every run starts LocalStack
fresh"). `tofu destroy`'s refresh step correctly detected the drift and
found nothing real left to tear down.
