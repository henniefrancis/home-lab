locals {
  tags = {
    Project   = "home-lab"
    ManagedBy = "terraform"
    Owner     = "hennie"
    Repo      = "github.com/henniefrancis/home-lab"
  }
}

provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region

  default_tags {
    tags = local.tags
  }
}

# SSM and its KMS key are regional; the key lookup in roles.tf needs af-south-1.
provider "aws" {
  alias   = "af_south_1"
  profile = var.aws_profile
  region  = "af-south-1"

  default_tags {
    tags = local.tags
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}
