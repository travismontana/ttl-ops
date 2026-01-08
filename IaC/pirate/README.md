tofu init -var-file ~/.a/proxmoxapi.tfvars -var 'clusterfile=clusters.json'
tofu plan -var-file ~/.a/proxmoxapi.tfvars -var 'clusterfile=clusters.json'
tofu apply -var-file ~/.a/proxmoxapi.tfvars -var 'clusterfile=clusters.json'

curl -sfL https://get.k3s.io | sh -s - --node-label clustername=pirate --node-label domainname=pirate.tailandtaillabs.org --node-name pirate-node0 --disable=traefik --tls-san pirate-node0.pirate.tailandtraillabs.org

