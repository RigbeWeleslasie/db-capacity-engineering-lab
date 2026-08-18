output "alb_dns_name" {
  description = "ALB DNS name (declared as IaC; nginx on the instance carries the real traffic — see modules/service's README)."
  value       = module.service.alb_dns_name
}

output "instance_id" {
  description = "EC2 instance id running capacity-api."
  value       = module.service.instance_id
}

output "instance_private_ip" {
  description = "Private IP of the instance — the bridge-reachable address on LocalStack."
  value       = module.service.instance_private_ip
}

output "db_endpoint" {
  description = "Aiven MySQL host (host only)."
  value       = module.data.db_endpoint
}

output "secret_arn" {
  description = "Secrets Manager ARN of the credential envelope."
  value       = module.data.secret_arn
}
