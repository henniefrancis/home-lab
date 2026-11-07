# Run once from the owner's laptop. State lives in HCP Terraform (workspace "home-lab-bootstrap", LOCAL execution),
# so the AWS SSO profile on the laptop is what authenticates. The organization comes from TF_CLOUD_ORGANIZATION
# and is deliberately not written here.
terraform {
  # The plan pinned 1.17.x; 1.16 is accepted too because the features used here (check blocks, import for_each,
  # optional() object attributes) exist since 1.7. See docs/runbooks/hcp-terraform-bootstrap.md.
  required_version = "~> 1.16"

  cloud {
    workspaces {
      name = "home-lab-bootstrap"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}
