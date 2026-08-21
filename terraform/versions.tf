terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Remote state (S3 + DynamoDB lock), per C1: "the bootstrap script is
  # provided — you don't write it." The group's bootstrap/ root (merged
  # regional-health-platform#12) creates the shared bucket + lock table;
  # bucket/key/region/dynamodb_table are intentionally NOT hardcoded here
  # (a literal key would collide with every other person's state in the
  # same shared bucket) — supply them all via -backend-config at init time:
  #
  #   tflocal init \
  #     -backend-config="bucket=devops-g1-ls-tfstate" \
  #     -backend-config="key=db-capacity-engineering-lab/terraform.tfstate" \
  #     -backend-config="region=us-east-1" \
  #     -backend-config="dynamodb_table=devops-g1-ls-tflock"
  backend "s3" {}
}
