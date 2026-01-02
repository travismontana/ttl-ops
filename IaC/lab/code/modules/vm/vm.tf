variable "cluster_name" {
  description = "Name of the Proxmox cluster"
  type        = string
}

variable "cluster_control_nodes" {
  description = "Number of control plane nodes (must be 1 or multiple of 3: 1, 3, 6, 9...)"
  type        = number
  default     = 1
  
  validation {
    condition     = var.cluster_control_nodes >= 1 && (var.cluster_control_nodes == 1 || var.cluster_control_nodes % 3 == 0)
    error_message = "Control nodes must be 1 or a multiple of 3 (1, 3, 6, 9, etc.)."
  }
}

variable "cluster_worker_nodes" {
  description = "Number of worker nodes (must be 0, 1, or multiple of 3: 0, 1, 3, 6, 9...)"
  type        = number
  default     = 0
  
  validation {
    condition     = var.cluster_worker_nodes >= 0 && (var.cluster_worker_nodes <= 1 || var.cluster_worker_nodes % 3 == 0)
    error_message = "Worker nodes must be 0, 1, or a multiple of 3 (0, 1, 3, 6, 9, etc.)."
  }
}

variable "proxmox_node" {
  description = "Proxmox node name to deploy VMs to"
  type        = string
  default     = "intrepid"
}

variable "appgroups" {
  description = "Application groups for this cluster"
  type        = list(map(bool))
  default     = []
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

variable "domainname" {
  description = "Domain name for the cluster"
  type        = string
}

locals {
  total_nodes = var.cluster_control_nodes + var.cluster_worker_nodes
  
  # Minimum 1 node required
  validate_min_nodes = var.cluster_control_nodes >= 1 ? true : tobool("At least 1 control node required")
  
  # Generate node roles: first N are control, rest are workers
  node_roles = [
    for i in range(local.total_nodes) : 
      i < var.cluster_control_nodes ? "control" : "worker"
  ]
  
  # Single node gets both roles
  is_single_node = local.total_nodes == 1
}

resource "proxmox_virtual_environment_vm" "cluster_vms" {
  count       = local.total_nodes
  name        = "${var.cluster_name}-node${count.index}" 
  node_name   = var.proxmox_node
  description = "Managed by Terraform - Role: ${local.node_roles[count.index]}${local.is_single_node ? " (control+worker)" : ""}"
  tags        = local.is_single_node ? ["terraform", "ubuntu", var.cluster_name, "control", "worker"] : ["terraform", "ubuntu", var.cluster_name, local.node_roles[count.index]]

  lifecycle {
    ignore_changes = [
      initialization[0].user_data_file_id,
      tags,
      description,
#      ipv4_addresses,
      mac_addresses,
      cores,
      memory,
      disk
    ]
  }

  agent {
    enabled = true
  }
  
  stop_on_destroy = true

  startup {
    order      = "3"
    up_delay   = "60"
    down_delay = "60"
  }

  cpu {
    cores = 4
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 8192
    floating  = 8192
  }

  disk {
    datastore_id = "local-lvm"
    import_from  = data.proxmox_virtual_environment_file.latest_ubuntu.id
    interface    = "scsi0"
    size         = "32"
  }

  disk {
    datastore_id = "local-lvm"
    interface    = "scsi1"
    size         = 100  # 100GB
    discard      = "on"  # Thin provisioning support
    ssd          = true  # If local-lvm is on SSD
  }

  initialization {
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    dns {
      domain = "tailandtraillabs.org"
    }

    user_data_file_id = proxmox_virtual_environment_file.cloud_config[count.index].id
  }

  network_device {
    bridge = "vmbr0"
    model  = "e1000"
  }

  operating_system {
    type = "l26"
  }

  serial_device {}
}

data "proxmox_virtual_environment_file" "latest_ubuntu" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "intrepid"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
}

output "ubuntu_vm_private_key" {
  value     = var.ssh_private_key
  sensitive = true
}

output "ubuntu_vm_public_key" {
  value = var.ssh_public_key
}

resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "intrepid"
  count        = local.total_nodes

  source_raw {
    file_name = "cloud-init-${var.cluster_name}-node${count.index}.yaml"
    data = <<-EOF
#cloud-config
hostname: ${var.cluster_name}-node${count.index}
ssh_deletekeys: false
packages:
  - qemu-guest-agent
  - nfs-common
  - avahi-daemon
  - net-tools

write_files:
  - path: /etc/node_role
    permissions: '0644'
    owner: root:root
    content: |
      ${local.node_roles[count.index]}
  - path: /root/.ssh/id_ed25519
    permissions: '0600'
    owner: root:root
    content: |
      ${indent(6, file(var.ssh_private_key))}
  - path: /root/.ssh/id_ed25519.pub
    permissions: '0644'
    owner: root:root
    content: |
      ${indent(6, file(var.ssh_public_key))}
  - path: /tmp/aws_credentials
    permissions: '0600'
    owner: root:root
    content: |
      ${indent(6, file(var.aws_credentials))}

users:
  - default
  - name: ubuntu
    passwd: $6$rounds=4096$IdKa.h27CQYKO1Aa$MwJ4Mtc7qXkQ8M3iWikcZZWqynde7.vNmjJO9rizdBSlFhEG7o0QxHY1cW6FSSNRawEdo6ZMHaSJjgzjJZuiQ/
    groups: sudo
    shell: /bin/bash
    ssh-authorized-keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMoNIBEOBhaObNW2hoUNX1/q8XCVKdrKmcCCjmvijRU1 bob@groth
    sudo: ALL=(ALL) NOPASSWD:ALL
  - name: root
    ssh-authorized-keys:
      - ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMoNIBEOBhaObNW2hoUNX1/q8XCVKdrKmcCCjmvijRU1 bob@groth    

runcmd:
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, qemu-guest-agent ]
  - [ systemctl, start, --no-block, qemu-guest-agent ]
  - [ systemctl, enable, avahi-daemon ]
  - [ systemctl, start, --no-block, avahi-daemon ]
EOF    
  }
}

data "aws_route53_zone" "main" {
  name = "tailandtraillabs.org."
}

resource "aws_route53_record" "cluster_nodes" {
  count   = local.total_nodes
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "${var.cluster_name}-node${count.index}.${var.domainname}"
  type    = "A"
  ttl     = 300
  records = [proxmox_virtual_environment_vm.cluster_vms[count.index].ipv4_addresses[1][0]]
}