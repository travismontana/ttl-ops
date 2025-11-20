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
