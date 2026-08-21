# =============================================================================
# Root config — wires the group platform's modules/data + modules/service to
# capacity-api. No module.network here: modules/data no longer needs it
# (Aiven is external to the VPC), and modules/service still does its own
# internal VPC/subnet lookup — it hasn't adopted modules/network yet (see
# that module's README in the group repo). Nothing for this root to do there
# either way; both group modules are fully self-contained today.
# =============================================================================

locals {
  # PORT isn't set by modules/service's user-data automatically — only
  # AWS_*/DB_* are. Merge it into app_env so the Express app actually listens
  # on the same port nginx is configured to proxy to (app_port).
  app_env = merge({ PORT = tostring(var.app_port) }, var.app_env)
}

module "data" {
  # Pinned to main (regional-health-platform#5, merged) — Aiven MySQL.
  source = "git::https://github.com/nebyathhailu/regional-health-platform.git//terraform/modules/data?ref=c930bc6aeb6dfc456a57de9dfb34053f08c0278d"

  name_prefix    = var.name_prefix
  db_name        = "capacity_lab"
  aiven_host     = var.aiven_host
  aiven_port     = var.aiven_port
  aiven_username = var.aiven_username
  aiven_password = var.aiven_password
}

module "service" {
  # Pinned to main (regional-health-platform#2 + #6 + #8 + #9 + #10, merged)
  # — the trivy config hardening (IMDSv2, encrypted volume, invalid headers),
  # #8's fix for app_ami_id (aws_instance.app.ami strips the
  # localstack-ec2/<name>: prefix off the docker-tag-style value CI produces,
  # was InvalidAMIID.Malformed), #9's db_ca_cert (user-data now wires the
  # Aiven TLS CA cert to DB_CA_CERT_PATH when db_ca_cert is set below), and
  # #10's trivy ignore-unfixed tweak.
  source = "git::https://github.com/nebyathhailu/regional-health-platform.git//terraform/modules/service?ref=c930bc6aeb6dfc456a57de9dfb34053f08c0278d"

  name_prefix       = var.name_prefix
  app_ami_id        = var.app_ami_id
  app_port          = var.app_port
  app_start_command = var.app_start_command
  app_workdir       = var.app_workdir
  app_env           = local.app_env
  ingress_cidrs     = var.ingress_cidrs
  db_ca_cert        = var.db_ca_cert

  # From modules/data — never the secret value itself, just its ARN.
  secret_arn  = module.data.secret_arn
  db_endpoint = module.data.db_endpoint
  db_port     = module.data.db_port
}
