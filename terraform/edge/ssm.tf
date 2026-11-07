# SSM Parameter Store. SecureString values are WRITE-ONLY: Terraform sends a placeholder (value_wo) that is never
# stored in state, and the owner sets the real value out of band with scripts/set-secret.sh. That is the one
# documented exception to the Terraform-only rule; the parameter resources themselves are Terraform-managed.
# Plan: docs/plan/phase-1-traefik.md section 6.7.3; verification: docs/runbooks/secrets-ssm.md.
locals {
  secure_params = var.create_ssm_parameters ? {
    "authentik/secret-key"         = "Authentik secret key"
    "authentik/postgres-password"  = "Authentik PostgreSQL password"
    "authentik/bootstrap-password" = "Authentik akadmin bootstrap password - first start only"
    "traefik/breakglass-htpasswd"  = "Traefik break-glass basic auth htpasswd line"
    "tailscale/auth-key"           = "Tailscale one-off auth key - UNSET after join"
    "homepage/authentik-token"     = "Homepage Authentik widget API token - optional"
  } : {}

  config_params = var.create_ssm_parameters ? merge(
    {
      "config/domain"          = var.domain
      "config/route53-zone-id" = aws_route53_zone.primary.zone_id
    },
    local.enable_roles_anywhere ? {
      "config/ra-trust-anchor-arn" = aws_rolesanywhere_trust_anchor.ca[0].arn
      "config/ra-acme-profile-arn" = aws_rolesanywhere_profile.traefik[0].arn
      "config/ra-acme-role-arn"    = aws_iam_role.traefik_dns01[0].arn
    } : {}
  ) : {}
}

resource "aws_ssm_parameter" "secret" {
  for_each = local.secure_params

  name        = "/home-lab/${each.key}"
  description = each.value
  type        = "SecureString"
  tier        = "Standard"
  # key_id omitted: the AWS-managed key alias/aws/ssm is used.

  value_wo = "UNSET-set-via-set-secret"
  # NEVER bump this: a new version re-sends the placeholder and overwrites the real value. CI enforces it stays 1.
  value_wo_version = 1

  lifecycle {
    prevent_destroy = true
  }
}

# Non-secret configuration owned by Terraform, rendered into runtime.env on the Pi.
resource "aws_ssm_parameter" "config" {
  for_each = local.config_params

  name           = "/home-lab/${each.key}"
  description    = "home-lab config - managed by Terraform"
  type           = "String"
  tier           = "Standard"
  insecure_value = each.value
}
