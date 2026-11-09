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

override_resource {
  target = aws_sns_topic.alerts
  values = {
    arn = "arn:aws:sns:af-south-1:111111111111:home-lab-alerts"
  }
}

override_resource {
  target = aws_sns_topic_subscription.alerts_email
}

override_resource {
  target = aws_sns_topic_policy.alerts
}

variables {
  hcp_organization       = "example-org"
  domain                 = "example.com"
  home_lab_zone_id       = "ZTESTZONE0000000001"
  duplicate_zone_ids     = []
  owner_role_arn_pattern = "arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_Admin_*"
  ca_cert_pem            = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----"
  alert_email            = "alerts@example.com"
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

  assert {
    condition     = can(regex("parameter/home-lab/config/", data.aws_iam_policy_document.write.json)) && !can(regex("parameter/home-lab/[*]", data.aws_iam_policy_document.write.json))
    error_message = "the apply role touches only /home-lab/config/* in SSM, never the SecureStrings (ADR-013)"
  }

  assert {
    condition     = !can(regex("\"kms:(Encrypt|GenerateDataKey)", data.aws_iam_policy_document.write.json))
    error_message = "the apply role has no KMS permission other than the deny (ADR-013)"
  }

  assert {
    condition     = can(regex("parameter/home-lab/config/", data.aws_iam_policy_document.read.json)) && !can(regex("parameter/home-lab/[*]", data.aws_iam_policy_document.read.json)) && !can(regex("kms:", data.aws_iam_policy_document.read.json))
    error_message = "the plan role reads only /home-lab/config/* and has no kms permission (ADR-013)"
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
    condition     = !can(regex("ApplyRoleEncrypt", data.aws_iam_policy_document.ssm_key.json)) && can(regex("OwnerEncryptViaSsm", data.aws_iam_policy_document.ssm_key.json))
    error_message = "the HCP roles are not key users; the owner role may encrypt (ADR-013)"
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

run "alerts_only_pi_host_can_publish" {
  command = apply

  assert {
    condition     = aws_sns_topic.alerts.name == "home-lab-alerts" && aws_sns_topic.alerts.kms_master_key_id == "alias/aws/sns"
    error_message = "one encrypted topic named home-lab-alerts, on the AWS-managed SNS key (the home-lab CMK denies SNS Decrypt)"
  }

  assert {
    condition     = can(regex("\"sns:Publish\"", data.aws_iam_policy_document.pi_host.json)) && can(regex("arn:aws:sns:af-south-1:111111111111:home-lab-alerts", data.aws_iam_policy_document.pi_host.json))
    error_message = "the Pi host role may sns:Publish to the alert topic ARN"
  }

  assert {
    condition     = length(regexall("\"sns:", data.aws_iam_policy_document.pi_host.json)) == 1 && !can(regex("sns:(Subscribe|SetTopicAttributes|DeleteTopic|CreateTopic|[*])", data.aws_iam_policy_document.pi_host.json))
    error_message = "the Pi host role has exactly one SNS action (Publish) and no topic management"
  }

  assert {
    condition     = !can(regex("sns:", data.aws_iam_policy_document.write.json)) && !can(regex("sns:", data.aws_iam_policy_document.read.json)) && !can(regex("sns:", data.aws_iam_policy_document.dns01.json)) && !can(regex("sns:", data.aws_iam_policy_document.ssm_key.json))
    error_message = "no other policy (HCP plan and apply roles, DNS-01 role, key policy) gains any SNS right"
  }

  assert {
    condition     = can(regex("DenyInsecureTransport", data.aws_iam_policy_document.alerts_topic.json)) && can(regex("aws:SecureTransport", data.aws_iam_policy_document.alerts_topic.json))
    error_message = "the topic policy refuses non-TLS Publish and Subscribe (SEC-L-1)"
  }

  assert {
    condition     = can(regex("DenyPublishExceptPiHostAndOwner", data.aws_iam_policy_document.alerts_topic.json)) && can(regex("role/home-lab-pi-host", data.aws_iam_policy_document.alerts_topic.json))
    error_message = "only the Pi host role and the owner role may publish to the topic (SEC-L-1)"
  }

  assert {
    condition     = can(regex("DenySubscribeAndManagementExceptOwner", data.aws_iam_policy_document.alerts_topic.json)) && can(regex("sns:Subscribe", data.aws_iam_policy_document.alerts_topic.json)) && can(regex("sns:SetTopicAttributes", data.aws_iam_policy_document.alerts_topic.json))
    error_message = "Subscribe and topic management are restricted to the owner (SEC-L-1)"
  }

  assert {
    condition     = length(regexall("\"Effect\": \"Allow\"", data.aws_iam_policy_document.alerts_topic.json)) == 1 && can(regex(":root", data.aws_iam_policy_document.alerts_topic.json))
    error_message = "exactly one Allow statement, for the account root (SEC-L-1)"
  }

  assert {
    condition     = aws_sns_topic_subscription.alerts_email.protocol == "email"
    error_message = "the subscription is an email subscription"
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

# SEC-L1 / N7: audit logging is opt-in (enable_audit_logging). When it is switched on, the trail must be multi-region with log file
# validation and the bucket must be private, encrypted, versioned, and refuse plain HTTP. (Nothing is created: all overridden.)
override_resource {
  target = aws_s3_bucket.audit
  values = {
    id  = "home-lab-audit-111111111111-af-south-1"
    arn = "arn:aws:s3:::home-lab-audit-111111111111-af-south-1"
  }
}

override_resource {
  target = aws_s3_bucket_public_access_block.audit
}

override_resource {
  target = aws_s3_bucket_ownership_controls.audit
}

override_resource {
  target = aws_s3_bucket_server_side_encryption_configuration.audit
}

override_resource {
  target = aws_s3_bucket_versioning.audit
}

override_resource {
  target = aws_s3_bucket_lifecycle_configuration.audit
}

override_resource {
  target = aws_s3_bucket_policy.audit
}

override_resource {
  target = aws_cloudtrail.audit
}

override_resource {
  target = aws_accessanalyzer_analyzer.account
}

run "audit_logging_is_off_by_default" {
  command = apply

  assert {
    condition     = length(aws_cloudtrail.audit) == 0 && length(aws_s3_bucket.audit) == 0 && length(aws_accessanalyzer_analyzer.account) == 0
    error_message = "no trail, bucket or analyzer unless enable_audit_logging is true (N7: opt-in, nothing is created by default)"
  }
}

run "audit_logging_when_enabled_is_hardened" {
  command = apply

  variables {
    enable_audit_logging = true
  }

  assert {
    condition     = aws_cloudtrail.audit[0].is_multi_region_trail && aws_cloudtrail.audit[0].enable_log_file_validation && aws_cloudtrail.audit[0].include_global_service_events
    error_message = "the trail is multi-region, validates log files and records global service events"
  }

  assert {
    condition     = can(regex("DenyInsecureTransport", data.aws_iam_policy_document.audit_bucket[0].json)) && can(regex("aws:SecureTransport", data.aws_iam_policy_document.audit_bucket[0].json))
    error_message = "the audit bucket refuses plain HTTP"
  }

  assert {
    condition     = can(regex("cloudtrail.amazonaws.com", data.aws_iam_policy_document.audit_bucket[0].json)) && can(regex("aws:SourceArn", data.aws_iam_policy_document.audit_bucket[0].json))
    error_message = "only the home-lab trail (SourceArn) may write to the audit bucket"
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.audit[0].block_public_acls && aws_s3_bucket_public_access_block.audit[0].restrict_public_buckets
    error_message = "the audit bucket blocks public access"
  }

}
