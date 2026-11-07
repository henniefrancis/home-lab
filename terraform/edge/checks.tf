check "registered_ns_match_zone" {
  assert {
    condition = toset([for n in var.registered_name_servers : trimsuffix(lower(n), ".")]) == toset([
      for n in aws_route53_zone.primary.name_servers : trimsuffix(lower(n), ".")
    ])
    error_message = "Registered domain NS do not match the adopted hosted zone NS - wrong zone imported or delegation drift."
  }
}

check "planned_record_adoption_flags" {
  assert {
    condition = (
      (!var.adopt_planned_records.wildcard_a || var.pi_tailnet_ipv4 != null) &&
      (!(var.adopt_planned_records.www_txt || var.adopt_planned_records.apex_caa) || var.create_planned_records)
    )
    error_message = "adopt_planned_records needs the matching record enabled (pi_tailnet_ipv4 for the wildcard, create_planned_records for www and CAA)."
  }
}
