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
