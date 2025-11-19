Sources
k8s logs
otel 4317 grpc
otel 4318 http
syslog
netflow

Transform (converts to vector remap)

Sinks
logs -> signoz
otel -> signoz
netflow -> ?

signoz:
signoz-otel-collector.signoz.svc:4317
signoz-otel-collector.signoz.svc:4318
