.PHONY: help build apply delete validate test-prod test-dev

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build all manifests
	@echo "Building production manifests..."
	@kubectl kustomize overlays/production > /tmp/prod-dashboards.yaml
	@echo "Building development manifests..."
	@kubectl kustomize overlays/development > /tmp/dev-dashboards.yaml
	@echo "✓ Manifests built in /tmp/"

validate: ## Validate all Kubernetes manifests
	@echo "Validating kustomizations..."
	@kubectl kustomize base > /dev/null && echo "✓ base valid"
	@kubectl kustomize overlays/production > /dev/null && echo "✓ production valid"
	@kubectl kustomize overlays/development > /dev/null && echo "✓ development valid"
	@echo "Validating ArgoCD manifests..."
	@kubectl apply --dry-run=client -f argocd/ > /dev/null && echo "✓ ArgoCD manifests valid"

apply-prod: ## Apply production dashboards directly
	@kubectl apply -k overlays/production
	@echo "✓ Production dashboards applied"

apply-dev: ## Apply development dashboards directly
	@kubectl apply -k overlays/development
	@echo "✓ Development dashboards applied"

apply-argocd-app: ## Deploy ArgoCD Application (single cluster)
	@kubectl apply -f argocd/dashboard-app.yaml
	@echo "✓ ArgoCD Application created"

apply-argocd-appset: ## Deploy ArgoCD ApplicationSet (multi-cluster)
	@kubectl apply -f argocd/applicationset.yaml
	@echo "✓ ArgoCD ApplicationSet created"

delete-prod: ## Delete production dashboards
	@kubectl delete -k overlays/production
	@echo "✓ Production dashboards deleted"

delete-dev: ## Delete development dashboards
	@kubectl delete -k overlays/development
	@echo "✓ Development dashboards deleted"

test-prod: ## Test build production manifests
	@kubectl kustomize overlays/production

test-dev: ## Test build development manifests
	@kubectl kustomize overlays/development

list-dashboards: ## List all dashboard ConfigMaps
	@kubectl get configmaps -n monitoring -l grafana_dashboard=1

watch-sync: ## Watch ArgoCD sync status
	@watch -n 2 'kubectl get applications -n argocd | grep dashboard'
