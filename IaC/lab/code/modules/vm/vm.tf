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
    # uncomment and specify the datastore for cloud-init disk if default `local-lvm` is not available
    # datastore_id = "local-lvm"

    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }
    dns {
      domain = "abode.tailandtraillabs.org"
    }

    #user_account {
    #  keys     = [trimspace(local.ssh_public_key)]
    #  password = local.ubuntu_vm_password
    #  username = "ubuntu"
    #}

    user_data_file_id = proxmox_virtual_environment_file.cloud_config[count.index].id
  }

  network_device {
    bridge = "vmbr0"
    model = "e1000"
  }

  operating_system {
    type = "l26"
  }

  #tpm_state {
  #  version = "v2.0"
  #}

  serial_device {}

  #virtiofs {
  #  mapping = "data_share"
  #  cache = "always"
  #  direct_io = true
  #}
}

#resource "proxmox_virtual_environment_download_file" "latest_ubuntu" {
data "proxmox_virtual_environment_file" "latest_ubuntu" {
  content_type = "import"
  datastore_id = "local"
  node_name    = "intrepid"
  file_name    = "noble-server-cloudimg-amd64.qcow2"
  #url          = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  #file_name    = "noble-server-cloudimg-amd64.qcow2"
  #source_file {
  #  path = "noble-server-cloudimg-amd64.img"
  #  file_name    = "noble-server-cloudimg-amd64.qcow2"
  #}
}

# Remove the tls_private_key resource entirely, replace with locals
locals {
  ssh_public_key  = file("/home/bob/.ssh/id_ed25519.pub")
  ssh_private_key = file("/home/bob/.ssh/id_ed25519")
  ubuntu_vm_password = "n2260m"
  aws_credentials = file("/home/bob/.a/aws_key")
}

output "ubuntu_vm_password" {
  value     = local.ubuntu_vm_password
  sensitive = true
}

output "ubuntu_vm_private_key" {
  value     = local.ssh_private_key
  sensitive = true
}

output "ubuntu_vm_public_key" {
  value = local.ssh_public_key
}

resource "proxmox_virtual_environment_file" "cloud_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = "intrepid"
  count        = var.cluster_numnodes
  #file_name    = "cloud-init-${local.vm_names[count.index]}.yaml"
  #file_name = "cloud-init-${count.index}.yaml"
  #file_mode = "0644"

  # 

  source_raw {
    file_name = "cloud-init-${var.cluster_name}-node${count.index}.yaml"
    #ile_name    = "cloud-init-${local.vm_names[count.index]}.yaml"
    data = <<-EOF
#cloud-config
hostname: ${var.cluster_name}-node${count.index}
ssh_deletekeys: false
#chpasswd:
#  list: |
#    ubuntu:n2260m
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
      ${indent(6, file("/home/bob/.ssh/id_ed25519"))}
  - path: /root/.ssh/id_ed25519.pub
    permissions: '0644'
    owner: root:root
    content: |
      ${indent(6, file("/home/bob/.ssh/id_ed25519.pub"))}
  - path: /tmp/aws_credentials
    permissions: '0600'
    owner: root:root
    content: |
      ${indent(6, local.aws_credentials)}
  - path: /tmp/runinstall.sh
    permissions: '0755'
    owner: root:root
    content: |
      #!/bin/bash
      exec >> /tmp/k3s_install.log 2>&1
      set -e
      
      log() {
        echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a /tmp/k3s_install.log | tee /dev/console
      }
      
      log "Starting k3s installation on $(hostname)"
      
      export INSTALL_K3S_VERSION="v1.34.1+k3s1"
      export K3S_TOKEN="N2260mN2260m"
      
      K3SVARS="--node-name ${var.cluster_name}-node${count.index} ${local.appgroup_labels} --node-label clustername=${var.cluster_name}"
      
      if echo "$(hostname)" | grep -q "node0"; then
        log "Installing as SERVER (first node)"
        export INSTALL_K3S_EXEC="server --cluster-init --tls-san ${var.cluster_name}-node0.abode.tailandtraillabs.org $K3SVARS"
      else
        sleep 60
        log "Installing as AGENT"
        export K3S_URL="https://${var.cluster_name}-node0.abode.tailandtraillabs.org:6443"
        export INSTALL_K3S_EXEC="agent $K3SVARS"
      fi
      
      log "Downloading k3s installer..."
      curl -sfL https://get.k3s.io -o /tmp/k3s_installer.sh
      
      log "Running k3s installer with: "
      log "INSTALL_K3S_EXEC=$INSTALL_K3S_EXEC"
      log "K3S_URL=$K3S_URL"
      log "INSTALL_K3S_VERSION=$INSTALL_K3S_VERSION"
      sh /tmp/k3s_installer.sh >> /tmp/k3s_install.log 2>&1      
      log "k3s installation complete"
      if echo "$(hostname)" | grep -q "node0"; then
        mkdir /danas
        mount danas.hangar.bpfx.org:/volume1/dataz /danas
        sed 's/127.0.0.1/${var.cluster_name}-node0.abode.tailandtraillabs.org/g' /etc/rancher/k3s/k3s.yaml > /danas/kube/k3s-${var.cluster_name}-node0-config.yaml
        sync
        chmod 644 /danas/kube/k3s-${var.cluster_name}-node0-config.yaml
        sync
        log "Copied k3s config to /danas/kube/"

        sleep 1
        log "Waiting for k3s to be ready..."
        until kubectl get nodes &> /dev/null; do
          sleep 5
        done    

        log "Creating external-dns namespace..."
        kubectl create namespace external-dns || true

        log "Creating AWS credentials secret..."
        source /tmp/aws_credentials
        kubectl create secret generic route53-credentials \
          -n external-dns \
          --from-literal=aws-access-key-id="$AWS_ACCESS_KEY_ID" \
          --from-literal=aws-secret-access-key="$AWS_SECRET_ACCESS_KEY" \
          --dry-run=client -o yaml | kubectl apply -f -

        log "Creating argocd namespace..."
        kubectl create namespace argocd || true
      
        log "Installing ArgoCD..."
        kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
        
        log "Waiting for ArgoCD to be ready..."
        kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd

        log "Creating ArgoCD in-cluster secret..."
        kubectl create secret generic cluster-in-cluster \
          -n argocd \
          --from-literal=name=in-cluster \
          --from-literal=server=https://kubernetes.default.svc \
          --dry-run=client -o yaml | kubectl apply -f -

        kubectl label secret cluster-in-cluster \
          -n argocd \
          argocd.argoproj.io/secret-type=cluster \
          cluster-name="${var.cluster_name}" \
          --overwrite
          
        log "Install the core app"
        kubectl apply -f https://raw.githubusercontent.com/travismontana/ttl-ops/refs/heads/main/appgroups/core/core.argoappset.yaml

        umount /danas
        sync
        sync
      fi

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
  - [ wget https://get.k3s.io, -O, /tmp/k3s.sh ]
  - [ bash, /tmp/runinstall.sh  ]
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
  #name    = "${local.vm_names[count.index]}.${var.cluster_name}.abode.abode.tailandtraillabs.org"
  name    = "${var.cluster_name}-node${count.index}.abode.tailandtraillabs.org"
  type    = "A"
  ttl     = 300
  records = [proxmox_virtual_environment_vm.cluster_vms[count.index].ipv4_addresses[1][0]]  # [1][0] gets first IP of first interface (skipping loopback)
}

# Optionally create a wildcard or cluster-level record pointing to node0
#resource "aws_route53_record" "cluster_api" {
#  zone_id = data.aws_route53_zone.main.zone_id
#  name    = "${var.cluster_name}.abode.tailandtraillabs.org"
#  type    = "A"
#  ttl     = 300
#  records = [proxmox_virtual_environment_vm.cluster_vms[0].ipv4_addresses[1][0]]
#}