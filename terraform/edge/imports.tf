# Adoption of the hand-made Route 53 setup (runbook docs/runbooks/adopt-existing-route53.md).
# Every real value (zone ID, record names and values, name servers) arrives through HCP workspace variables, so the
# public repo contains none of them. Import blocks that are already satisfied are no-ops, so they may stay.

import {
  to = aws_route53_zone.primary
  id = var.existing_zone_id
}

# Existing records. Import ID format: ZONEID_name_TYPE[_SETIDENTIFIER].
import {
  for_each = var.existing_records
  to       = aws_route53_record.existing[each.key]
  id       = join("_", compact([var.existing_zone_id, each.value.name, each.value.type, each.value.set_identifier]))
}

# Records that collide with a planned lab record are imported at the planned address (variable adopt_planned_records).
import {
  for_each = var.adopt_planned_records.wildcard_a ? toset(["wildcard"]) : toset([])
  to       = aws_route53_record.wildcard[0]
  id       = "${var.existing_zone_id}_*.${var.domain}_A"
}

import {
  for_each = var.adopt_planned_records.www_txt ? toset(["www"]) : toset([])
  to       = aws_route53_record.www_reserved[0]
  id       = "${var.existing_zone_id}_www.${var.domain}_TXT"
}

import {
  for_each = var.adopt_planned_records.apex_caa ? toset(["caa"]) : toset([])
  to       = aws_route53_record.caa[0]
  id       = "${var.existing_zone_id}_${var.domain}_CAA"
}

# Registered domain (Route 53 Domains, us-east-1). Imported by domain name; this never registers or renews anything.
import {
  provider = aws.us_east_1
  to       = aws_route53domains_registered_domain.this
  id       = var.domain
}

import {
  for_each = toset(var.duplicate_zone_ids)
  to       = aws_route53_zone.duplicate[each.value]
  id       = each.value
}
