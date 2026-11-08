# Adopted records, recreated exactly as found. KEEP means leave the entry; REPLACE means edit it in a reviewed apply;
# DROP means delete the entry in a reviewed apply.
resource "aws_route53_record" "existing" {
  for_each = var.existing_records

  zone_id        = aws_route53_zone.primary.zone_id
  name           = each.value.name
  type           = each.value.type
  ttl            = each.value.ttl
  records        = each.value.records
  set_identifier = each.value.set_identifier

  dynamic "alias" {
    for_each = each.value.alias == null ? [] : [each.value.alias]
    content {
      name                   = alias.value.name
      zone_id                = alias.value.zone_id
      evaluate_target_health = alias.value.evaluate_target_health
    }
  }
}

# ---- Planned lab records ----------------------------------------------------------------------------------------

# Wildcard for every lab host, pointing at the Pi's tailnet address. Exists only once the Pi has joined the tailnet (M2).
resource "aws_route53_record" "wildcard" {
  count = var.pi_tailnet_ipv4 == null ? 0 : 1

  zone_id = aws_route53_zone.primary.zone_id
  name    = "*.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [var.pi_tailnet_ipv4]
}

# Route 53 answers a wildcard only for names that have no record of any type, so this placeholder keeps www off the
# wildcard until the public website exists.
resource "aws_route53_record" "www_reserved" {
  count = var.create_planned_records ? 1 : 0

  zone_id = aws_route53_zone.primary.zone_id
  name    = "www.${var.domain}"
  type    = "TXT"
  ttl     = 300
  records = ["reserved for public website"] # the provider adds the TXT wire quotes
}

# SEC-L5: only Let's Encrypt, only through dns-01 (the method Traefik uses), and, once the production account exists
# (acme_account_uri), only for that account, so a stolen _acme-challenge role cannot be used with another LE account.
# amazon.com is dropped (no ACM certificate is planned).
locals {
  caa_params = join(";", compact(["validationmethods=dns-01", var.acme_account_uri == null ? "" : "accounturi=${var.acme_account_uri}"]))
}

resource "aws_route53_record" "caa" {
  count = var.create_planned_records ? 1 : 0

  zone_id = aws_route53_zone.primary.zone_id
  name    = var.domain
  type    = "CAA"
  ttl     = 3600
  records = [
    "0 issue \"letsencrypt.org;${local.caa_params}\"",
    "0 issuewild \"letsencrypt.org;${local.caa_params}\"",
  ]
}

# Never managed here: apex NS/SOA (owned by the zone) and _acme-challenge (owned by Traefik at issuance).
# Never created here: apex or www address records pointing at the Pi, and AAAA records for lab names.
