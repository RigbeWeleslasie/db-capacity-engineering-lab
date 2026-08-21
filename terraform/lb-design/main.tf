# =============================================================================
# terraform/lb-design — the ALB, as IaC only. NEVER applied.
#
# Per the trainer's clarification: ELBv2 (ALB) is a Base-tier-and-up
# LocalStack feature, same as real Docker-backed EC2 -- not available on the
# free Hobby tier this lab runs on. So this root exists purely to be written,
# `tofu validate`d, and scanned (trivy config / zizmor) as real, hardened IaC
# -- it is intentionally standalone, sourced by nothing, and nothing sources
# it. It is not part of ../main.tf's apply graph and never will be while on
# Hobby. On a real-AWS or Base-tier-and-up transfer, this becomes the actual
# entrypoint's IaC; nginx (see modules/service's user-data) carries real
# traffic here in the meantime -- see ../../evidence/04-health/ for the
# readiness-gating proof at that layer instead.
#
# Same hardening patterns as the group's modules/service (which gates its
# own ALB behind a create_alb variable defaulting false, for the identical
# reason) so this isn't a lesser/toy version of the real thing:
#   - drop_invalid_header_fields (AWS-0052)
#   - internal = false is intentional (AWS-0053 suppressed by design: an ALB
#     fronting a public service must be internet-facing)
#   - health check against /readyz, matching this repo's actual readiness
#     contract, not a generic TCP check
# =============================================================================

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }
}

variable "name_prefix" {
  description = "Name/tag prefix, matching this repo's root convention."
  type        = string
  default     = "devops-g1-ls-rigbe"
}

variable "vpc_id" {
  description = <<-EOT
    VPC to place the ALB in. No default, deliberately -- this root is never
    applied, so there's no live default VPC lookup to fall back to (unlike
    modules/service, which does `data "aws_vpc" "default" {}` against a real
    provider connection). Left as a plain variable so `tofu validate` has
    something type-correct to check against without needing a provider
    connection at all.
  EOT
  type        = string
  default     = "vpc-placeholder-never-applied"
}

variable "subnet_ids" {
  description = "At least 2 subnet ids across distinct AZs, same as modules/service's own ALB requirement."
  type        = list(string)
  default     = ["subnet-placeholder-a", "subnet-placeholder-b"]
}

variable "security_group_id" {
  description = "Security group the ALB attaches to -- would be modules/service's aws_security_group.app.id in the real apply graph."
  type        = string
  default     = "sg-placeholder-never-applied"
}

#trivy:ignore:AVD-AWS-0053 internet-facing is the intended design for a public entrypoint, same justification as modules/service's own ALB
resource "aws_lb" "app" {
  name                       = "${var.name_prefix}-alb"
  internal                   = false
  load_balancer_type         = "application"
  security_groups            = [var.security_group_id]
  subnets                    = var.subnet_ids
  drop_invalid_header_fields = true # AWS-0052

  tags = { Name = "${var.name_prefix}-alb" }
}

resource "aws_lb_target_group" "app" {
  name = "${var.name_prefix}-tg"
  # Target nginx (80), not the app port directly -- same reasoning as
  # modules/service: the declared LB path also goes through the readiness
  # gate, consistent with the security group having no app-port ingress.
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/readyz"
    matcher             = "200"
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = { Name = "${var.name_prefix}-tg" }
}

# HTTP (not HTTPS): this root is IaC-only and never routes traffic, and there
# is no TLS material anywhere in this lab -- nginx on the instance terminates
# the only real traffic, over HTTP. A production transfer would add an ACM
# cert, an HTTPS (443) listener, and redirect this one to it.
#trivy:ignore:AVD-AWS-0054 ALB is non-routing IaC only; no TLS material in lab; nginx terminates real traffic
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.app.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
