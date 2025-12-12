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
    backend "s3" {
        bucket = "ttl-ops-terraform-state"
        key    = "lab/terraform.tfstate"
        region = "us-east-2"
    }
}

provider "aws" {
    region = "us-east-2"
}

provider "proxmox" {
    endpoint  = "https://intrepid.abode.tailandtraillabs.org:8006"
    api_token = var.token
    insecure  = true
    ssh {
        agent    = true
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
    type        = string
}

variable "ssh_public_key" {
    description = "Path to SSH public key"
    type        = string
    default     = "/home/bob/.ssh/id_ed25519.pub"
}

variable "ssh_private_key" {
    description = "Path to SSH private key"
    type        = string
    default     = "/home/bob/.ssh/id_ed25519"
}

variable "aws_credentials" {
    description = "Path to AWS credentials file"
    type        = string
    default     = "/home/bob/.aws/credentials"
}

locals {
    clusters_data = jsondecode(file(var.clusterfile))
}

module "dnszones" {
  source = "./modules/dnszones"
  
  parent_zone_id   = "Z096642825SZ7BHKNL1P0"  # Your tailandtraillabs.org zone ID
  parent_zone_name = "tailandtraillabs.org"
  subdomain_prefix = "abode"
  clusters         = local.clusters_data.cluster
}

module "vms" {
    source = "./modules/vm"

    for_each = { for cluster in local.clusters_data.cluster : cluster.name => cluster }
    
    cluster_name          = each.value.name
    cluster_control_nodes = each.value.numCnodes
    cluster_worker_nodes  = each.value.numWnodes
    appgroups            = each.value.appgroups
    ssh_public_key       = var.ssh_public_key
    ssh_private_key      = var.ssh_private_key
    aws_credentials      = var.aws_credentials
    domainname           = local.clusters_data.domainname
}