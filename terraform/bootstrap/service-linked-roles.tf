# IAM Roles Anywhere creates AWSServiceRoleForRolesAnywhere (for its CloudWatch metrics) the first time a trust anchor is
# made in the account. The edge apply role deliberately has no iam:CreateServiceLinkedRole, so the role is made here, under
# the owner's admin SSO, and the edge stack can then create the trust anchor. Service-linked roles take no tags.
resource "aws_iam_service_linked_role" "rolesanywhere" {
  aws_service_name = "rolesanywhere.amazonaws.com"
  description      = "Used by IAM Roles Anywhere for the home-lab Pi trust anchor"

  lifecycle {
    prevent_destroy = true
  }
}
