# The Pi's AWS identity: Roles Anywhere trust anchor, two profiles and two least-privilege roles (moved from terraform/edge,
# SEC-H1). Applied only by the owner with admin SSO (local execution), so a compromise of the HCP workspace cannot rewrite a
# trust policy or a role policy. The HCP apply role has no iam:* or rolesanywhere:* write permission at all (roles.tf).
# Roles Anywhere lives in af-south-1; the roles are global.

locals {
  # Public-safe: the trust conditions pin the CA by certificate CN and the generation by OU.
  traefik_cn = "home-lab-pi-traefik"
  host_cn    = "home-lab-pi-host"
  ca_cn      = "home-lab-offline-ca"
}

resource "aws_rolesanywhere_trust_anchor" "ca" {
  provider = aws.af_south_1
  count    = local.enable_identity ? 1 : 0

  name    = local.ca_cn
  enabled = true

  source {
    source_type = "CERTIFICATE_BUNDLE"
    source_data {
      x509_certificate_data = var.ca_cert_pem
    }
  }

  depends_on = [aws_iam_service_linked_role.rolesanywhere]

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_rolesanywhere_profile" "traefik" {
  provider = aws.af_south_1
  count    = local.enable_identity ? 1 : 0

  name             = "home-lab-traefik"
  enabled          = true
  duration_seconds = 3600
  role_arns        = [aws_iam_role.traefik_dns01[0].arn]
}

resource "aws_rolesanywhere_profile" "pi_host" {
  provider = aws.af_south_1
  count    = local.enable_identity ? 1 : 0

  name             = "home-lab-pi-host"
  enabled          = true
  duration_seconds = 3600
  role_arns        = [aws_iam_role.pi_host[0].arn]
}

# ---- Trust policies: the trust anchor ARN, the certificate CN, the generation OU and the issuer CN, all exact ----------
data "aws_iam_policy_document" "ra_trust" {
  for_each = local.enable_identity ? { traefik = local.traefik_cn, host = local.host_cn } : {}

  statement {
    sid    = "RolesAnywhere${title(each.key)}"
    effect = "Allow"
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
      "sts:SetSourceIdentity",
    ]

    principals {
      type        = "Service"
      identifiers = ["rolesanywhere.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_rolesanywhere_trust_anchor.ca[0].arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Subject/CN"
      values   = [each.value]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Subject/OU"
      values   = [var.pki_generation]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Issuer/CN"
      values   = [local.ca_cn]
    }
  }
}

# ---- DNS-01 role (Traefik): TXT _acme-challenge in the home-lab zone only ------------------------------------------------
# ForAllValues is paired with a Null check on each key so that a request that omits the key cannot satisfy the condition
# vacuously.
data "aws_iam_policy_document" "dns01" {
  statement {
    sid       = "GetChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:${local.partition}:route53:::change/*"]
  }

  statement {
    sid       = "ListRecordsInZone"
    effect    = "Allow"
    actions   = ["route53:ListResourceRecordSets"]
    resources = [local.zone_arn]
  }

  statement {
    sid       = "ChangeAcmeChallengeTxtOnly"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [local.zone_arn]

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["_acme-challenge.${var.domain}"]
    }
    condition {
      test     = "Null"
      variable = "route53:ChangeResourceRecordSetsNormalizedRecordNames"
      values   = ["false"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["TXT"]
    }
    condition {
      test     = "Null"
      variable = "route53:ChangeResourceRecordSetsRecordTypes"
      values   = ["false"]
    }

    condition {
      test     = "ForAllValues:StringEquals"
      variable = "route53:ChangeResourceRecordSetsActions"
      values   = ["UPSERT", "DELETE"]
    }
    condition {
      test     = "Null"
      variable = "route53:ChangeResourceRecordSetsActions"
      values   = ["false"]
    }
  }
}

resource "aws_iam_role" "traefik_dns01" {
  count = local.enable_identity ? 1 : 0

  name                 = "home-lab-traefik-dns01"
  description          = "Traefik DNS-01 for home-lab via Roles Anywhere - TXT _acme-challenge only"
  assume_role_policy   = data.aws_iam_policy_document.ra_trust["traefik"].json
  max_session_duration = 3600

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "traefik_dns01" {
  count = local.enable_identity ? 1 : 0

  name   = "acme-challenge-txt-only"
  role   = aws_iam_role.traefik_dns01[0].id
  policy = data.aws_iam_policy_document.dns01.json
}

# ---- Pi host role: read-only on /home-lab, decrypt only through SSM with the home-lab key ----------------------------
data "aws_iam_policy_document" "pi_host" {
  statement {
    sid     = "ReadHomeLabParams"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [
      "arn:${local.partition}:ssm:${local.ssm_region}:${local.account_id}:parameter/home-lab",
      local.param_arn_glob,
    ]
  }

  statement {
    sid       = "DecryptViaSsmOnly"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.ssm.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.ssm_via_service]
    }
    condition {
      test     = "StringLike"
      variable = "kms:EncryptionContext:PARAMETER_ARN"
      values   = [local.param_arn_glob]
    }
  }

  # K4: the only SNS right in the whole stack. Publish to the one alert topic, nothing else (no Subscribe, no topic management).
  statement {
    sid       = "PublishHomeLabAlerts"
    effect    = "Allow"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]
  }

  # Migration window only (allow_legacy_ssm_key): secrets not yet re-set still sit under the AWS-managed key.
  dynamic "statement" {
    for_each = var.allow_legacy_ssm_key ? [1] : []
    content {
      sid       = "DecryptLegacyKeyViaSsmOnly"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [data.aws_kms_alias.legacy_ssm.target_key_arn]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = [local.ssm_via_service]
      }
    }
  }
}

resource "aws_iam_role" "pi_host" {
  count = local.enable_identity ? 1 : 0

  name                 = "home-lab-pi-host"
  description          = "Pi host deploy-time secret fetch for home-lab via Roles Anywhere - read-only SSM under /home-lab and publish to the alert topic"
  assume_role_policy   = data.aws_iam_policy_document.ra_trust["host"].json
  max_session_duration = 3600

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "pi_host" {
  count = local.enable_identity ? 1 : 0

  name   = "read-home-lab-parameters"
  role   = aws_iam_role.pi_host[0].id
  policy = data.aws_iam_policy_document.pi_host.json
}

# ---- One-off migration from terraform/edge (adopt_from_edge): import, never destroy or recreate ----------------------------
# Roles Anywhere profiles reference the roles, so a recreate would break both identities. Names are public-safe; the UUIDs
# come from the gitignored tfvars (adopt_ids). Import blocks that are already satisfied are no-ops.
import {
  for_each = var.adopt_from_edge && local.enable_identity ? toset(["x"]) : toset([])
  to       = aws_rolesanywhere_trust_anchor.ca[0]
  id       = var.adopt_ids.trust_anchor_id
}

import {
  for_each = var.adopt_from_edge && local.enable_identity ? toset(["x"]) : toset([])
  to       = aws_rolesanywhere_profile.traefik[0]
  id       = var.adopt_ids.traefik_profile_id
}

import {
  for_each = var.adopt_from_edge && local.enable_identity ? toset(["x"]) : toset([])
  to       = aws_rolesanywhere_profile.pi_host[0]
  id       = var.adopt_ids.pi_host_profile_id
}

import {
  for_each = var.adopt_from_edge && local.enable_identity ? toset(["x"]) : toset([])
  to       = aws_iam_role.traefik_dns01[0]
  id       = "home-lab-traefik-dns01"
}

import {
  for_each = var.adopt_from_edge && local.enable_identity ? toset(["x"]) : toset([])
  to       = aws_iam_role.pi_host[0]
  id       = "home-lab-pi-host"
}

import {
  for_each = var.adopt_from_edge && local.enable_identity ? toset(["x"]) : toset([])
  to       = aws_iam_role_policy.traefik_dns01[0]
  id       = "home-lab-traefik-dns01:acme-challenge-txt-only"
}

import {
  for_each = var.adopt_from_edge && local.enable_identity ? toset(["x"]) : toset([])
  to       = aws_iam_role_policy.pi_host[0]
  id       = "home-lab-pi-host:read-home-lab-parameters"
}

check "adopt_ids_present" {
  assert {
    condition     = !var.adopt_from_edge || var.adopt_ids != null
    error_message = "adopt_from_edge needs adopt_ids (trust anchor and the two profile UUIDs from the edge outputs)."
  }
}
