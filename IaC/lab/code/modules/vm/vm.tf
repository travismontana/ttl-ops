variable "cluster_name" {
  description = "Name of the Proxmox cluster"
  type        = string
}

variable "cluster_numnodes" {
  description = "Number of nodes in the Proxmox cluster"
  type        = number
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

locals {
  # Convert appgroups to k3s label format: --node-label appgroup.pirate=true
  appgroup_labels = join(" ", [
    for group in var.appgroups : 
      join(" ", [
        for key, value in group :
          "--node-label appgroup.${key}=${value}"
      ])
  ])
}


resource "proxmox_virtual_environment_vm" "cluster_vms" {
  count       = var.cluster_numnodes
  name        = "${var.cluster_name}-node${count.index}" 
  node_name   = var.proxmox_node
  description = "Managed by Terraform"
  tags        = ["terraform", "ubuntu" ,var.cluster_name]

  lifecycle {
    ignore_changes = [
      # Ignore changes to these attributes - they can drift without triggering recreate
      initialization[0].user_data_file_id,  # Cloud-init changes won't recreate VM
      tags,                                  # Tag changes won't recreate
      description,                           # Description changes won't recreate
      ipv4_addresses,                        # IP changes from DHCP won't trigger anything
      mac_addresses,                         # MAC address drift
    ]
  }

  agent {
    # read 'Qemu guest agent' section, change to true only when ready
    enabled = true
  }
  # if agent is not enabled, the VM may not be able to shutdown properly, and may need to be forced off
  stop_on_destroy = true

  startup {
    order      = "3"
    up_delay   = "60"
    down_delay = "60"
  }

  cpu {
    cores = 2
    type  = "x86-64-v2-AES" # recommended for modern CPUs
  }

  memory {
    dedicated = 2048
    floating  = 2048 # set equal to dedicated to enable ballooning
  }

  disk {
    datastore_id = "local-lvm"
    import_from  = data.proxmox_virtual_environment_file.latest_ubuntu.id
    interface    = "scsi0"
    size         = "32"
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
    model = "e1000"
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

}

#resource "proxmox_virtual_environment_download_file" "latest_ubuntu" {
data "proxmox_virtual_environment_file" "latest_ubuntu" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "intrepid"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
}

# Remove the tls_private_key resource entirely, replace with locals
variable ssh_public_key {
  description = "Path to SSH public key"
  type        = string
  default     = "/home/bob/.ssh/id_ed25519.pub"
}

variable ssh_private_key {
  description = "Path to SSH private key"
  type        = string
  default     = "/home/bob/.ssh/id_ed25519"
}

variable aws_credentials {
  description = "Path to AWS credentials file"
  type        = string
  default     = "/home/bob/.aws/credentials"
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
  count        = var.cluster_numnodes

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
  - path: /root/.ssh/id_ed25519
    permissions: '0600'
    owner: root:root
    content: |
      ${indent(6, var.ssh_private_key)}
  - path: /root/.ssh/id_ed25519.pub
    permissions: '0644'
    owner: root:root
    content: |
      ${indent(6, var.ssh_public_key)}
  - path: /tmp/aws_credentials
    permissions: '0600'
    owner: root:root
    content: |
      ${indent(6, var.aws_credentials)}

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

# Get your Route53 hosted zone
data "aws_route53_zone" "main" {
  name = "tailandtraillabs.org."
}

# Create DNS records for each VM
resource "aws_route53_record" "cluster_nodes" {
  count   = var.cluster_numnodes
  zone_id = data.aws_route53_zone.main.zone_id
  #name    = "${local.vm_names[count.index]}.${var.cluster_name}.tailandtraillabs.org"
  name    = "${var.cluster_name}-node${count.index}.tailandtraillabs.org"
  type    = "A"
  ttl     = 300
  records = [proxmox_virtual_environment_vm.cluster_vms[count.index].ipv4_addresses[1][0]]  # [1][0] gets first IP of first interface (skipping loopback)
}