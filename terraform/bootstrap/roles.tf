locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  sub_prefix = "organization:${var.hcp_organization}:project:${var.hcp_project}:workspace:${var.hcp_workspace}:run_phase"

  # The one role the apply role may manage (the DNS-01 role for Traefik, created by terraform/edge).
  acme_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/home-lab-traefik-dns01"
  host_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/home-lab-pi-host"
  lab_role_arns = [local.acme_role_arn, local.host_role_arn]
  budget_arn    = "arn:${local.partition}:budgets::${local.account_id}:budget/home-lab-monthly"
  ssm_region    = "af-south-1"
  ssm_params    = "arn:${local.partition}:ssm:${local.ssm_region}:${local.account_id}:parameter/home-lab/*"
  ssm_key_arn   = data.aws_kms_alias.ssm.target_key_arn
}

# The AWS-managed key behind SecureStrings. It exists once SSM has been used in the region (preflight checks this).
data "aws_kms_alias" "ssm" {
  provider = aws.af_south_1
  name     = "alias/aws/ssm"
}

# ---- Trust policies: exact audience and exact per-phase subject, no wildcards --------------------------------
data "aws_iam_policy_document" "trust" {
  for_each = toset(["plan", "apply"])

  statement {
    sid     = "HcpTerraformRunPhase${title(each.key)}"
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.oidc_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "app.terraform.io:aud"
      values   = ["aws.workload.identity"]
    }

    condition {
      test     = "StringEquals"
      variable = "app.terraform.io:sub"
      values   = ["${local.sub_prefix}:${each.key}"]
    }
  }
}

# ---- Read-only permissions (plan role; also included in the apply role) --------------------------------------
data "aws_iam_policy_document" "read" {
  statement {
    sid       = "Route53Read"
    effect    = "Allow"
    actions   = ["route53:Get*", "route53:List*"]
    resources = ["*"]
  }

  statement {
    sid    = "Route53DomainsRead"
    effect = "Allow"
    actions = [
      "route53domains:GetDomainDetail",
      "route53domains:ListTagsForDomain",
      "route53domains:GetOperationDetail",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "RolesAnywhereRead"
    effect    = "Allow"
    actions   = ["rolesanywhere:Get*", "rolesanywhere:List*"]
    resources = ["*"]
  }

  statement {
    sid    = "IamRoleRead"
    effect = "Allow"
    actions = [
      "iam:GetRole",
      "iam:GetRolePolicy",
      "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies",
      "iam:ListRoleTags",
      "iam:ListInstanceProfilesForRole",
    ]
    resources = ["*"]
  }

  # Metadata and ListTags only. Values are never read by the plan role, so no kms:Decrypt here: add it only if
  # the refresh-only verification (docs/runbooks/secrets-ssm.md) proves the provider needs it.
  statement {
    sid    = "SsmRead"
    effect = "Allow"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:ListTagsForResource",
    ]
    resources = [local.ssm_params]
  }

  statement {
    sid       = "SsmDescribe"
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  statement {
    sid       = "KmsAliasLookup"
    effect    = "Allow"
    actions   = ["kms:ListAliases", "kms:DescribeKey"]
    resources = ["*"]
  }

  statement {
    sid       = "BudgetsRead"
    effect    = "Allow"
    actions   = ["budgets:ViewBudget", "budgets:ListTagsForResource"]
    resources = ["*"]
  }

  statement {
    sid       = "WhoAmI"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

# ---- Scoped write permissions (apply role only) --------------------------------------------------------------
data "aws_iam_policy_document" "write" {
  source_policy_documents = [data.aws_iam_policy_document.read.json]

  statement {
    sid    = "Route53Write"
    effect = "Allow"
    actions = [
      "route53:DeleteHostedZone",
      "route53:ChangeTagsForResource",
      "route53:UpdateHostedZoneComment",
      "route53:ChangeResourceRecordSets",
    ]
    resources = ["arn:${local.partition}:route53:::hostedzone/*"]
  }

  statement {
    sid       = "Route53CreateZone"
    effect    = "Allow"
    actions   = ["route53:CreateHostedZone"]
    resources = ["*"]
  }

  statement {
    sid       = "Route53GetChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:${local.partition}:route53:::change/*"]
  }

  statement {
    sid    = "Route53DomainsWrite"
    effect = "Allow"
    actions = [
      "route53domains:UpdateDomainNameservers",
      "route53domains:EnableDomainAutoRenew",
      "route53domains:DisableDomainAutoRenew",
      "route53domains:EnableDomainTransferLock",
      "route53domains:UpdateTagsForDomain",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["us-east-1"]
    }
  }

  statement {
    sid    = "DenyDomainDanger"
    effect = "Deny"
    actions = [
      "route53domains:DeleteDomain",
      "route53domains:TransferDomain",
      "route53domains:TransferDomainToAnotherAwsAccount",
      "route53domains:AcceptDomainTransferFromAnotherAwsAccount",
      "route53domains:RejectDomainTransferFromAnotherAwsAccount",
      "route53domains:CancelDomainTransferToAnotherAwsAccount",
      "route53domains:RegisterDomain",
      "route53domains:RenewDomain",
      "route53domains:UpdateDomainContact",
      "route53domains:UpdateDomainContactPrivacy",
      "route53domains:RetrieveDomainAuthCode",
      "route53domains:DisableDomainTransferLock",
      "route53domains:PushDomain",
      "route53domains:AssociateDelegationSignerToDomain",
      "route53domains:DisassociateDelegationSignerFromDomain",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "RolesAnywhereWrite"
    effect = "Allow"
    actions = [
      "rolesanywhere:CreateTrustAnchor",
      "rolesanywhere:UpdateTrustAnchor",
      "rolesanywhere:EnableTrustAnchor",
      "rolesanywhere:DisableTrustAnchor",
      "rolesanywhere:CreateProfile",
      "rolesanywhere:UpdateProfile",
      "rolesanywhere:EnableProfile",
      "rolesanywhere:DisableProfile",
      "rolesanywhere:TagResource",
      "rolesanywhere:UntagResource",
      "rolesanywhere:PutNotificationSettings",
      "rolesanywhere:ResetNotificationSettings",
    ]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = ["af-south-1"]
    }
  }

  statement {
    sid    = "SsmHomeLab"
    effect = "Allow"
    actions = [
      "ssm:PutParameter",
      "ssm:DeleteParameter",
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:AddTagsToResource",
      "ssm:RemoveTagsFromResource",
      "ssm:ListTagsForResource",
    ]
    resources = [local.ssm_params]
  }

  statement {
    sid       = "KmsViaSsm"
    effect    = "Allow"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
    resources = [local.ssm_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["ssm.${local.ssm_region}.amazonaws.com"]
    }
  }

  statement {
    sid    = "LabRolesOnly"
    effect = "Allow"
    actions = [
      "iam:CreateRole",
      "iam:UpdateRole",
      "iam:UpdateAssumeRolePolicy",
      "iam:PutRolePolicy",
      "iam:DeleteRolePolicy",
      "iam:TagRole",
      "iam:UntagRole",
      "iam:DeleteRole",
    ]
    resources = local.lab_role_arns
  }

  statement {
    sid       = "PassLabRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = local.lab_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["rolesanywhere.amazonaws.com"]
    }
  }

  statement {
    sid       = "BudgetWrite"
    effect    = "Allow"
    actions   = ["budgets:ModifyBudget", "budgets:ViewBudget", "budgets:TagResource"]
    resources = [local.budget_arn]
  }
}

# ---- The roles ------------------------------------------------------------------------------------------------
resource "aws_iam_role" "plan" {
  name                 = "home-lab-hcp-plan"
  description          = "HCP Terraform plan phase for home-lab - read-only"
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
  max_session_duration = 3600

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "plan" {
  name   = "read-only"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.read.json
}

resource "aws_iam_role" "apply" {
  name                 = "home-lab-hcp-apply"
  description          = "HCP Terraform apply phase for home-lab - scoped write"
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
  max_session_duration = 3600

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "scoped-write"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.write.json
}
