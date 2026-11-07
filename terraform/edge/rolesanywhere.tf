# IAM Roles Anywhere in af-south-1 (the default provider region). Revoke by setting enabled = false.
# Adding another Pi role later (for example for runtime secrets) means one more aws_iam_role plus one more
# aws_rolesanywhere_profile that reuse this trust anchor; see iam-dns01.tf for the pattern.
resource "aws_rolesanywhere_trust_anchor" "ca" {
  count = local.enable_roles_anywhere ? 1 : 0

  name    = "home-lab-offline-ca"
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = var.ca_cert_pem
    }
  }
}

resource "aws_rolesanywhere_profile" "traefik" {
  count = local.enable_roles_anywhere ? 1 : 0

  name             = "home-lab-traefik"
  enabled          = true
  duration_seconds = 3600
  role_arns        = [aws_iam_role.traefik_dns01[0].arn]
}

resource "aws_rolesanywhere_profile" "pi_host" {
  count = local.enable_roles_anywhere ? 1 : 0

  name             = "home-lab-pi-host"
  enabled          = true
  duration_seconds = 3600
  role_arns        = [aws_iam_role.pi_host[0].arn]
}
