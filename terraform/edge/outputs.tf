output "zone_id" {
  description = "Hosted zone ID, for ROUTE53_ZONE_ID in the Pi .env."
  value       = aws_route53_zone.primary.zone_id
}

output "name_servers" {
  description = "Name servers of the adopted zone."
  value       = aws_route53_zone.primary.name_servers
}
