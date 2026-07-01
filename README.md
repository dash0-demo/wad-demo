# wad-demo

Infrastructure-as-code for the **We Are Developers** demo: provisions a GKE
Autopilot cluster, installs the Dash0 operator + the OpenTelemetry demo via
Helm, and ships all telemetry to the `wad-demo` Dash0 dataset.

```
GitHub Actions ──▶ Terraform ──▶ GKE Autopilot ──┬─▶ Dash0 operator (dash0-system)
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
    main.tf              # GKE Autopilot + dash0-system + Dash0 operator + Dash0Monitoring + otel-demo
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
TF_VAR_dash0_auth_token=<ingest-token> TF_VAR_dash0_api_token=<api-token> terraform apply
```

After apply, point `kubectl` at the cluster with the command printed in the
Terraform outputs (`get_credentials_command`).

## Tear down

```sh
cd deployment/terraform
TF_VAR_dash0_auth_token=<ingest-token> TF_VAR_dash0_api_token=<api-token> terraform destroy
```

`helm_release` is removed first (along with the demo workloads), then the
namespace, then the GKE cluster.

## Configuration knobs

All in `deployment/terraform/variables.tf`:

| Variable                       | Default                                | Purpose                                                      |
| ------------------------------ | -------------------------------------- | ------------------------------------------------------------ |
| `project_id`                   | _required_                             | GCP project                                                  |
| `region`                       | `europe-west1`                         | Cluster region                                               |
| `cluster_name`                 | `wad-demo`                             | GKE cluster name                                             |
| `release_channel`              | `REGULAR`                              | GKE release channel                                          |
| `otel_demo_chart_version`      | `0.40.9`                               | OTel demo chart version                                      |
| `dash0_operator_chart_version` | _empty (latest)_                       | Pin a specific operator chart version if needed              |
| `dash0_auth_token`             | _required, sensitive_                  | Ingest token used by the operator (env: `TF_VAR_dash0_auth_token`) |
| `dash0_api_token`              | _required, sensitive_                  | Management API token used by the dash0 provider (env: `TF_VAR_dash0_api_token`) |
| `dash0_dataset`                | `wad-demo`                             | Dash0 dataset technical id                                   |
| `dash0_otlp_grpc_endpoint`     | `ingress.eu-west-1.aws.dash0.com:4317` | OTLP/gRPC endpoint used by the operator's collectors         |
| `dash0_api_endpoint`           | `https://api.eu-west-1.aws.dash0.com`  | Dash0 API endpoint (for operator-side dashboards/views sync) |

## Notes

- **Disabled in `values.yaml`**: in-cluster Jaeger, Prometheus, Grafana, and
  OpenSearch (Dash0 is the only backend); the `flagd-ui` admin sidecar (it
  OOMs at modest memory limits and isn't needed for telemetry); the demo
  chart's bundled `opentelemetry-collector` (the Dash0 operator deploys and
  configures its own collectors, which are Autopilot-friendly out of the box).
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
- **`operator.gke.autopilot.enabled=true`**: deploys an `AllowlistSynchronizer`
  so Autopilot's Warden permits the operator's pods (which use custom node
  affinities and other features outside Autopilot's default allow-list).
  Side effect: kubeletstats utilization metrics (`k8s.pod.cpu_limit_utilization`
  and siblings) are not collected — Autopilot withholds the `nodes/proxy`
  permission needed for the kubelet `/pod` endpoint.
- **State**: stored in GCS bucket `${PROJECT_ID}-tf-state-wad-demo` with
  versioning enabled.
- **Auth**: GitHub Actions impersonates the Terraform SA via Workload Identity
  Federation — no long-lived JSON keys.
