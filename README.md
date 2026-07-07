# wad-demo

Infrastructure-as-code for the **We Are Developers** demo: provisions a GKE
Standard cluster, installs the Dash0 operator + the OpenTelemetry demo via
Helm, and ships all telemetry to the `wad-demo` Dash0 dataset.

```
GitHub Actions ──▶ Terraform ──▶ GKE Standard ───┬─▶ Dash0 operator (dash0-system)
   (WIF auth)        (GCS state)                  │     └─ OTel collectors ─▶ Dash0 (wad-demo)
                                                  └─▶ OTel demo workloads (otel-demo)
                                                        └─ SDK OTLP ─▶ operator's collector
```

## Layout

```
deployment/
  helm/
    values.yaml          # OTel demo values: bundled collector + UI backends disabled,
                         # apps' OTEL_COLLECTOR_NAME redirected to operator's collector
  terraform/
    versions.tf
    backend.tf           # GCS backend, bucket configured at init
    providers.tf         # google, kubernetes, helm providers
    variables.tf
    main.tf              # GKE Standard + node pool + dash0-system + Dash0 operator + Dash0Monitoring + otel-demo
    outputs.tf
    bootstrap.sh         # One-time GCS bucket + WIF + SA setup; idempotent
.github/workflows/
  terraform.yml          # plan on PR, apply on push to main
```

## Prerequisites

- GCP project with billing enabled (default in this repo: `dash0-devrel`).
- A Dash0 ingest token with write access to the `wad-demo` dataset.
- Local CLIs for hands-on use (not required for the CI path):
  `gcloud`, `terraform >= 1.6`, `kubectl`, `helm`.

## One-time bootstrap

Creates the Terraform state bucket, the Terraform service account, and the
Workload Identity Federation binding for this GitHub repository:

```sh
PROJECT_ID=we-are-developers-501011 \
REGION=europe-west1 \
GITHUB_REPO=dash0-demo/wad-demo \
  ./deployment/terraform/bootstrap.sh
```

The script is idempotent. It prints, at the end, the values to register in the
GitHub repo under **Settings → Secrets and variables → Actions**:

| Kind     | Name                  | Value (example, for the `we-are-developers-501011` project)                                              |
| -------- | --------------------- | -------------------------------------------------------------------------------------------------------- |
| Variable | `GCP_PROJECT_ID`      | `we-are-developers-501011`                                                                               |
| Variable | `GCP_REGION`          | `europe-west1`                                                                                           |
| Variable | `TF_STATE_BUCKET`     | `we-are-developers-501011-tf-state-wad-demo`                                                             |
| Variable | `WIF_PROVIDER`        | `projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/github-actions/providers/wad-demo`     |
| Variable | `WIF_SERVICE_ACCOUNT` | `wad-demo-tf@we-are-developers-501011.iam.gserviceaccount.com`                                           |
| Secret   | `DASH0_AUTH_TOKEN`    | ingest token for the `wad-demo` dataset (used by the operator's collectors)                              |
| Secret   | `DASH0_API_TOKEN`     | management API token for the `wad-demo` tenant (used by the dash0 Terraform provider)                    |
| Secret   | `DASH0_WEB_SDK_AUTH_TOKEN` | **separate** ingest-only token, scoped to `wad-demo` — becomes public in the frontend HTML          |

## Deploy

Push to `main` (or merge a PR). The `terraform` workflow runs
`init → fmt → validate → plan → apply`; on pull requests it posts the plan as a
comment and skips apply.

To run locally instead:

```sh
cd deployment/terraform
terraform init \
  -backend-config="bucket=dash0-devrel-tf-state-wad-demo" \
  -backend-config="prefix=wad-demo/gke"
TF_VAR_dash0_auth_token=<ingest-token> \
TF_VAR_dash0_api_token=<api-token> \
TF_VAR_dash0_web_sdk_auth_token=<web-sdk-ingest-token> \
  terraform apply
```

After apply, point `kubectl` at the cluster with the command printed in the
Terraform outputs (`get_credentials_command`). The `frontend_public_url`
output is the demo's public HTTP endpoint (LoadBalancer with a reserved
regional external IP) — open it in a browser to exercise the Dash0 Web SDK,
or point Dash0 synthetics at it.

## Tear down

```sh
cd deployment/terraform
TF_VAR_dash0_auth_token=<ingest-token> \
TF_VAR_dash0_api_token=<api-token> \
TF_VAR_dash0_web_sdk_auth_token=<web-sdk-ingest-token> \
  terraform destroy
```

`helm_release` is removed first (along with the demo workloads), then the
namespace, then the GKE cluster.

Or, from GitHub Actions: run the **terraform destroy** workflow via
`workflow_dispatch`, typing `DESTROY` in the confirmation input. Same
teardown, no local tooling required. Handy when a change would otherwise
force-replace the cluster (e.g. Autopilot ↔ Standard migrations) —
run destroy first, then merge the change so the next apply builds
fresh.

## Configuration knobs

All in `deployment/terraform/variables.tf`:

| Variable                       | Default                                | Purpose                                                      |
| ------------------------------ | -------------------------------------- | ------------------------------------------------------------ |
| `project_id`                   | _required_                             | GCP project                                                  |
| `region`                       | `europe-west1`                         | Cluster region                                               |
| `cluster_name`                 | `wad-demo`                             | GKE cluster name                                             |
| `release_channel`              | `REGULAR`                              | GKE release channel                                          |
| `gke_machine_type`             | `e2-standard-4`                        | Machine type for the primary node pool                       |
| `gke_node_count`               | `1`                                    | Nodes per zone (regional cluster; total = value × zones)     |
| `otel_demo_chart_version`      | `0.40.9`                               | OTel demo chart version                                      |
| `dash0_operator_chart_version` | _empty (latest)_                       | Pin a specific operator chart version if needed              |
| `dash0_auth_token`             | _required, sensitive_                  | Ingest token used by the operator (env: `TF_VAR_dash0_auth_token`) |
| `dash0_api_token`              | _required, sensitive_                  | Management API token used by the dash0 provider (env: `TF_VAR_dash0_api_token`) |
| `dash0_dataset`                | `wad-demo`                             | Dash0 dataset technical id                                   |
| `dash0_otlp_grpc_endpoint`     | `ingress.eu-west-1.aws.dash0.com:4317` | OTLP/gRPC endpoint used by the operator's collectors         |
| `dash0_otlp_http_endpoint`     | `https://ingress.eu-west-1.aws.dash0.com` | OTLP/HTTP endpoint used by the Dash0 Web SDK from browsers |
| `dash0_web_sdk_auth_token`     | _required, sensitive_                  | Public ingest token for the Web SDK (env: `TF_VAR_dash0_web_sdk_auth_token`)   |
| `dash0_api_endpoint`           | `https://api.eu-west-1.aws.dash0.com`  | Dash0 API endpoint (for operator-side dashboards/views sync) |
| `ebpf_profiler_image_tag`      | `0.153.0`                              | Tag of the `otel/opentelemetry-collector-ebpf-profiler` image running as the node-local profiling DaemonSet |

## Notes

- **Web SDK injection via Envoy**: the demo's `frontend-proxy` (Envoy) template
  (`deployment/terraform/frontend-proxy/envoy.tmpl.yaml`, a fork of the
  upstream `src/frontend-proxy/envoy.tmpl.yaml` from otel-demo v2.2.0) adds an
  `envoy.filters.http.lua` filter that rewrites `text/html` response bodies to
  inject the [Dash0 Web SDK](https://github.com/dash0hq/dash0-sdk-web) IIFE
  bundle + `init()` call immediately before `</head>`. Endpoint, browser
  token, service version, and VCS attributes arrive as pod env vars via
  `components.frontend-proxy.envOverrides` and are inlined into the Lua source
  by envsubst at container start. The Lua filter also strips `Accept-Encoding`
  on requests so upstream returns uncompressed HTML (LuaJIT can't decode
  gzip). When bumping `otel_demo_chart_version`, diff the forked template
  against the matching upstream tag and reapply the Lua block.
- **Deployment events**: on every _successful_ apply against `main`, the
  `dash0-deploy-events` matrix job fans out one `dash0.deployment` log event
  per demo service whose Kubernetes pod template _actually changed_ during
  that apply, via the
  [`dash0hq/dash0-cli/.github/actions/send-log-event`](https://github.com/dash0hq/dash0-cli/tree/main/.github/actions/send-log-event)
  action. The change set comes from `.github/scripts/detect_changed_services.py`,
  which sha256-hashes the pod template of every `Deployment` / `DaemonSet` /
  `StatefulSet` in the two Helm releases (`otel-demo` and `dash0-operator`)
  before and after apply — everything that would trigger a rollout ends up
  in that hash. Failed applies and no-op applies produce zero events, so the
  Dash0 timeline reflects only real rollouts. Each event carries the
  service's own `service.name` (and
  `service.namespace` where the running service sets one — currently only the
  `dash0-operator` components) plus the `vcs.repository.url.full` /
  `vcs.ref.head.revision` / `vcs.ref.head.name` attributes the operator stamps
  on all runtime telemetry — so a per-service alert like the product-catalog
  error-rate check rule can be correlated with the exact commit whose apply
  produced it. The OTLP HTTP endpoint comes from the `DASH0_OTLP_URL` GitHub
  Actions variable (set at organization level; override at repo level to point
  at a different tenant).
- **Disabled in `values.yaml`**: in-cluster Jaeger, Prometheus, Grafana, and
  OpenSearch (Dash0 is the only backend); the `flagd-ui` admin sidecar (it
  OOMs at modest memory limits and isn't needed for telemetry); the demo
  chart's bundled `opentelemetry-collector` (the Dash0 operator deploys and
  configures its own collectors).
- **`OTEL_COLLECTOR_NAME` override**: the demo apps' chart defaults
  `OTEL_EXPORTER_OTLP_ENDPOINT` to `http://$(OTEL_COLLECTOR_NAME):4318`. We
  set `OTEL_COLLECTOR_NAME` via `default.envOverrides` to the operator's
  DaemonSet collector Service so SDK telemetry lands in the operator's
  pipeline.
- **Auto-namespace monitoring with `instrumentWorkloads.mode=none`**: the
  operator chart is installed with `operator.autoMonitorNamespaces.enabled=true`
  and its top-level `operator.monitoringTemplate.spec.instrumentWorkloads.mode`
  set to `none`. Every non-system namespace gets a `Dash0Monitoring` resource
  automatically, but the operator's `LD_PRELOAD` auto-instrumentation is
  disabled — the demo apps already carry their own OpenTelemetry SDKs and
  double-instrumentation would conflict. Logs, k8s events, and cluster
  metrics still flow from the operator's own collectors.
- **eBPF profiling**: `operator.profilingEnabled=true` on the operator turns
  on OTel profile ingestion in its collectors, and
  `deployment/terraform/ebpf-profiler.tf` adds a node-local DaemonSet running
  the `otel/opentelemetry-collector-ebpf-profiler` image. The profiler samples
  stacks with eBPF, exports OTel profiles over OTLP/gRPC to the operator's
  collector Service, and the operator forwards them to Dash0. See the [Dash0
  profiling docs](https://www.dash0.com/docs/dash0/monitoring/kubernetes/dash0-operator/profiling).
  The DaemonSet needs `hostPID`, `hostPath` mounts of `/proc` + `/sys`, and
  Linux capabilities (`SYS_ADMIN`/`SYS_PTRACE`/`SYS_RESOURCE`/`SYSLOG`) — none
  of which are permitted on GKE Autopilot's default `WorkloadAllowlist`, which
  is why this cluster runs GKE Standard.
- **State**: stored in GCS bucket `${PROJECT_ID}-tf-state-wad-demo` with
  versioning enabled.
- **Auth**: GitHub Actions impersonates the Terraform SA via Workload Identity
  Federation — no long-lived JSON keys.
