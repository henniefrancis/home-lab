# Offline policy tests for the identity stack (SEC-H1, SEC-M1, SEC-M2). No AWS: the aws provider is MOCKED, so this runs with
# `terraform init -backend=false && terraform test` (CI copies the stack to a temporary directory first, so no real tfvars and no
# HCP backend are involved). It renders the real IAM and KMS policy documents and asserts on their content.
# Real provider, nothing real called: scripts/test-terraform-policies.sh runs this in a temporary copy of the stack with a stub provider
# configuration (fake credentials, validation skipped) and a dead HTTPS proxy, so even a mistake could not reach AWS. Every data
# source and resource that would call an API is overridden below with fixed values; plan only reads data sources, and those are overridden.
override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "111111111111"
  }
}

override_data {
  target = data.aws_kms_alias.legacy_ssm
  values = {
    target_key_arn = "arn:aws:kms:af-south-1:111111111111:key/00000000-0000-0000-0000-000000000001"
  }
}

override_resource {
  target = aws_kms_key.ssm
  values = {
    arn    = "arn:aws:kms:af-south-1:111111111111:key/00000000-0000-0000-0000-000000000002"
    key_id = "00000000-0000-0000-0000-000000000002"
  }
}

override_resource {
  target = aws_iam_role.apply
  values = {
    arn = "arn:aws:iam::111111111111:role/home-lab-hcp-apply"
  }
}

override_resource {
  target = aws_iam_role.pi_host
  values = {
    arn = "arn:aws:iam::111111111111:role/home-lab-pi-host"
  }
}

override_resource {
  target = aws_rolesanywhere_trust_anchor.ca
  values = {
    arn = "arn:aws:rolesanywhere:af-south-1:111111111111:trust-anchor/00000000-0000-0000-0000-000000000003"
  }
}

override_resource {
  target = aws_iam_openid_connect_provider.hcp
  values = {
    arn = "arn:aws:iam::111111111111:oidc-provider/app.terraform.io"
  }
}

# Every other resource of the stack, overridden so that `apply` here only evaluates the configuration and calls no API.
override_resource {
  target = aws_iam_role.plan
  values = {
    arn = "arn:aws:iam::111111111111:role/home-lab-hcp-plan"
  }
}

override_resource {
  target = aws_iam_role.traefik_dns01
  values = {
    arn = "arn:aws:iam::111111111111:role/home-lab-traefik-dns01"
  }
}

override_resource {
  target = aws_iam_role_policy.plan
}

override_resource {
  target = aws_iam_role_policy.apply
}

override_resource {
  target = aws_iam_role_policy.traefik_dns01
}

override_resource {
  target = aws_iam_role_policy.pi_host
}

override_resource {
  target = aws_rolesanywhere_profile.traefik
}

override_resource {
  target = aws_rolesanywhere_profile.pi_host
}

override_resource {
  target = aws_kms_alias.ssm
  values = {
    name = "alias/home-lab-ssm"
  }
}

override_resource {
  target = aws_iam_service_linked_role.rolesanywhere
}

variables {
  hcp_organization       = "example-org"
  domain                 = "example.com"
  home_lab_zone_id       = "ZTESTZONE0000000001"
  duplicate_zone_ids     = []
  owner_role_arn_pattern = "arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/*/AWSReservedSSO_Admin_*"
  ca_cert_pem            = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
}

run "apply_role_cannot_change_identity" {
  command = apply

  assert {
    condition     = !can(regex("\"iam:(CreateRole|PutRolePolicy|UpdateAssumeRolePolicy|AttachRolePolicy|DeleteRolePolicy|UpdateRole)\"", data.aws_iam_policy_document.write.json))
    error_message = "the apply role must not be allowed any identity-changing IAM action (SEC-H1)"
  }

  assert {
    condition     = !can(regex("\"rolesanywhere:(CreateTrustAnchor|UpdateTrustAnchor|CreateProfile|UpdateProfile)\"", data.aws_iam_policy_document.write.json))
    error_message = "the apply role must not be allowed to change Roles Anywhere trust anchors or profiles (SEC-H1)"
  }

  assert {
    condition     = can(regex("DenyIdentityChanges", data.aws_iam_policy_document.write.json)) && can(regex("iam:PassRole", data.aws_iam_policy_document.write.json))
    error_message = "the explicit deny of identity changes (including PassRole) must be present"
  }

  assert {
    condition     = !can(regex("hostedzone/\\*", data.aws_iam_policy_document.write.json))
    error_message = "Route 53 write actions must be scoped to the home-lab zone, never hostedzone/* (SEC-M1)"
  }

  assert {
    condition     = can(regex("hostedzone/ZTESTZONE0000000001", data.aws_iam_policy_document.write.json))
    error_message = "the home-lab zone ARN must appear in the apply role policy (SEC-M1)"
  }

  assert {
    condition     = !can(regex("CreateHostedZone", data.aws_iam_policy_document.write.json))
    error_message = "CreateHostedZone is not granted (SEC-M1)"
  }

  assert {
    condition     = !can(regex("DeleteHostedZone", data.aws_iam_policy_document.write.json))
    error_message = "with no duplicate zones, DeleteHostedZone must not be granted at all (SEC-M1)"
  }

  assert {
    condition     = can(regex("route53domains:UpdateDomainNameservers", data.aws_iam_policy_document.write.json)) && !can(regex("\"Allow\"[^}]*route53domains:UpdateDomainNameservers", data.aws_iam_policy_document.write.json))
    error_message = "UpdateDomainNameservers is denied and never allowed for the apply role (SEC-M1: Route 53 Domains cannot be scoped)"
  }

  assert {
    condition     = can(regex("DenyKmsDecrypt", data.aws_iam_policy_document.write.json))
    error_message = "the apply role must carry an explicit kms:Decrypt deny (SEC-M2)"
  }
}

run "key_policy_least_privilege" {
  command = apply

  assert {
    condition     = can(regex("PiHostDecryptViaSsmForHomeLabParameters", data.aws_iam_policy_document.ssm_key.json)) && can(regex("kms:EncryptionContext:PARAMETER_ARN", data.aws_iam_policy_document.ssm_key.json))
    error_message = "only the Pi host role decrypts, with the encryption-context condition (SEC-M2)"
  }

  assert {
    condition     = can(regex("DenyDecryptExceptPiHost", data.aws_iam_policy_document.ssm_key.json))
    error_message = "everyone else is denied Decrypt in the key policy (SEC-M2)"
  }

  assert {
    condition     = aws_kms_key.ssm.enable_key_rotation == true
    error_message = "key rotation must be on (SEC-M2)"
  }

  assert {
    condition     = aws_kms_alias.ssm.name == "alias/home-lab-ssm"
    error_message = "the alias must be alias/home-lab-ssm"
  }
}

run "pi_host_and_dns01_policies" {
  command = apply

  assert {
    condition     = can(regex("kms:ViaService", data.aws_iam_policy_document.pi_host.json)) && can(regex("kms:EncryptionContext:PARAMETER_ARN", data.aws_iam_policy_document.pi_host.json))
    error_message = "the Pi host role decrypts only via SSM, for /home-lab parameters (SEC-M2)"
  }

  assert {
    condition     = !can(regex("DecryptLegacyKeyViaSsmOnly", data.aws_iam_policy_document.pi_host.json))
    error_message = "the legacy-key statement exists only during the migration window (allow_legacy_ssm_key)"
  }

  assert {
    condition     = can(regex("hostedzone/ZTESTZONE0000000001", data.aws_iam_policy_document.dns01.json)) && can(regex("_acme-challenge.example.com", data.aws_iam_policy_document.dns01.json))
    error_message = "the DNS-01 role is limited to _acme-challenge in the home-lab zone"
  }

  assert {
    condition     = length(aws_iam_role.pi_host) == 1 && length(aws_iam_role.traefik_dns01) == 1
    error_message = "both lab roles exist in the bootstrap stack"
  }
}

run "legacy_window_adds_only_the_old_key" {
  command = apply

  variables {
    allow_legacy_ssm_key = true
  }

  assert {
    condition     = can(regex("DecryptLegacyKeyViaSsmOnly", data.aws_iam_policy_document.pi_host.json))
    error_message = "with allow_legacy_ssm_key the migration statement is present"
  }
}

run "duplicate_zone_deletion_is_scoped" {
  command = apply

  variables {
    duplicate_zone_ids = ["ZDUPZONE00000000001"]
  }

  assert {
    condition     = can(regex("Route53DeleteDuplicateZones", data.aws_iam_policy_document.write.json)) && can(regex("hostedzone/ZDUPZONE00000000001", data.aws_iam_policy_document.write.json))
    error_message = "DeleteHostedZone exists only for the listed duplicate zones"
  }
}
