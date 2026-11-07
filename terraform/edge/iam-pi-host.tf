# Role for the Pi host's deploy-time secret fetch (scripts/fetch-secrets.sh). It has its OWN certificate (CN
# home-lab-pi-host), separate from the Traefik one, so a Traefik compromise cannot read any secret.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm" # the AWS-managed key behind SecureStrings; exists once SSM has been used in the region
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  ssm_param_arn_root = "arn:${data.aws_partition.current.partition}:ssm:af-south-1:${data.aws_caller_identity.current.account_id}:parameter/home-lab"
}

data "aws_iam_policy_document" "pi_host_trust" {
  count = local.enable_roles_anywhere ? 1 : 0

  statement {
    sid    = "RolesAnywherePiHost"
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
      values   = ["home-lab-pi-host"]
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

# Read-only on /home-lab and below. GetParametersByPath is authorised against the path ARN itself
# (parameter/home-lab) and, for recursive reads, the parameters beneath it (parameter/home-lab/*).
data "aws_iam_policy_document" "pi_host" {
  statement {
    sid       = "ReadHomeLabParams"
    effect    = "Allow"
    actions   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
    resources = [local.ssm_param_arn_root, "${local.ssm_param_arn_root}/*"]
  }

  statement {
    sid       = "DecryptViaSsmOnly"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.af-south-1.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "pi_host" {
  count = local.enable_roles_anywhere ? 1 : 0

  name                 = "home-lab-pi-host"
  description          = "Pi host deploy-time secret fetch for home-lab via Roles Anywhere - read-only SSM under /home-lab"
  assume_role_policy   = data.aws_iam_policy_document.pi_host_trust[0].json
  max_session_duration = 3600
}

resource "aws_iam_role_policy" "pi_host" {
  count = local.enable_roles_anywhere ? 1 : 0

  name   = "read-home-lab-parameters"
  role   = aws_iam_role.pi_host[0].id
  policy = data.aws_iam_policy_document.pi_host.json
}
