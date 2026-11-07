variable "aws_profile" {
  description = "AWS CLI profile (IAM Identity Center) used for the one-off bootstrap run."
  type        = string
  default     = "henniefrancis"
}

variable "aws_region" {
  description = "Region for the IAM and STS calls made by the bootstrap. IAM is global, so any enabled region works."
  type        = string
  default     = "us-east-1"
}

variable "hcp_organization" {
  description = "HCP Terraform organization name. Supplied via gitignored terraform.tfvars, never committed."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{3,40}$", var.hcp_organization))
    error_message = "hcp_organization must be 3-40 characters of letters, digits, hyphen or underscore."
  }
}

variable "hcp_project" {
  description = "HCP Terraform project that holds the home-lab workspace."
  type        = string
  default     = "home-lab"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,40}$", var.hcp_project))
    error_message = "hcp_project must be letters, digits, hyphen or underscore."
  }
}

variable "hcp_workspace" {
  description = "HCP Terraform workspace that runs terraform/edge remotely."
  type        = string
  default     = "home-lab"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]{1,90}$", var.hcp_workspace))
    error_message = "hcp_workspace must be letters, digits, hyphen or underscore."
  }
}

variable "oidc_provider_mode" {
  description = "How to treat the app.terraform.io OIDC provider: create, import (adopt and manage) or existing (read only)."
  type        = string
  default     = "create"

  validation {
    condition     = contains(["create", "import", "existing"], var.oidc_provider_mode)
    error_message = "oidc_provider_mode must be create, import or existing."
  }
}
