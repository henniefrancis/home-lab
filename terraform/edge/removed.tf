# SEC-H1 migration: the Roles Anywhere trust anchor, the two profiles and the two lab roles (with their inline policies) are
# now defined in terraform/bootstrap (owner admin SSO). These blocks only FORGET them in this stack's state: destroy = false,
# so nothing in AWS is touched. Order (docs/runbooks/sec-remediation-apply-order.md): apply bootstrap first (it imports the
# live objects), then apply this stack. Once this has been applied, the blocks may be deleted.
removed {
  from = aws_iam_role_policy.traefik_dns01
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy.pi_host
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_rolesanywhere_profile.traefik
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_rolesanywhere_profile.pi_host
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.traefik_dns01
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role.pi_host
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_rolesanywhere_trust_anchor.ca
  lifecycle {
    destroy = false
  }
}
