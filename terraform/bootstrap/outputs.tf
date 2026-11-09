output "plan_role_arn" {
  description = "Set as the TFC_AWS_PLAN_ROLE_ARN environment variable in the home-lab workspace."
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as the TFC_AWS_APPLY_ROLE_ARN environment variable in the home-lab workspace."
  value       = aws_iam_role.apply.arn
}

output "oidc_provider_arn" {
  description = "ARN of the app.terraform.io OIDC provider."
  value       = local.oidc_arn
}

output "trust_anchor_arn" {
  description = "Roles Anywhere trust anchor ARN (null until ca_cert_pem is set). Feeds scripts/render-aws-env.sh and the edge workspace variable ra_trust_anchor_arn."
  value       = one(aws_rolesanywhere_trust_anchor.ca[*].arn)
}

output "traefik_profile_arn" {
  description = "Roles Anywhere profile ARN for Traefik. Edge workspace variable ra_acme_profile_arn."
  value       = one(aws_rolesanywhere_profile.traefik[*].arn)
}

output "dns01_role_arn" {
  description = "DNS-01 role ARN. Edge workspace variable ra_acme_role_arn."
  value       = one(aws_iam_role.traefik_dns01[*].arn)
}

output "host_profile_arn" {
  description = "Roles Anywhere profile ARN for the Pi host identity (scripts/render-aws-env.sh)."
  value       = one(aws_rolesanywhere_profile.pi_host[*].arn)
}

output "host_role_arn" {
  description = "Pi host role ARN (scripts/render-aws-env.sh)."
  value       = one(aws_iam_role.pi_host[*].arn)
}

output "ssm_kms_key_alias" {
  description = "Alias of the customer-managed key for the /home-lab SecureStrings (used by terraform/edge and scripts/set-secret.sh)."
  value       = aws_kms_alias.ssm.name
}

output "alert_topic_arn" {
  description = "ARN of the SNS alert topic. Feeds scripts/render-aws-env.sh (ALERT_TOPIC_ARN in the Pi's /etc/home-lab/aws.env)."
  value       = aws_sns_topic.alerts.arn
}

output "backup_bucket_name" {
  description = "Name of the Authentik backup bucket. Feeds scripts/render-aws-env.sh (BACKUP_S3_BUCKET in the Pi's /etc/home-lab/aws.env)."
  value       = aws_s3_bucket.backup.id
}
