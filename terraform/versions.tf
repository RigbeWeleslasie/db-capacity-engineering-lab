terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
  }

  # Remote state (S3 + DynamoDB lock) is provided by the assignment's own
  # bootstrap — intentionally not hand-written here (see the group platform
  # repo's README: "bootstrap is provided by the assignment — we don't
  # hand-write it"). Local state for now; switch this to an "s3" backend
  # block with the assignment's actual bucket/table/region once that
  # bootstrap is available. Don't invent bucket/table names in the meantime.
  # backend "s3" {}
}
