resource "aws_route53_zone" "cluster_zones" {
  for_each = { for cluster in var.clusters : cluster.name => cluster }
  
  name = "${each.value.name}.${var.subdomain_prefix}.${var.parent_zone_name}"
  
  tags = {
    Name      = "${each.value.name}.${var.subdomain_prefix}.${var.parent_zone_name}"
    Cluster   = each.value.name
    ManagedBy = "terraform"
  }
}

resource "aws_route53_record" "cluster_ns_delegation" {
  for_each = aws_route53_zone.cluster_zones
  
  zone_id = var.parent_zone_id
  name    = "${each.key}.${var.subdomain_prefix}.${var.parent_zone_name}"
  type    = "NS"
  ttl     = 300
  
  records = each.value.name_servers
}