# Runs REMOTELY in HCP Terraform (workspace "home-lab", CLI-driven) with OIDC dynamic credentials.
# The organization comes from TF_CLOUD_ORGANIZATION and is deliberately not written here.
terraform {
  # The plan pinned 1.17.x; 1.16 is accepted too (features used exist since 1.7). Set the HCP workspace's
  # Terraform version to a release the owner is happy with; see docs/runbooks/hcp-terraform-bootstrap.md.
  required_version = "~> 1.16"

  cloud {
    workspaces {
      name = "home-lab"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.72"
    }
  }
}
