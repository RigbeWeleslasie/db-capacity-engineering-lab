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
  # PINNED TO A BRANCH COMMIT, NOT MAIN — TEMPORARY.
  # The Aiven rewrite (github.com/nebyathhailu/regional-health-platform,
  # branch feat/aiven-mysql) hasn't merged to that repo's main yet as of this
  # commit — it's out for review. This SHA is the actual commit, not a moving
  # branch name, so it's still a real pin; re-pin to the post-merge commit on
  # main once that PR lands, then this comment can go.
  source = "git::https://github.com/nebyathhailu/regional-health-platform.git//terraform/modules/data?ref=bc4f334417feb7e79666f905d57ac7950b3285ca"

  name_prefix    = var.name_prefix
  db_name        = "capacity_lab"
  aiven_host     = var.aiven_host
  aiven_port     = var.aiven_port
  aiven_username = var.aiven_username
  aiven_password = var.aiven_password
}

module "service" {
  source = "git::https://github.com/nebyathhailu/regional-health-platform.git//terraform/modules/service?ref=d0ff5320a01b0fb3606452c0324610d979411015"

  name_prefix       = var.name_prefix
  app_ami_id        = var.app_ami_id
  app_port          = var.app_port
  app_start_command = var.app_start_command
  app_workdir       = var.app_workdir
  app_env           = local.app_env
  ingress_cidrs     = var.ingress_cidrs

  # From modules/data — never the secret value itself, just its ARN.
  secret_arn  = module.data.secret_arn
  db_endpoint = module.data.db_endpoint
  db_port     = module.data.db_port
}
