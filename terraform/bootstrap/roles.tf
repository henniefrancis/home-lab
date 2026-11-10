locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  sub_prefix = "organization:${var.hcp_organization}:project:${var.hcp_project}:workspace:${var.hcp_workspace}:run_phase"

  # The two lab roles are defined in identity.tf (this stack). The HCP roles below have NO write access to any role,
  # trust policy, Roles Anywhere resource or IAM policy (SEC-H1).
  host_role_arn = "arn:${local.partition}:iam::${local.account_id}:role/home-lab-pi-host"
  budget_arn    = "arn:${local.partition}:budgets::${local.account_id}:budget/home-lab-monthly"
  ssm_region    = "af-south-1"
  # Only the Terraform-owned String parameters (decision 2026-11-08, ADR-013). The SecureStrings are set by the owner with
  # scripts/set-secret.sh and are outside the reach of both HCP roles.
  ssm_params = "arn:${local.partition}:ssm:${local.ssm_region}:${local.account_id}:parameter/home-lab/config/*"

  # SEC-M1: Route 53 write actions are limited to the home-lab zone (plus the duplicates still to be deleted).
  zone_arn        = "arn:${local.partition}:route53:::hostedzone/${var.home_lab_zone_id}"
  duplicate_zones = [for z in var.duplicate_zone_ids : "arn:${local.partition}:route53:::hostedzone/${z}"]
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

  # The /home-lab/config/* String parameters only: no SecureString is readable by the plan role, and there is no kms permission.
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

  # SEC-M1: only the home-lab zone (and duplicates awaiting deletion), never a wildcard over all hosted zones. The account also holds other
  # zones. CreateHostedZone is not granted: the zone is adopted, never created, by this stack.
  statement {
    sid    = "Route53ZoneWrite"
    effect = "Allow"
    actions = [
      "route53:ChangeTagsForResource",
      "route53:UpdateHostedZoneComment",
      "route53:ChangeResourceRecordSets",
    ]
    resources = concat([local.zone_arn], local.duplicate_zones)
  }

  # DeleteHostedZone exists only for the duplicate zones; the real zone is also protected by prevent_destroy.
  dynamic "statement" {
    for_each = length(local.duplicate_zones) > 0 ? [1] : []
    content {
      sid       = "Route53DeleteDuplicateZones"
      effect    = "Allow"
      actions   = ["route53:DeleteHostedZone"]
      resources = local.duplicate_zones
    }
  }

  statement {
    sid       = "Route53GetChange"
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:${local.partition}:route53:::change/*"]
  }

  # Route 53 Domains has NO resource-level permissions (the service authorization reference lists no resource types),
  # so these cannot be limited to the lab domain; the account holds other registered domains. Only protective or
  # metadata actions are allowed. Name server changes and DisableDomainAutoRenew are denied below and become an
  # owner (admin SSO) operation: that is the tightest option IAM offers.
  statement {
    sid    = "Route53DomainsWrite"
    effect = "Allow"
    actions = [
      "route53domains:EnableDomainAutoRenew",
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
      "route53domains:UpdateDomainNameservers",
      "route53domains:DisableDomainAutoRenew",
    ]
    resources = ["*"]
  }

  # SEC-H1: explicit belt and braces. No identity (role, trust policy, inline policy, Roles Anywhere trust anchor or
  # profile) can be created or changed by the HCP apply role, now or through a later policy edit.
  statement {
    sid    = "DenyIdentityChanges"
    effect = "Deny"
    actions = [
      "iam:Create*",
      "iam:Update*",
      "iam:Put*",
      "iam:Attach*",
      "iam:Detach*",
      "iam:Delete*",
      "iam:Add*",
      "iam:Remove*",
      "iam:Set*",
      "iam:Tag*",
      "iam:Untag*",
      "iam:PassRole",
      "sts:AssumeRole",
      "rolesanywhere:Create*",
      "rolesanywhere:Update*",
      "rolesanywhere:Delete*",
      "rolesanywhere:Put*",
      "rolesanywhere:Enable*",
      "rolesanywhere:Disable*",
      "rolesanywhere:Import*",
      "rolesanywhere:Tag*",
      "rolesanywhere:Untag*",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "SsmHomeLabConfig"
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

  # SEC-M2: no kms permission at all (the config parameters are plain String) and an explicit deny on decrypting anything.
  statement {
    sid       = "DenyKmsDecrypt"
    effect    = "Deny"
    actions   = ["kms:Decrypt", "kms:ReEncrypt*", "kms:CreateGrant"]
    resources = ["*"]
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
