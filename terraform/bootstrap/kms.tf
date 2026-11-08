# Customer-managed key for the /home-lab SecureStrings (SEC-M2). The previous key, the account-wide AWS-managed alias/aws/ssm,
# has a key policy that lets any principal with an IAM allow decrypt through SSM. This key's policy names its users:
#   - the owner's admin role may ENCRYPT through SSM (set-secret.sh) but never decrypt,
#   - the HCP roles have no access at all (Terraform no longer manages the SecureStrings, ADR-013),
#   - only the Pi host role may DECRYPT, only through SSM and only for parameters under /home-lab/ (encryption context),
#   - everything else is denied Decrypt, and the account root keeps key MANAGEMENT only (no cryptographic use), so an
#     administrator can always fix the policy but needs one deliberate step to read a secret.
locals {
  enable_identity = var.ca_cert_pem != null
  ssm_via_service = "ssm.${local.ssm_region}.amazonaws.com"
  param_arn_glob  = "arn:${local.partition}:ssm:${local.ssm_region}:${local.account_id}:parameter/home-lab/*"
  account_root    = "arn:${local.partition}:iam::${local.account_id}:root"
}

# Only used while allow_legacy_ssm_key is true (migration window).
data "aws_kms_alias" "legacy_ssm" {
  provider = aws.af_south_1
  name     = "alias/aws/ssm"
}

data "aws_iam_policy_document" "ssm_key" {
  statement {
    sid    = "AccountManagesKeyNoCryptoUse"
    effect = "Allow"
    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  statement {
    sid       = "OwnerEncryptViaSsm"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:PrincipalArn"
      values   = [var.owner_role_arn_pattern]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = [local.ssm_via_service]
    }
  }

  dynamic "statement" {
    for_each = local.enable_identity ? [1] : []
    content {
      sid       = "PiHostDecryptViaSsmForHomeLabParameters"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = ["*"]

      principals {
        type        = "AWS"
        identifiers = [aws_iam_role.pi_host[0].arn]
      }
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
  }

  statement {
    sid       = "DenyDecryptExceptPiHost"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:ReEncryptFrom"]
    resources = ["*"]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [local.host_role_arn]
    }
  }
}

resource "aws_kms_key" "ssm" {
  provider = aws.af_south_1

  description              = "home-lab SecureString parameters (SSM Parameter Store)"
  key_usage                = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"
  enable_key_rotation      = true
  rotation_period_in_days  = 365
  deletion_window_in_days  = 30
  multi_region             = false
  policy                   = data.aws_iam_policy_document.ssm_key.json

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "ssm" {
  provider = aws.af_south_1

  name          = "alias/home-lab-ssm"
  target_key_id = aws_kms_key.ssm.key_id
}
