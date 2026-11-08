# SSM Parameter Store, Terraform side: ONLY the non-secret /home-lab/config/* String parameters.
#
# The six SecureStrings (authentik/secret-key, authentik/postgres-password, authentik/bootstrap-password, traefik/breakglass-htpasswd,
# tailscale/auth-key, homepage/authentik-token) are NOT Terraform-managed (decision 2026-11-08, ADR-013): the provider reads a
# SecureString WithDecryption even for a write-only value, and the customer-managed key correctly denies Decrypt to the HCP roles.
# They are created and set by the owner with scripts/set-secret.sh (--create, then set; --check verifies them), and the list in
# config/secrets-manifest.tsv is the source of truth. The removed block only forgets them in state; nothing is deleted in AWS.
removed {
  from = aws_ssm_parameter.secret
  lifecycle {
    destroy = false
  }
}

locals {
  config_params = var.create_ssm_parameters ? merge(
    {
      "config/domain"          = var.domain
      "config/route53-zone-id" = aws_route53_zone.primary.zone_id
    },
    # The Roles Anywhere identity lives in terraform/bootstrap (SEC-H1); its ARNs arrive as workspace variables
    # (bootstrap outputs) and are only mirrored into SSM here for the Pi.
    var.ra_trust_anchor_arn == null ? {} : { "config/ra-trust-anchor-arn" = var.ra_trust_anchor_arn },
    var.ra_acme_profile_arn == null ? {} : { "config/ra-acme-profile-arn" = var.ra_acme_profile_arn },
    var.ra_acme_role_arn == null ? {} : { "config/ra-acme-role-arn" = var.ra_acme_role_arn }
  ) : {}
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
