# Observability Dashboards GitOps

Multi-cluster Grafana dashboards implementing USE Method, RED Method, and Google's Four Golden Signals.

## Structure

```
observability-dashboards/
├── base/                           # Base dashboard definitions
│   ├── kustomization.yaml
│   └── dashboards/                 # Dashboard JSON files
├── overlays/                       # Environment-specific overrides
│   ├── production/
│   └── development/
└── argocd/                         # ArgoCD application definitions
    ├── applicationset.yaml         # Multi-cluster deployment
    └── dashboard-app.yaml          # Single cluster deployment
```

## Dashboards Included

1. **USE Method - Node Resources** (`use-nodes`)
   - CPU: Utilization, Saturation (load), Context switches
   - Memory: Utilization, Saturation (page faults, swap)
   - Disk: Utilization, Saturation (queue time), Errors
   - Network: Utilization (bandwidth), Saturation (drops), Errors

2. **USE Method - Kubernetes Resources** (`use-k8s`)
   - Pod CPU: Usage, Throttling
   - Pod Memory: Working set, OOM indicators
   - Storage: PVC utilization, Inode usage
   - Network: Pod bandwidth

3. **RED Method - Service Template** (`red-service`)
   - Rate: Requests per second
   - Errors: Error percentage
   - Duration: Latency percentiles (p50, p95, p99)
   - Apdex score, Status code breakdown

4. **Golden Signals Overview** (`golden-signals`)
   - Latency: p99 across services
   - Traffic: Request rates
   - Errors: Error percentages
   - Saturation: CPU usage
   - Service summary table

5. **Fleet Overview** (`fleet-overview`)
   - Multi-cluster status table
   - Cross-cluster resource trends
   - Capacity planning heatmaps

## Prerequisites

- Grafana with sidecar enabled or Grafana Operator
- Prometheus with:
  - node_exporter
  - kube-state-metrics
  - Application instrumentation for RED metrics
- Consistent labeling: `cluster`, `namespace`, `instance`

## Deployment

### Option 1: ArgoCD ApplicationSet (Multi-cluster)

Deploy to all clusters with `monitoring: "enabled"` label:

```bash
kubectl apply -f argocd/applicationset.yaml
```

### Option 2: Single Cluster

```bash
kubectl apply -k overlays/production/
```

### Option 3: Local Development

```bash
kubectl apply -k overlays/development/
```

## Grafana Configuration

Ensure your Grafana Helm values include:

```yaml
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    labelValue: "1"
    folder: /tmp/dashboards
    folderAnnotation: grafana_folder
    searchNamespace: monitoring
    provider:
      foldersFromFilesStructure: true
```

## Customization

### Adjust Thresholds

Edit the dashboard JSON files in `base/dashboards/` to tune thresholds for your SLOs.

### Metric Label Names

If your Prometheus uses different label names:

1. Update queries in dashboard JSON files
2. Focus on: `cluster`, `namespace`, `instance`, `nodename`

### RED Method Prerequisites

The RED Method dashboard requires HTTP instrumentation with these metrics:

- `http_requests_total{method, endpoint, status}`
- `http_request_duration_seconds_bucket{method, endpoint, le}`

If not available, use ingress controller metrics as proxy or instrument your applications.

## Folder Organization

Dashboards are auto-organized into folders via the `grafana_folder` annotation:

- USE Method → "USE Method"
- RED Method → "RED Method"
- Golden Signals → "Golden Signals"
- Fleet → "Fleet"

## Maintenance

### Update a Dashboard

1. Edit JSON in `base/dashboards/`
2. Commit and push
3. ArgoCD auto-syncs (if enabled)

### Add a Dashboard

1. Create JSON in `base/dashboards/`
2. Add to `base/kustomization.yaml` configMapGenerator
3. Set appropriate labels and annotations

## Troubleshooting

**Dashboard not appearing:**
- Check ConfigMap labels: `kubectl get cm -n monitoring -l grafana_dashboard=1`
- Check Grafana logs for sidecar errors
- Verify namespace matches sidecar `searchNamespace`

**No data in panels:**
- Verify Prometheus datasource is configured
- Check metric label names match your environment
- Use Grafana's Explore to test queries

**ArgoCD sync issues:**
- Check cluster labels: `kubectl get secret -n argocd -l argocd.argoproj.io/secret-type=cluster -o yaml`
- Verify clusters have `monitoring: "enabled"` label

## References

- [USE Method - Brendan Gregg](http://www.brendangregg.com/usemethod.html)
- [RED Method - Tom Wilkie](https://www.weave.works/blog/the-red-method-key-metrics-for-microservices-architecture/)
- [Four Golden Signals - Google SRE](https://sre.google/sre-book/monitoring-distributed-systems/)

## License

MIT - Customize as needed for your environment.
