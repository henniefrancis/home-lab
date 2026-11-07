# All values are HCP workspace variables set by the owner (see workspace-variables.example.md).
# There are NO tfvars files for this stack: CLI-driven remote runs would upload them.

variable "domain" {
  description = "The registered domain, for example example.com."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.domain))
    error_message = "domain must be a lowercase domain name without a trailing dot."
  }
}

variable "existing_zone_id" {
  description = "ID of the DELEGATED hosted zone (its NS set equals the registered NS), from aws-preflight.sh."
  type        = string

  validation {
    condition     = can(regex("^Z[A-Z0-9]{8,31}$", var.existing_zone_id))
    error_message = "existing_zone_id must look like a Route 53 hosted zone ID (starts with Z)."
  }
}

variable "existing_zone_comment" {
  description = "Current zone comment, mirrored so that adopting the zone is a no-op."
  type        = string
  default     = ""
}

variable "registered_name_servers" {
  description = "The registered domain's name servers, copied exactly and in the same order as currently registered."
  type        = list(string)

  validation {
    condition     = length(var.registered_name_servers) >= 2 && length(var.registered_name_servers) <= 6
    error_message = "registered_name_servers needs between 2 and 6 entries."
  }
}

variable "domain_auto_renew" {
  description = "Current auto-renew setting of the registered domain (mirrored)."
  type        = bool
  default     = true
}

variable "domain_transfer_lock" {
  description = "Current transfer-lock setting (mirrored). null when the TLD does not support it (for example co.za)."
  type        = bool
  default     = null
}

variable "existing_records" {
  description = "Existing records of the delegated zone to adopt, excluding apex NS/SOA, values exactly as found."
  type = map(object({
    name           = string
    type           = string
    ttl            = optional(number)
    records        = optional(set(string))
    set_identifier = optional(string)
    alias = optional(object({
      name                   = string
      zone_id                = string
      evaluate_target_health = optional(bool, false)
    }))
  }))
  default = {}

  validation {
    condition = alltrue([
      for r in values(var.existing_records) :
      (r.alias != null && r.records == null && r.ttl == null) || (r.alias == null && r.records != null && r.ttl != null)
    ])
    error_message = "Each existing record is either an alias (no ttl, no records) or a standard record (ttl and records)."
  }

  validation {
    condition     = alltrue([for r in values(var.existing_records) : !contains(["NS", "SOA"], r.type) || r.name != var.domain])
    error_message = "Apex NS and SOA records are owned by the zone and must not be listed."
  }

  validation {
    condition     = alltrue([for r in values(var.existing_records) : !startswith(r.name, "_acme-challenge.")])
    error_message = "_acme-challenge records belong to Traefik and must not be managed here."
  }
}

variable "duplicate_zone_ids" {
  description = "IDs of duplicate hosted zones to adopt and then remove via Terraform (expected to be empty)."
  type        = list(string)
  default     = []
}

variable "adopt_planned_records" {
  description = "Set a flag true when a record already exists at the address of a planned lab record, so it is imported there instead of created."
  type = object({
    wildcard_a = optional(bool, false)
    www_txt    = optional(bool, false)
    apex_caa   = optional(bool, false)
  })
  default = {}
}

variable "create_planned_records" {
  description = "Create the planned www TXT placeholder and apex CAA records. Leave false until the adoption apply is done."
  type        = bool
  default     = false
}

variable "pi_tailnet_ipv4" {
  description = "Tailnet IPv4 address of the Pi. null until M2; the wildcard A record exists only when set."
  type        = string
  default     = null

  validation {
    condition     = var.pi_tailnet_ipv4 == null || can(regex("^100\\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\\.[0-9]{1,3}\\.[0-9]{1,3}$", coalesce(var.pi_tailnet_ipv4, "")))
    error_message = "pi_tailnet_ipv4 must be in the Tailscale CGNAT range 100.64.0.0/10."
  }
}

variable "ca_cert_pem" {
  description = "PEM of the offline CA certificate (public). null until M2; Roles Anywhere and the DNS-01 role exist only when set."
  type        = string
  default     = null

  validation {
    condition     = var.ca_cert_pem == null || can(regex("-----BEGIN CERTIFICATE-----", coalesce(var.ca_cert_pem, "")))
    error_message = "ca_cert_pem must be a PEM-encoded certificate."
  }
}

variable "budget_usd" {
  description = "Monthly budget limit in USD."
  type        = number
  default     = 5

  validation {
    condition     = var.budget_usd > 0
    error_message = "budget_usd must be positive."
  }
}

variable "budget_email" {
  description = "Address for budget alerts (sensitive). null until set; the budget exists only when set."
  type        = string
  default     = null
  sensitive   = true

  validation {
    condition     = var.budget_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", coalesce(var.budget_email, "")))
    error_message = "budget_email must look like an email address."
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

variable "create_ssm_parameters" {
  description = "Create the SSM parameters under /home-lab/. Leave false during the adoption apply so that it is imports only."
  type        = bool
  default     = false
}
