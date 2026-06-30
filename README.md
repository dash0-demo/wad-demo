# wad-demo

Infrastructure-as-code for the **We Are Developers** demo: provisions a GKE
Autopilot cluster, installs the OpenTelemetry demo via Helm, and ships all
telemetry to a Dash0 dataset.

```
GitHub Actions ──▶ Terraform ──▶ GKE Autopilot ──┬─▶ OTel demo workloads
   (WIF auth)        (GCS state)                  │
                                                  └─▶ otel-collector ─▶ Dash0 (wad-demo dataset)
```

## Layout

```
deployment/
  helm/
    values.yaml          # Dash0-only collector config; Jaeger/Prometheus/Grafana/OpenSearch disabled
  terraform/
    versions.tf
    backend.tf           # GCS backend, bucket configured at init
    providers.tf         # google, kubernetes, helm providers
    variables.tf
    main.tf              # GKE Autopilot + namespace + dash0-auth Secret + helm_release
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
| Secret   | `DASH0_AUTH_TOKEN`    | the ingest token for the `wad-demo` dataset                                                              |

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
TF_VAR_dash0_auth_token=<token> terraform apply
```

After apply, point `kubectl` at the cluster with the command printed in the
Terraform outputs (`get_credentials_command`).

## Tear down

```sh
cd deployment/terraform
TF_VAR_dash0_auth_token=<token> terraform destroy
```

`helm_release` is removed first (along with the demo workloads), then the
namespace, then the GKE cluster.

## Configuration knobs

All in `deployment/terraform/variables.tf`:

| Variable                  | Default                                     | Purpose                                     |
| ------------------------- | ------------------------------------------- | ------------------------------------------- |
| `project_id`              | _required_                                  | GCP project                                 |
| `region`                  | `europe-west1`                              | Cluster region                              |
| `cluster_name`            | `wad-demo`                                  | GKE cluster name                            |
| `release_channel`         | `REGULAR`                                   | GKE release channel                         |
| `otel_demo_chart_version` | `0.40.9`                                    | Helm chart version                          |
| `dash0_auth_token`        | _required, sensitive_                       | Ingest token (env: `TF_VAR_dash0_auth_token`)|
| `dash0_dataset`           | `wad-demo`                                  | Dash0 dataset technical id                  |
| `dash0_otlp_endpoint`     | `https://ingress.eu-west-1.aws.dash0.com`   | Dash0 OTLP/HTTP ingress                     |

## Notes

- **Disabled in `values.yaml`**: in-cluster Jaeger, Prometheus, Grafana, and
  OpenSearch (Dash0 is the only backend); the `flagd-ui` admin sidecar (it
  OOMs at modest memory limits and isn't needed for telemetry).
- **State**: stored in GCS bucket `${PROJECT_ID}-tf-state-wad-demo` with
  versioning enabled.
- **Auth**: GitHub Actions impersonates the Terraform SA via Workload Identity
  Federation — no long-lived JSON keys.
