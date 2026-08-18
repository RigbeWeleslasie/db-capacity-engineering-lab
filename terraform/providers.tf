provider "aws" {
  region = var.aws_region

  # This root runs via `tflocal apply` (github.com/localstack/terraform-local)
  # against LocalStack, not `tofu apply` directly — tflocal transparently
  # injects the endpoint overrides and dummy credentials LocalStack needs.
  # This provider block stays plain "real AWS" config on purpose, so the
  # exact same root config runs unchanged against real AWS with `tofu`/
  # `terraform` swapped in for `tflocal` — no isLocalStack branch here either.
}
