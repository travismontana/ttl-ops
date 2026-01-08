output "zone_ids" {
  description = "Map of cluster names to their Route53 zone IDs"
  value       = { for k, zone in aws_route53_zone.cluster_zones : k => zone.zone_id }
}

output "zone_name_servers" {
  description = "Map of cluster names to their nameservers"
  value       = { for k, zone in aws_route53_zone.cluster_zones : k => zone.name_servers }
}