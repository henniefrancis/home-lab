# The hosted zone that is already delegated from the registered domain. Created by hand originally, adopted here by
# the import block in imports.tf. Never recreated.
resource "aws_route53_zone" "primary" {
  name    = var.domain
  comment = var.existing_zone_comment

  lifecycle {
    prevent_destroy = true
  }
}

# Duplicate zones (same name, different NS set) exist only so Terraform can delete them with owner approval.
# Remove an ID from duplicate_zone_ids to delete that zone (force_destroy removes its records first).
resource "aws_route53_zone" "duplicate" {
  for_each = toset(var.duplicate_zone_ids)

  name          = var.domain
  force_destroy = true

  lifecycle {
    # The comment of a throwaway zone is irrelevant, and ignoring it keeps the adoption plan clean.
    ignore_changes = [comment]
  }
}
