variable "parent_zone_id" {
  description = "The Route53 zone ID for the parent domain"
  type        = string
}

variable "parent_zone_name" {
  description = "The parent domain name (e.g., tailandtraillabs.org)"
  type        = string
}

variable "clusters" {
  description = "List of cluster configurations"
  type = list(object({
    name = string
  }))
}

variable "subdomain_prefix" {
  description = "Subdomain prefix (e.g., 'abode' for cluster.abode.domain.com)"
  type        = string
  default     = "abode"
}