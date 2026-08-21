# `terraform/lb-design/` — the ALB, as IaC only

Per the trainer's clarification: ELBv2 (ALB) is a Base-tier-and-up
LocalStack feature — not available on the free Hobby tier this lab runs on
(same story as Docker-backed EC2, see `../../FIDELITY.md`). This directory
exists to satisfy that requirement honestly: real, hardened `aws_lb` /
`aws_lb_target_group` / `aws_lb_listener` Terraform, `tofu validate`-clean
and scanned by `trivy config` / `zizmor` in CI (it's under `terraform/`, so
CI's IaC scan already covers it) — but **never applied**, standalone,
sourced by nothing and sourcing nothing else.

Why standalone rather than folded into `../main.tf`: applying it would
either fail outright (ELBv2 isn't licensed on Hobby, confirmed in
`evidence/01-iac/README.md`'s ALB section from before the group's
`create_alb` fix) or, if `tofu apply` were ever pointed at this directory
by mistake, it would try to create real resources referencing
placeholder `vpc_id`/`subnet_ids`/`security_group_id` values that don't
exist. Keeping it a separate root with no backend, no apply target, and
default placeholder values makes "never applied" true by construction, not
just by convention.

**What actually carries traffic in the meantime:** nginx, on the instance
(see `modules/service`'s `templates/nginx.conf.tftpl` and user-data),
proxying only to a `/readyz`-passing upstream — the same readiness gate
this design's target group's health check encodes. See
`evidence/04-health/readyz-degraded.txt` for proof that gate is real.

**On a real-AWS or Base-tier-and-up transfer:** this becomes the actual
entrypoint. Wire `vpc_id`/`subnet_ids` to the real VPC/subnet data sources
(matching `modules/service`'s own `data "aws_vpc" "default"` pattern),
`security_group_id` to `modules/service`'s `aws_security_group.app.id`,
fold it into the main apply graph, and add an HTTPS listener + ACM cert —
noted inline in `main.tf` where the HTTP-only choice is justified for this
lab specifically.
