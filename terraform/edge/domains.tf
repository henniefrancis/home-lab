# Adopts the registered domain's nameserver, renewal and lock settings. Contacts and privacy are NOT managed.
# aws_route53domains_domain is banned in this repo (it can register, renew and deregister domains); CI guards that.
resource "aws_route53domains_registered_domain" "this" {
  provider    = aws.us_east_1
  domain_name = var.domain

  dynamic "name_server" {
    for_each = var.registered_name_servers # exactly as currently registered
    content {
      name = name_server.value
    }
  }

  auto_renew    = var.domain_auto_renew
  transfer_lock = var.domain_transfer_lock

  lifecycle {
    prevent_destroy = true
  }
}
