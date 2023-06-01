# VESSL Agent Helm Chart

## Release Notes

### v0.1.42 (2023-06-01)
- Do not drop `kube_pod_labels` on kube-state-metrics-servicemonitor

### v0.1.41 (2023-05-31)
- Fix ServiceMonitor using non-string value for `matchLabels` field

### v0.1.40 (2023-05-31)
- Bump up cluster-agent to 0.6.14

### v0.1.39 (2023-04-26)
- Upgrade apiVersion of PodDisruptionBudget from policy/v1beta to policy/v1

### v0.1.38 (2023-04-04)
- User can use `simpleRegistry` option instead of `harbor` option in some specific case.

### v0.1.37 (2023-03-31)
- Introduces `prometheus.standalone` value: remote-write is now an option.

### v0.1.34 (2023-02-24)
- Set `enabled` flag for local-path-provisioner, dcgm-exporter, kube-state-metrics and node-exporter

### v0.1.33 (2023-02-24)
- Bump up cluster-agent to 0.6.3

### v0.1.32 (2023-02-16)
- Add enabled flags to subcharts.

### v0.1.31 (2023-01-05)
- Bump up cluster-agent to 0.6.2

### v0.1.30 (2023-01-05)
- Suppress nv-hostengine.log of dcgm-exporter

### v0.1.29 (2022-12-21)
- Bump up cluster-agent to 0.6.0
- Set DCGM_EXPORTER_KUBERNETES_GPU_ID_TYPE only when non-empty value is given from chart
- Update ClusterRole of kube-state-metrics

### v0.1.28 (2022-12-09)
- Allow tolerations on local path provisioner

### v0.1.27 (2022-11-25)
- Updates version of dependency packages
  - nvidia-device-plugin to v0.12.3
  - node-feature-discovery to v0.11.0
  - gpu-feature-discovery to v0.6.2
  - local-path-provisioner to v0.0.22
  - dcgm-exporter to 2.4.7-2.6.11-ubuntu20.04
  - kube-state-metrics to v2.6.0
  - node-exporter to v1.4.0
- Adds prometheus-operator as a dependency. The prometheus is configured to perform remote-write to VESSL service by default. If you have your own prometheus-operator, you may prevent installing another operator by setting `kube-prometheus-stack.prometheusOperator.enabled = false`.

### v0.1.20 (2022-08-25)

- Adds optional agent.clusterName parameter to configure created cluster name.

### v0.1.18 (2022-04-29)

- Adds [harbor](https://goharbor.io) components for internal OCI proxy.
- It automatically sets up a quay.io proxy.
