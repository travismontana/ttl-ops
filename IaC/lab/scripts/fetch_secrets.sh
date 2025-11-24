#!/bin/bash
set -e

AWS_REGION="us-east-2"

echo "Fetching Proxmox secrets from AWS Secrets Manager..."

# Fetch secrets
export TF_VAR_proxmox_api_url=$(aws secretsmanager get-secret-value \
  --region $AWS_REGION \
  --secret-id proxmox/api-url \
  --query SecretString \
  --output text)

export TF_VAR_proxmox_token_id=$(aws secretsmanager get-secret-value \
  --region $AWS_REGION \
  --secret-id proxmox/token-id \
  --query SecretString \
  --output text)

export TF_VAR_proxmox_token_secret=$(aws secretsmanager get-secret-value \
  --region $AWS_REGION \
  --secret-id proxmox/token-secret \
  --query SecretString \
  --output text)

echo "Secrets loaded successfully!"