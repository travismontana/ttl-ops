terraform {
    required_providers {
        proxmox = {
        source  = "bpg/proxmox"
        }
        aws = {
            source  = "hashicorp/aws"
            version = "~> 5.0"
        }
    }
}

provider "aws" {
  region = "us-east-2"  # or wherever your Route53 is
  # Uses AWS credentials from environment or ~/.aws/credentials
}

provider "proxmox" {
    endpoint = "https://intrepid.abode.tailandtraillabs.org:8006"
    api_token = var.token
    insecure = true
    ssh {
        agent = true
        username = "root"
    }
}

variable "clusterfile" {
    description = "Path to JSON file containing cluster definitions"
    type        = string
    default     = "clusters.json"
}

variable "token" {
    description = "Proxmox API token in the format 'USER@REALM!TOKENID=SECRET'"
  
}

locals {
    clusters_data = jsondecode(file(var.clusterfile))
}

module "vms" {
    source = "./modules/vm"

    for_each = { for cluster in local.clusters_data.cluster : cluster.name => cluster }
    cluster_name        = each.key
    cluster_numnodes    = each.value.numnodes
    appgroups       = each.value.appgroups
}