locals {
  # Roles Anywhere resources need the offline CA certificate, which the owner supplies in M2.
  enable_roles_anywhere = var.ca_cert_pem != null
}

data "aws_iam_policy_document" "dns01_trust" {
  count = local.enable_roles_anywhere ? 1 : 0

  statement {
    sid    = "RolesAnywhereTraefikPi"
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
      values   = ["home-lab-pi-traefik"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Subject/OU"
      values   = [var.pki_generation]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:PrincipalTag/x509Issuer/CN"
      values   = ["home-lab-offline-ca"]
    }
  }
}

# TXT _acme-challenge only. ForAllValues is paired with a Null check on each key so that a request that omits the
# key cannot satisfy the condition vacuously.
data "aws_iam_policy_document" "dns01" {
  statement {
    sid       = "GetChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    sid       = "ListRecordsInZone"
    effect    = "Allow"
    actions   = ["route53:ListResourceRecordSets"]
    resources = [aws_route53_zone.primary.arn]
  }

  statement {
    sid       = "ChangeAcmeChallengeTxtOnly"
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets"]
    resources = [aws_route53_zone.primary.arn]

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
  count = local.enable_roles_anywhere ? 1 : 0

  name                 = "home-lab-traefik-dns01"
  description          = "Traefik DNS-01 for home-lab via Roles Anywhere - TXT _acme-challenge only"
  assume_role_policy   = data.aws_iam_policy_document.dns01_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "traefik_dns01" {
  count = local.enable_roles_anywhere ? 1 : 0

  name   = "acme-challenge-txt-only"
  role   = aws_iam_role.traefik_dns01[0].id
  policy = data.aws_iam_policy_document.dns01.json
}
