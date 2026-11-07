output "zone_id" {
  description = "Hosted zone ID, for ROUTE53_ZONE_ID in the Pi .env."
  value       = aws_route53_zone.primary.zone_id
}

output "name_servers" {
  description = "Name servers of the adopted zone."
  value       = aws_route53_zone.primary.name_servers
}

output "trust_anchor_arn" {
  description = "Roles Anywhere trust anchor ARN (null until ca_cert_pem is set)."
  value       = one(aws_rolesanywhere_trust_anchor.ca[*].arn)
}

output "profile_arn" {
  description = "Roles Anywhere profile ARN for Traefik (null until ca_cert_pem is set)."
  value       = one(aws_rolesanywhere_profile.traefik[*].arn)
}

output "role_arn" {
  description = "DNS-01 role ARN (null until ca_cert_pem is set)."
  value       = one(aws_iam_role.traefik_dns01[*].arn)
}

output "host_profile_arn" {
  description = "Roles Anywhere profile ARN for the Pi host identity (null until ca_cert_pem is set)."
  value       = one(aws_rolesanywhere_profile.pi_host[*].arn)
}

output "host_role_arn" {
  description = "Pi host role ARN (null until ca_cert_pem is set)."
  value       = one(aws_iam_role.pi_host[*].arn)
}
