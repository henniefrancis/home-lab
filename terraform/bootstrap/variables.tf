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

# ---- Identity stack (moved here from terraform/edge: SEC-H1) ---------------------------------------------------
# The Roles Anywhere trust anchor, the profiles and the two lab roles are defined in THIS stack, which only the owner
# applies (admin SSO, local execution). The HCP apply role can no longer change a trust policy or a role policy.

variable "domain" {
  description = "The registered lab domain (public-safe placeholder in git; the real value is in the gitignored tfvars)."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lowercase domain name without a trailing dot."
  }
}

variable "home_lab_zone_id" {
  description = "ID of the home-lab hosted zone. Scopes the apply role's Route 53 write actions and the DNS-01 role to this one zone."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{8,31}$", var.home_lab_zone_id))
    error_message = "home_lab_zone_id must look like a Route 53 hosted zone ID (starts with Z)."
  }
}

variable "duplicate_zone_ids" {
  description = "IDs of duplicate hosted zones that the edge stack may still delete (same list as the edge variable; normally empty)."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for z in var.duplicate_zone_ids : can(regex("^Z[A-Z0-9]{8,31}$", z))])
    error_message = "duplicate_zone_ids entries must look like Route 53 hosted zone IDs."
  }
}

variable "ca_cert_pem" {
  description = "PEM of the offline CA certificate (public). null until M2; the trust anchor, profiles and lab roles exist only when set."
  type        = string
  default     = null

  validation {
    condition     = var.ca_cert_pem == null || can(regex("-----BEGIN CERTIFICATE-----", coalesce(var.ca_cert_pem, "")))
    error_message = "ca_cert_pem must be a PEM-encoded certificate."
  }
}

variable "pki_generation" {
  description = "Certificate generation, pinned as the OU of both Pi certificates. Bump it (and reissue the certs) to revoke a lost Pi."
  type        = string
  default     = "gen-1"

  validation {
    condition     = can(regex("^[A-Za-z0-9-]{1,32}$", var.pki_generation))
    error_message = "pki_generation must be 1-32 letters, digits or hyphens."
  }
}

variable "owner_role_arn_pattern" {
  description = "ARN pattern of the owner's admin role (an IAM Identity Center permission set role), allowed to ENCRYPT secrets with the home-lab key via SSM (scripts/set-secret.sh). It never gets Decrypt. The SSO role path has NO region segment: arn:aws:iam::111111111111:role/aws-reserved/sso.amazonaws.com/AWSReservedSSO_AdministratorAccess_* (wildcards allowed; ArnLike)"
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[A-Za-z0-9+=,.@_/*-]+$", var.owner_role_arn_pattern))
    error_message = "owner_role_arn_pattern must be an IAM role ARN pattern (wildcards allowed)."
  }
}

variable "allow_legacy_ssm_key" {
  description = "Migration window only (SEC-M2): also let the Pi host role decrypt with the old AWS-managed key alias/aws/ssm, so secrets that have not been re-set yet stay readable. Set back to false after every secret was re-set with set-secret.sh."
  type        = bool
  default     = false
}

variable "adopt_from_edge" {
  description = "One-off (SEC-H1 migration): import the roles, policies, trust anchor and profiles that terraform/edge created, so no live identity is destroyed or recreated. Needs adopt_ids. Leave false on a fresh account."
  type        = bool
  default     = false
}

variable "adopt_ids" {
  description = "IDs (the UUID part of the ARN) of the existing trust anchor and the two profiles, from the edge outputs. Used only when adopt_from_edge is true."
  type = object({
    trust_anchor_id    = string
    traefik_profile_id = string
    pi_host_profile_id = string
  })
  default = null

  validation {
    condition     = var.adopt_ids == null || alltrue([for v in values(coalesce(var.adopt_ids, { a = "x" })) : can(regex("^[0-9a-f-]{36}$", v))])
    error_message = "adopt_ids values must be UUIDs (the part after the last slash of the ARN)."
  }
}

variable "enable_audit_logging" {
  description = "Create the multi-region CloudTrail trail (S3 bucket with log file validation) and an IAM Access Analyzer (SEC-L1). Leave false if the account already has an organisation trail."
  type        = bool
  default     = false
}
