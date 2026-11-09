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
}
