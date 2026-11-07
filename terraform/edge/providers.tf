locals {
  tags = {
    Project   = "home-lab"
    ManagedBy = "terraform"
    Owner     = "hennie"
    Repo      = "github.com/henniefrancis/home-lab"
  }
}

# Injected by HCP Terraform dynamic provider credentials (TFC_AWS_PROVIDER_AUTH=true). Never set it by hand.
variable "tfc_aws_dynamic_credentials" {
  description = "Injected by HCP Terraform dynamic provider credentials"
  type = object({
    default = object({ shared_config_file = string })
    aliases = map(object({ shared_config_file = string }))
  })
}

provider "aws" {
  region              = "af-south-1"
  shared_config_files = [var.tfc_aws_dynamic_credentials.default.shared_config_file]

  default_tags {
    tags = local.tags
  }
}

# The Route 53 Domains API only exists in us-east-1. It reuses the default dynamic credentials (same role, same
# shared config file). If a run shows the alias cannot authenticate, switch to a tagged alias as in the HCP docs.
provider "aws" {
  alias               = "us_east_1"
  region              = "us-east-1"
  shared_config_files = [var.tfc_aws_dynamic_credentials.default.shared_config_file]

  default_tags {
    tags = local.tags
  }
}
