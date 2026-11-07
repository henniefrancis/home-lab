# HCP Terraform as an OIDC identity provider (audience aws.workload.identity). AWS allows one provider per URL per
# account, and aws-preflight.sh found that app.terraform.io already exists here (it is shared with another Terraform
# stack). oidc_provider_mode chooses what this stack does about it:
#   create   - create it (account has none)
#   import   - adopt it and manage it from here (this stack becomes the only owner)
#   existing - read it and manage nothing (safe when another stack owns it)
# No thumbprint is needed: AWS validates app.terraform.io against its trusted CA library.
locals {
  create_oidc  = contains(["create", "import"], var.oidc_provider_mode)
  oidc_arn     = local.create_oidc ? aws_iam_openid_connect_provider.hcp[0].arn : data.aws_iam_openid_connect_provider.hcp[0].arn
  oidc_url_arn = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "hcp" {
  count = local.create_oidc ? 1 : 0

  url            = "https://app.terraform.io"
  client_id_list = ["aws.workload.identity"]

  lifecycle {
    prevent_destroy = true
  }
}

import {
  for_each = var.oidc_provider_mode == "import" ? toset(["app.terraform.io"]) : toset([])
  to       = aws_iam_openid_connect_provider.hcp[0]
  id       = local.oidc_url_arn
}

data "aws_iam_openid_connect_provider" "hcp" {
  count = local.create_oidc ? 0 : 1

  arn = local.oidc_url_arn

  lifecycle {
    postcondition {
      condition     = contains(self.client_id_list, "aws.workload.identity")
      error_message = "The existing app.terraform.io OIDC provider does not list the client ID aws.workload.identity."
    }
  }
}
