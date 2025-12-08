#!/bin/bash
set -euo pipefail

# Enable debug mode if DEBUG env var is set
DEBUG="${DEBUG:-false}"
if [[ "$DEBUG" == "true" ]]; then
    set -x
    echo "[DEBUG MODE ENABLED]"
fi

# Bootstrap script for k3s cluster deployment
# Usage: ./bootstrap.sh [OPTIONS] [cluster-file]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_URL="git@github.com:travismontana/ttl-ops.git"

# Defaults
#DEFAULT_WORK_DIR=$(mktemp -d /tmp/bootstrap.XXXXXXX)
DEFAULT_WORK_DIR=/tmp/bootstrap
WORK_DIR="${WORK_DIR:-$DEFAULT_WORK_DIR}"
REPO_DIR=""
SECTION="all"
CLUSTER_FILE=""
DRY_RUN=false
TOFU_VARS=()
TOFU_VAR_FILES=()
DEFAULT_VAR_FILE="$HOME/.a/proxmoxapi.tfvars"

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    log "ERROR: $*" >&2
    exit 1
}

run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would execute: $*"
    else
        log "Executing: $*"
        "$@"
    fi
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS] [cluster-file]

ARGUMENTS:
  cluster-file         Path to cluster JSON file (relative to repo root)
                       Default: IaC/lab/clusters.json
                       Examples: 
                         clusters.json          -> \$REPO_DIR/clusters.json
                         IaC/prod/clusters.json -> \$REPO_DIR/IaC/prod/clusters.json
                         /tmp/test.json         -> /tmp/test.json (absolute path)

OPTIONS:
  --debug              Enable debug mode (set -x for bash tracing)
  --section SECTION    Run specific section: git|tofu|k3sinstall|argoinstall|appgroupinstall|destroy|all
                       Default: all
  --work-dir DIR       Working directory for all operations
                       Default: temporary directory (/tmp/bootstrap.XXXXXXX)
  --repo-dir DIR       Directory for git repository
                       Default: \$WORK_DIR/ttl-ops
  --tofu-var KEY=VALUE Pass variables to Tofu (can be used multiple times)
                       Example: --tofu-var token=USER@REALM!TOKENID=SECRET
  --tofu-var-file FILE Path to Tofu variables file
                       Default: $DEFAULT_VAR_FILE (if it exists)
                       Example: --tofu-var-file /path/to/vars.tfvars
  --dry-run            Show what would be done without executing
  -h, --help           Show this help message

SECTIONS:
  git                 Clone/update ttl-ops repository
  tofu                Infrastructure provisioning with Tofu
  k3sinstall          Install k3s on provisioned VMs
  argoinstall         Install ArgoCD (part of k3s playbook)
  appgroupinstall     Install core application groups
  destroy             Tear down infrastructure (runs tofu destroy)
  all                 Run all sections in order (git, tofu, k3sinstall, appgroupinstall)

EXAMPLES:
  # Use default clusters.json and default var file (~/.a/proxmoxapi.tfvars)
  $0

  # Enable debug mode
  DEBUG=true $0
  # or
  $0 --debug

  # Use specific cluster file from repo
  $0 IaC/prod/clusters.json

  # Use custom var file
  $0 --tofu-var-file /path/to/prod.tfvars clusters.json

  # Override with CLI variable
  $0 --tofu-var token="root@pam!mytoken=secret" clusters.json

  # Custom work directory
  $0 --work-dir /tmp/bootstrap

  # Dry run
  $0 --dry-run

  # Just clone/update repo
  $0 --section git

  # Destroy infrastructure
  $0 --section destroy
  
EOF
    exit 1
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --debug)
            DEBUG=true
            set -x
            shift
            ;;
        --section)
            SECTION="$2"
            shift 2
            ;;
        --work-dir)
            WORK_DIR="$2"
            shift 2
            ;;
        --repo-dir)
            REPO_DIR="$2"
            shift 2
            ;;
        --tofu-var)
            TOFU_VARS+=("-var=$2")
            shift 2
            ;;
        --tofu-var-file)
            TOFU_VAR_FILES+=("-var-file=$2")
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            CLUSTER_FILE="$1"
            shift
            ;;
    esac
done

# Auto-load default var file if it exists and no var files specified
if [[ ${#TOFU_VAR_FILES[@]} -eq 0 && -f "$DEFAULT_VAR_FILE" ]]; then
    log "Auto-loading default var file: $DEFAULT_VAR_FILE"
    TOFU_VAR_FILES+=("-var-file=$DEFAULT_VAR_FILE")
fi

# Set defaults if not provided
[[ -z "$REPO_DIR" ]] && REPO_DIR="${WORK_DIR}/ttl-ops"
TOFU_DIR="${REPO_DIR}/IaC/lab/code"
ANSIBLE_DIR="${REPO_DIR}/IaC/ansible"
TEMP_DIR="${WORK_DIR}/tmp"

# Validate section
case $SECTION in
    git|tofu|k3sinstall|argoinstall|appgroupinstall|destroy|all)
        ;;
    *)
        error "Invalid section: $SECTION. Must be one of: git, tofu, k3sinstall, argoinstall, appgroupinstall, destroy, all"
        ;;
esac

# Create work directory if it doesn't exist
if [[ "$DRY_RUN" == "false" && "$SECTION" != "destroy" ]]; then
    mkdir -p "$WORK_DIR"
    mkdir -p "$TEMP_DIR"
fi

check_ssh_agent() {
    log "Checking SSH agent..."
    
    # Check if ssh-agent is running
    if [[ -z "${SSH_AUTH_SOCK:-}" ]]; then
        log "SSH agent not running, starting..."
        eval "$(ssh-agent -s)"
    fi
    
    # Check if key is loaded
    if ! ssh-add -L &>/dev/null; then
        log "No SSH keys loaded, adding default key..."
        ssh-add "$HOME/.ssh/id_ed25519" || error "Failed to add SSH key to agent"
    fi
    
    log "SSH agent ready with keys:"
    ssh-add -L | awk '{print "  - " $NF}'
}

# Handle cluster file path
resolve_cluster_file() {
    # If git section only, we don't need cluster file yet
    if [[ "$SECTION" == "git" ]]; then
        return
    fi
    
    # If no cluster file specified, use default
    if [[ -z "$CLUSTER_FILE" ]]; then
        CLUSTER_FILE="${REPO_DIR}/IaC/lab/clusters.json"
        log "No cluster file specified, using default: $CLUSTER_FILE"
    else
        # If absolute path, use as-is
        if [[ "$CLUSTER_FILE" = /* ]]; then
            log "Using absolute cluster file path: $CLUSTER_FILE"
        else
            # Relative path, resolve from repo root
            CLUSTER_FILE="${REPO_DIR}/${CLUSTER_FILE}"
            log "Resolving cluster file relative to repo: $CLUSTER_FILE"
        fi
    fi
    
    # Validate cluster file exists
    [[ -f "$CLUSTER_FILE" ]] || error "Cluster file not found: $CLUSTER_FILE"
    
    # Get absolute path
    CLUSTER_FILE="$(cd "$(dirname "$CLUSTER_FILE")" && pwd)/$(basename "$CLUSTER_FILE")"
}

if [[ "$DRY_RUN" == "true" ]]; then
    log "=== DRY RUN MODE - No changes will be made ==="
fi

log "Configuration:"
log "  Work directory: $WORK_DIR"
log "  Repo directory: $REPO_DIR"
log "  Tofu directory: $TOFU_DIR"
log "  Ansible directory: $ANSIBLE_DIR"
log "  Temp directory: $TEMP_DIR"
log "  Section: $SECTION"
log "  Debug mode: $DEBUG"
[[ ${#TOFU_VARS[@]} -gt 0 ]] && log "  Tofu vars: ${#TOFU_VARS[@]} variable(s) provided"
[[ ${#TOFU_VAR_FILES[@]} -gt 0 ]] && log "  Tofu var files: ${#TOFU_VAR_FILES[@]} file(s) loaded"
log ""

# Section: git
run_git() {
    log "=== Section: Git Repository ==="
    
    if [[ -d "$REPO_DIR/.git" ]]; then
        log "Repository already exists at $REPO_DIR, pulling latest changes..."
        cd "$REPO_DIR"
        run_cmd git fetch origin
        run_cmd git pull origin main
    else
        log "Cloning repository from $REPO_URL to $REPO_DIR..."
        PARENT_DIR="$(dirname "$REPO_DIR")"
        mkdir -p "$PARENT_DIR"
        cd "$PARENT_DIR"
        run_cmd git clone "$REPO_URL" "$(basename "$REPO_DIR")"
        log "Repository cloned to $REPO_DIR"
    fi
    
    log "Git section complete"
}

# Section: tofu
run_tofu() {
    log "=== Section: Tofu Infrastructure Provisioning ==="
    
    # Resolve cluster file path
    check_ssh_agent
    resolve_cluster_file
    log "  Cluster file: $CLUSTER_FILE"
    
    # Validate repository exists
    [[ -d "$TOFU_DIR" ]] || error "Tofu directory not found: $TOFU_DIR (run --section git first)"
    
    # Validate AWS credentials
    [[ -f "$HOME/.aws/credentials" ]] || error "AWS credentials not found at ~/.aws/credentials"
    
    # Validate SSH keys
    [[ -f "$HOME/.ssh/id_ed25519" ]] || error "SSH private key not found"
    [[ -f "$HOME/.ssh/id_ed25519.pub" ]] || error "SSH public key not found"
    
    log "Initializing Tofu with S3 backend..."
    cd "$TOFU_DIR"
    run_cmd tofu init \
        -backend-config="bucket=ttl-ops-terraform-state" \
        -backend-config="key=lab/terraform.tfstate" \
        -backend-config="region=us-east-2"
    
    log "Planning infrastructure changes..."
    PLAN_FILE="${TEMP_DIR}/tfplan"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        run_cmd tofu plan -var="clusterfile=$CLUSTER_FILE" "${TOFU_VAR_FILES[@]}" "${TOFU_VARS[@]}"
    else
        run_cmd tofu plan \
            -var="clusterfile=$CLUSTER_FILE" \
            "${TOFU_VAR_FILES[@]}" \
            "${TOFU_VARS[@]}" \
            -out="$PLAN_FILE"
        
        log "Applying infrastructure..."
        run_cmd tofu apply "$PLAN_FILE"
        
        # Clean up plan file
        rm -f "$PLAN_FILE"
        
        log "Waiting 30s for VMs to stabilize..."
        sleep 30

        log "Flushing PiHole DNS cache..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null pi@172.16.2.23 "pihole restartdns reload" || log "Warning: Could not flush PiHole DNS"
        sleep 5
    fi
    
    log "Tofu section complete"
}

# Section: k3sinstall (includes argoinstall since it's in the same playbook)
run_k3sinstaller() {
    log "=== Section: K3s Installation ==="
    
    # Resolve cluster file path
    resolve_cluster_file
    log "  Cluster file: $CLUSTER_FILE"
    
    # Validate repository exists
    [[ -d "$ANSIBLE_DIR" ]] || error "Ansible directory not found: $ANSIBLE_DIR (run --section git first)"
    
    # Parse AWS credentials for Ansible
    AWS_ACCESS_KEY=$(awk -F'=' '/aws_access_key_id/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' ~/.aws/credentials | head -1)
    AWS_SECRET_KEY=$(awk -F'=' '/aws_secret_access_key/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' ~/.aws/credentials | head -1)
    
    [[ -n "$AWS_ACCESS_KEY" ]] || error "Could not parse AWS access key from credentials file"
    [[ -n "$AWS_SECRET_KEY" ]] || error "Could not parse AWS secret key from credentials file"
    
    log "Running Ansible playbook for k3s + ArgoCD..."
    cd "$ANSIBLE_DIR"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        run_cmd ansible-playbook k3s_main.yaml \
            -e "clusters_file=$CLUSTER_FILE" \
            -e "aws_access_key=REDACTED" \
            -e "aws_secret_key=REDACTED" \
            --check
    else
        run_cmd ansible-playbook k3s_main.yaml \
            -e "clusters_file=$CLUSTER_FILE" \
            -e "aws_access_key=$AWS_ACCESS_KEY" \
            -e "aws_secret_key=$AWS_SECRET_KEY"
    fi
    
    log "K3s installation complete"
}

# Section: k3sinstall (includes argoinstall since it's in the same playbook)
run_argoinstaller() {
    log "=== Section: Argo Installation ==="
    
    # Resolve cluster file path
    resolve_cluster_file
    log "  Cluster file: $CLUSTER_FILE"
    
    # Validate repository exists
    [[ -d "$ANSIBLE_DIR" ]] || error "Ansible directory not found: $ANSIBLE_DIR (run --section git first)"
    
    # Parse AWS credentials for Ansible
    AWS_ACCESS_KEY=$(awk -F'=' '/aws_access_key_id/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' ~/.aws/credentials | head -1)
    AWS_SECRET_KEY=$(awk -F'=' '/aws_secret_access_key/ {gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2}' ~/.aws/credentials | head -1)
    
    [[ -n "$AWS_ACCESS_KEY" ]] || error "Could not parse AWS access key from credentials file"
    [[ -n "$AWS_SECRET_KEY" ]] || error "Could not parse AWS secret key from credentials file"
    
    log "Running Ansible playbook for ArgoCD..."
    cd "$ANSIBLE_DIR"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        run_cmd ansible-playbook k3s_initial_appload.yaml \
            -e "clusters_file=$CLUSTER_FILE" \
            -e "aws_access_key=REDACTED" \
            -e "aws_secret_key=REDACTED" \
            --check
    else
        run_cmd ansible-playbook k3s_initial_appload.yaml \
            -e "clusters_file=$CLUSTER_FILE" \
            -e "aws_access_key=$AWS_ACCESS_KEY" \
            -e "aws_secret_key=$AWS_SECRET_KEY"
    fi
    
    log "K3s installation complete"
}

# Section: argoinstall (separate entry point, but runs k3sinstall since they're together)
run_k3sinstall() {
    log "=== Section: K3s Installation ==="
    log "Note: K3s is installed as part of k3s playbook"
    run_k3sinstaller
}

# Section: argoinstall (separate entry point, but runs k3sinstall since they're together)
run_argoinstall() {
    log "=== Section: ArgoCD Installation ==="
    log "Note: ArgoCD is installed as part of k3s playbook"
    run_argoinstaller
}

# Section: appgroupinstall
run_appgroupinstall() {
    log "=== Section: Application Group Installation ==="
    
    # Resolve cluster file path
    resolve_cluster_file
    log "  Cluster file: $CLUSTER_FILE"
    
    # Get first cluster info for kubectl access
    FIRST_CLUSTER=$(jq -r '.cluster[0].name' "$CLUSTER_FILE")
    DOMAIN=$(jq -r '.domainname' "$CLUSTER_FILE")
    FIRST_NODE="${FIRST_CLUSTER}-node0.${DOMAIN}"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log "[DRY-RUN] Would wait for ArgoCD on $FIRST_NODE"
        log "[DRY-RUN] Would verify ApplicationSets"
    else
        log "Waiting for ArgoCD to be ready on $FIRST_NODE..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$FIRST_NODE" \
            'kubectl wait --for=condition=available --timeout=300s deployment/argocd-server -n argocd' \
            || log "Warning: ArgoCD may not be ready yet"
        
        log "Verifying core ApplicationSet..."
        ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@"$FIRST_NODE" \
            'kubectl get applicationset -n argocd' \
            || error "Could not verify ApplicationSets"
        
        log "Application groups are managed by ArgoCD ApplicationSets"
        log "Check status: ssh ubuntu@$FIRST_NODE 'kubectl get applications -n argocd'"
    fi
    
    log "Application group installation complete"
}

# Section: destroy
run_destroy() {
    log "=== Section: Destroy Infrastructure ==="
    
    # Resolve cluster file path
    resolve_cluster_file
    log "  Cluster file: $CLUSTER_FILE"
    run_git  # Ensure repo is available for tofu destroy
    # Validate repository exists
    [[ -d "$TOFU_DIR" ]] || error "Tofu directory not found: $TOFU_DIR (run --section git first)"

    # Validate AWS credentials
    [[ -f "$HOME/.aws/credentials" ]] || error "AWS credentials not found at ~/.aws/credentials"
    
    log "Initializing Tofu with S3 backend..."
    cd "$TOFU_DIR"
    run_cmd tofu init \
        -backend-config="bucket=ttl-ops-terraform-state" \
        -backend-config="key=lab/terraform.tfstate" \
        -backend-config="region=us-east-2"
    
    log "Planning infrastructure destruction..."
    if [[ "$DRY_RUN" == "true" ]]; then
        run_cmd tofu plan -destroy -var="clusterfile=$CLUSTER_FILE" "${TOFU_VAR_FILES[@]}" "${TOFU_VARS[@]}"
    else
        log "WARNING: This will destroy all infrastructure defined in $CLUSTER_FILE"
        read -p "Are you sure? Type 'yes' to continue: " -r
        if [[ $REPLY == "yes" ]]; then
            run_cmd tofu destroy -var="clusterfile=$CLUSTER_FILE" "${TOFU_VAR_FILES[@]}" "${TOFU_VARS[@]}" -auto-approve
            log "Infrastructure destroyed"
        else
            log "Destroy cancelled"
            exit 0
        fi
    fi
    
    log "Destroy section complete"
}

# Section: all
run_all() {
    log "=== Running all sections ==="
    run_git
    resolve_cluster_file  # Resolve here so it's available for all subsequent sections
    log "  Cluster file: $CLUSTER_FILE"
    run_tofu
    run_k3sinstall
    run_argoinstall
    run_appgroupinstall
}

# Execute requested section
case $SECTION in
    git)
        run_git
        ;;
    tofu)
        run_tofu
        ;;
    k3sinstall)
        run_k3sinstall
        ;;
    argoinstall)
        run_argoinstall
        ;;
    appgroupinstall)
        run_appgroupinstall
        ;;
    destroy)
        run_destroy
        ;;
    all)
        run_all
        ;;
esac

# Cleanup temp directory if empty
if [[ "$DRY_RUN" == "false" && -d "$TEMP_DIR" ]]; then
    rmdir "$TEMP_DIR" 2>/dev/null || true
fi

log "=== Bootstrap Complete ==="

if [[ "$SECTION" != "destroy" && "$SECTION" != "git" && "$DRY_RUN" == "false" ]]; then
    # Resolve cluster file if not already done
    [[ -z "$CLUSTER_FILE" || ! -f "$CLUSTER_FILE" ]] && resolve_cluster_file
    
    log "Access clusters:"
    jq -r '.cluster[] | "  - \(.name)-node0.'$(jq -r '.domainname' "$CLUSTER_FILE")'"' "$CLUSTER_FILE"
    log ""
    
    FIRST_CLUSTER=$(jq -r '.cluster[0].name' "$CLUSTER_FILE")
    DOMAIN=$(jq -r '.domainname' "$CLUSTER_FILE")
    
    log "Get ArgoCD admin password:"
    log "  ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null ubuntu@${FIRST_CLUSTER}-node0.${DOMAIN} 'kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath={.data.password} | base64 -d'"
fi

# Cleanup temp work directory on exit
if [[ "$WORK_DIR" == /tmp/bootstrap.* ]]; then
    trap 'rm -rf "$WORK_DIR"' EXIT
fi