# Alert path (K4): one SNS topic that the Pi publishes to when a certificate check fails, and one email subscription.
# Region af-south-1, next to SSM. The topic is encrypted with the AWS-managed key alias/aws/sns, NOT the home-lab CMK: the CMK
# key policy (kms.tf) denies Decrypt to everyone but the Pi host role, which would also block the SNS service from delivering
# the message, and widening it for SNS would weaken SEC-M2. An alert carries no secret (check name, days left), so the managed key is enough.
# Only the Pi host role may publish (identity.tf, statement PublishHomeLabAlerts); nobody else gains any SNS right.
resource "aws_sns_topic" "alerts" {
  provider = aws.af_south_1

  name              = "home-lab-alerts"
  display_name      = "home-lab alerts"
  kms_master_key_id = "alias/aws/sns"
}

# Email subscriptions stay "pending confirmation" until the owner clicks the link in the confirmation mail (runbook: alerting).
resource "aws_sns_topic_subscription" "alerts_email" {
  provider = aws.af_south_1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email

  # SEC N-1: create the subscription only after the topic policy exists, so a first apply never races the Subscribe deny.
  depends_on = [aws_sns_topic_policy.alerts]
}

# SEC-L-1: an explicit topic policy instead of the SNS default (which lets any principal in the account with an IAM allow publish,
# subscribe or rewrite the topic). The account root statement keeps IAM in charge for the owner; the denies below narrow it:
#   - TLS only for Publish and Subscribe,
#   - Publish only for the Pi host role and the owner's admin role (the owner can run a manual test publish),
#   - Subscribe and topic management only for the owner's admin role (and the account root, so a wrong pattern cannot lock the topic away).
# Email subscriptions are confirmed by the link in the mail, which is not an IAM call and is not affected.
data "aws_iam_policy_document" "alerts_topic" {
  statement {
    sid    = "AccountOwnsTopic"
    effect = "Allow"
    actions = [
      "sns:Publish",
      "sns:Subscribe",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:ListSubscriptionsByTopic",
      "sns:AddPermission",
      "sns:RemovePermission",
      "sns:DeleteTopic",
      "sns:TagResource",
      "sns:UntagResource",
    ]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "AWS"
      identifiers = [local.account_root]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["sns:Publish", "sns:Subscribe"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyPublishExceptPiHostAndOwner"
    effect    = "Deny"
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [local.host_role_arn, var.owner_role_arn_pattern]
    }
  }

  statement {
    sid    = "DenySubscribeAndManagementExceptOwner"
    effect = "Deny"
    actions = [
      "sns:Subscribe",
      "sns:SetTopicAttributes",
      "sns:AddPermission",
      "sns:RemovePermission",
      "sns:DeleteTopic",
    ]
    resources = [aws_sns_topic.alerts.arn]

    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = [var.owner_role_arn_pattern, local.account_root]
    }
  }
}

resource "aws_sns_topic_policy" "alerts" {
  provider = aws.af_south_1

  arn    = aws_sns_topic.alerts.arn
  policy = data.aws_iam_policy_document.alerts_topic.json
}
