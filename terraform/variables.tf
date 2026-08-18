# =============================================================================
# Root config — Regional Health / capacity-api individual rehost
#
# Wires the shared group platform modules (modules/data, modules/service —
# see main.tf for the pinned source refs and why) to this specific service.
# =============================================================================

variable "aws_region" {
  description = "AWS region for the provider and the group modules."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = <<-EOT
    Prefix for names/tags/identifiers. Extends the group's devops-g1-ls-
    convention with a per-person suffix so resources are unambiguous in
    diagrams/screenshots even though each of us runs our own separate
    LocalStack account (no actual collision risk, just clarity).
  EOT
  type        = string
  default     = "devops-g1-ls-rigbe"
}

# --- modules/service: app-specific ------------------------------------------

variable "app_ami_id" {
  description = "CI-produced AMI tag: localstack-ec2/app:ami-<sha12>. No default — always supplied by CI or by hand for a manual apply."
  type        = string
}

variable "app_port" {
  description = "Port capacity-api listens on. Must match the PORT env var actually passed to the process (see local.app_env in main.tf)."
  type        = number
  default     = 3000
}

variable "app_start_command" {
  description = "How user-data starts the app. Matches package.json's start script / the Dockerfile's CMD."
  type        = string
  default     = "node server.js"
}

variable "app_workdir" {
  description = "Where the app starts from inside the instance image. Matches the Dockerfile's WORKDIR."
  type        = string
  default     = "/usr/src/app"
}

variable "app_env" {
  description = <<-EOT
    Extra non-secret env vars for the app process, merged with the required
    PORT entry in main.tf. Notably NOT wired by default: MONGO_URI/MONGO_DB
    (the Mongo audit store isn't in Assignment 2's scope — /api/audit/ping
    will fail once deployed unless you choose to stand up a reachable Mongo
    and set these yourself) and DB_CA_CERT_PATH (Aiven TLS — depends on how
    the CI-built AMI delivers the CA cert to the instance, not yet decided;
    see modules/data's README). Both are deliberate gaps, not oversights.
  EOT
  type        = map(string)
  default     = {}
}

variable "ingress_cidrs" {
  description = "CIDRs allowed to reach the instance. Default (null) falls through to modules/service's own default (the VPC CIDR) — never 0.0.0.0/0."
  type        = list(string)
  default     = null
}

# --- modules/data: Aiven connection details ---------------------------------
# Same discipline as LOCALSTACK_AUTH_TOKEN: sourced via TF_VAR_aiven_* env
# vars (CI secret / local shell), never a default, never a committed tfvars.

variable "aiven_host" {
  description = "Aiven MySQL service hostname. No default — always caller-supplied."
  type        = string
}

variable "aiven_port" {
  description = "Aiven MySQL service port. No default — Aiven assigns this per-service."
  type        = number
}

variable "aiven_username" {
  description = "Aiven MySQL admin username."
  type        = string
  default     = "avnadmin"
}

variable "aiven_password" {
  description = "Aiven MySQL admin password. No default, sensitive — must come from TF_VAR_aiven_password."
  type        = string
  sensitive   = true
}
