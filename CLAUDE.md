# wad-demo Development Guide

This repository is the infrastructure-as-code for the **We Are Developers** demo: a GKE cluster running the OpenTelemetry Astronomy Shop with the Dash0 operator, everything shipping telemetry to the `wad-demo` Dash0 dataset.
Terraform provisions the cluster, the Helm release of `open-telemetry/opentelemetry-demo`, the Dash0 operator plus `Dash0Monitoring` resources, and Dash0-side assets (check rules, synthetic checks).
GitHub Actions plans on PR and applies on push to `main`.

## Commands

- Format: `make fmt` (or `make fmt-check` to fail-if-changes).
- Init: `make init TF_STATE_BUCKET=<bucket>`.
- Validate: `make validate`.
- Plan: `make plan`.
- Apply: `make apply` (usually done via CI on push to `main`).
- Destroy: `make destroy`.
- Show outputs: `make output`.
- One-time GCP bootstrap: `make bootstrap PROJECT_ID=<id> GITHUB_REPO=<owner/repo>`.
- Render Helm locally: `helm template test open-telemetry/opentelemetry-demo --version <ver> --values deployment/helm/values.yaml`.
- Query the live dataset: `dash0 spans query --filter '...'`, `dash0 logs query --filter '...'`, `dash0 metrics instant --promql '...'`.

`TF_VAR_dash0_auth_token`, `TF_VAR_dash0_api_token`, and `TF_VAR_dash0_web_sdk_auth_token` must be set (via `.env` — gitignored — or the environment) for local plans and applies.
In CI they arrive as GitHub secrets.

## Layout

```
deployment/
  helm/
    values.yaml           # OTel demo chart overrides — the source of truth
                          # for cross-tenant demo config (envs, disabled
                          # backends, imageOverrides, resource sizing)
  terraform/
    main.tf               # Cluster + operator + Dash0Monitoring + otel-demo Helm release
    check_rules.tf        # Dash0 check rules (product-catalog error rate, latency)
    synthetic_checks.tf   # Dash0 synthetic checks (frontend homepage, /api/*)
    frontend_public.tf    # Reserved external IP + Service for the frontend-proxy
    ebpf-profiler.tf      # OTel eBPF profiler DaemonSet
    frontend-proxy/       # Forked envoy.tmpl.yaml — mounted over the image's baked-in one
    loadgen/              # Patched locustfile.py + people.json — mounted over image files
    flagd/                # Durable feature-flag defaults — mounted over image files
    check_rules/          # YAML source files for each check rule (loaded via for_each)
    synthetic_checks/     # YAML source files for each synthetic check
.github/workflows/
  terraform.yml           # plan on PR, apply on push to main, deploy events per rolled service
```

## Development guidelines

### The four override patterns

Almost every non-trivial change in this repo uses one of four override mechanisms against the upstream OTel demo chart.
When adding new behavior, pick the smallest of these that will work — do not fork more than you have to.

1. **Chart values (`deployment/helm/values.yaml`)** — env vars, resource limits, `enabled: false` for bundled components, `imageOverride` entries.
   Merged with a Terraform-generated overlay (`local.otel_demo_values_overrides` in `main.tf`) that carries values only Terraform can compute (dataset endpoints, secrets, git SHA).
2. **`envOverrides` in Terraform** (`main.tf`, `otel_demo_values_overrides` local) — same as above but for env vars whose value depends on Terraform state (secret refs, `data.external.git_head.result.sha`, `regex(...)` on other variables).
   Prefer `values.yaml` for anything static.
3. **ConfigMap `subPath` override** — for files baked into upstream images we want to replace without rebuilding the image.
   Current examples:
   - `deployment/terraform/frontend-proxy/envoy.tmpl.yaml` overlaid at `/home/envoy/envoy.tmpl.yaml`.
   - `deployment/terraform/loadgen/locustfile.py` and `people.json` overlaid at `/usr/src/app/*`.
   - `deployment/terraform/flagd/demo.flagd.json` overlaid at `/config-ro/demo.flagd.json`.
4. **`imageOverride` pointing at a `dash0-demo/opentelemetry-demo` fork build** — for patches that need source-code changes.
   Used sparingly: currently only the `frontend` component (fork PRs #81 and #96).
   The fork has a `dash0-build-images.yml` workflow that publishes `ghcr.io/dash0-demo/opentelemetry-demo:<sha>-<component>` on push to main.
   Always pin to the immutable `<sha>-<component>` tag, never `main-<component>`.

### Chart version bumps

When bumping `otel_demo_chart_version` in `variables.tf`, three forked files need re-syncing against the matching upstream tag.

- `deployment/terraform/frontend-proxy/envoy.tmpl.yaml` — diff against `open-telemetry/opentelemetry-demo/src/frontend-proxy/envoy.tmpl.yaml` at the target tag; reapply the `/_dash0/*` reverse-proxy route and `dash0_ingest` upstream cluster.
- `deployment/terraform/loadgen/locustfile.py` — diff against `open-telemetry/opentelemetry-demo/src/loadgenerator/locustfile.py`; reapply the `seed_person(page)` calls in `WebsiteBrowserUser` tasks and the module-level `tracer` swap.
- `deployment/terraform/loadgen/people.json` — the extended 12-person set with `countryCode` and `continentCode` fields overlays the upstream 9-person file.
  Only re-sync if upstream adds meaningful fields; otherwise our extension is a strict superset.

Also re-check the `dash0-demo/opentelemetry-demo` fork commits used by any `imageOverride`.
If the patches those carry have made it upstream, delete the fork image reference from `values.yaml`.

### The dash0-deploy-events job

The `dash0-deploy-events` matrix job in [`terraform.yml`](.github/workflows/terraform.yml) hashes the pod template of every `Deployment`, `DaemonSet`, and `StatefulSet` in the `otel-demo` and `dash0-operator` Helm releases before and after apply.
It emits one `dash0.deployment` event per service whose hash changed.
This means:

- Any change to a service's env, volume mounts, resource requests, or image tag produces a deploy event with the current commit SHA in `vcs.ref.head.revision`.
- Cosmetic changes (comments in `values.yaml`, formatting) do not emit events, because the pod template hash is unchanged.
- Failed applies emit zero events.
  Successful no-op applies also emit zero events.
- If you deliberately roll a pod without changing its template (for example, `kubectl rollout restart`), no event is emitted — that is by design.

When designing a change, expect the deploy event to fire on the affected services and no others.

### GKE Standard, not Autopilot

The cluster migrated off Autopilot to Standard for eBPF profiler support.
This has two consequences you need to keep in mind.

Pod resource `requests` matter for scheduling and cost.
Setting only `limits` no longer works cleanly — set both, and match them for latency-sensitive workloads (Chromium in the load-generator, for example, throttles on burstable slices).

Cloud NAT is provisioned separately (see `main.tf`).
Cluster egress requires it — verify Cloud NAT health if pods cannot reach `unpkg.com` or `ingress.eu-west-1.aws.dash0.com`.

### The Dash0 Web SDK path

The frontend embeds `@dash0/sdk-web` directly (fork PR [dash0-demo/opentelemetry-demo#96](https://github.com/dash0-demo/opentelemetry-demo/pull/96)), reading its config from `window.ENV` which `pages/_document.tsx` inlines from `PUBLIC_DASH0_WEB_SDK_*` env vars set in `main.tf`.
Web SDK telemetry does **not** go direct to Dash0 ingest — it goes through a same-origin `/_dash0/*` reverse-proxy route on the frontend-proxy Envoy, which relays with the `DASH0_WEB_SDK_AUTH_TOKEN` injected server-side.
This exists because Dash0 ingest does not return CORS headers for the demo's origin.

When touching this path, changes typically span three files: `deployment/helm/values.yaml`, `deployment/terraform/main.tf` (env vars on the `frontend` or `frontend-proxy` components), and `deployment/terraform/frontend-proxy/envoy.tmpl.yaml` (route + cluster config).

### Local validation before pushing

For any change that touches Terraform, run `make fmt validate` locally.
For chart-value or Envoy-template changes, additionally render and inspect.

```bash
helm template test open-telemetry/opentelemetry-demo --version 0.40.9 --values deployment/helm/values.yaml
```

That confirms the rendered manifests look right and is useful for verifying env-var and volume-mount changes.

```bash
envsubst < deployment/terraform/frontend-proxy/envoy.tmpl.yaml | yq eval '.static_resources.listeners[0].filter_chains[0].filters[0].typed_config' -
```

That confirms the Envoy YAML is well-formed after `${VAR}` substitution at container start.

For loadgen changes, rebuild the image locally in a checkout of the fork.

```bash
docker build -f src/loadgenerator/Dockerfile -t local/loadgen .
```

Then point it at the live public IP with small user counts — Locust prints task-failure attributions to stderr that the in-cluster Python-OTel logging handler swallows, and only the local run surfaces them.

## Prose rules

Follow these rules when writing or editing Markdown in this repo (README.md, AGENTS.md, CLAUDE.md, PR descriptions, and commit bodies).
The intent is that any pass of edits leaves the prose readable, easy to diff, and consistent across files.

### Line and paragraph structure

- **One sentence per line** (semantic line breaks).
  Each sentence starts on its own line; do not wrap mid-sentence at a fixed column.
- Separate paragraphs with a single blank line.
- Keep paragraphs between 2 and 5 sentences.
  If a paragraph gets longer, split it or move detail into a list.

### Section headers

Section headers are written in sentence case, for example "The four override patterns" — not "The Four Override Patterns" or "THE FOUR OVERRIDE PATTERNS".

### Links

- Use inline Markdown links: `[visible text](url)`.
- Link the most specific relevant term, not generic phrases like "click here" or "this page".
- For cross-repo references (issues, PRs, files) prefer the full GitHub URL to keep the doc self-contained.

### Code blocks

- Fence with triple backticks and a language identifier (` ```yaml `, ` ```bash `, ` ```hcl `, ` ```lua `, and so on).
- Use code blocks for illustrative examples.
- **One independent command per code block.**
  Do not stack unrelated commands inside a single ` ```bash ` block.
  A reader's "copy" action should never grab more than one thing they intended to run.
  Exceptions: a multi-line invocation continued with `\`, a `key=value` env-var prefix followed by the command (`TF_VAR_dash0_auth_token=… terraform apply`), or a pipeline (`dash0 spans query … | jq …`) — those are a *single* command.
- Multi-step workflows use one code block per step, with prose between them describing what the previous step accomplished and what the next one does.

### Punctuation and typography

- End sentences with full stops.
- Use the **Oxford comma** (for example, "the four overrides: values.yaml, envOverrides, ConfigMap subPath, and imageOverride").
- Use curly typographic quotes in prose (`"…"`, `'…'`); straight quotes are fine inside code blocks.
- Write numbers as digits and spell out "percent" (for example, "10 percent", not "10%" or "ten percent").

### Referencing external artifacts

- **GitHub Actions**: name-as-code with a link to the workflow file, for example [`terraform.yml`](.github/workflows/terraform.yml).
- **Make targets**: name-as-code, no link (they live in `Makefile`).
- **Terraform resource / module addresses**: name-as-code, for example `helm_release.otel_demo` or `kubernetes_config_map.frontend_proxy_envoy`.
- **Kubernetes objects**: name-as-code in the form `kind/name`, for example `Deployment/frontend-proxy` or `ConfigMap/frontend-proxy-envoy-override`.
- **Attribute keys in Dash0 examples**: use real Dash0 or OpenTelemetry Semantic Convention attribute keys — never invented ones.
  Common ones you will need:
  - Signals: `service.name`, `service.namespace`, `otel.log.body`, `otel.log.severity.range`, `otel.trace.id`, `otel.span.name`.
  - Kubernetes: `k8s.deployment.name`, `k8s.pod.name`, `k8s.container.name`, `k8s.namespace.name`.
  - VCS (stamped by the Dash0 operator): `vcs.repository.url.full`, `vcs.ref.head.revision`, `vcs.ref.head.name`.
  - The valid `otel.log.severity.range` values are `TRACE`, `DEBUG`, `INFO`, `WARN`, `ERROR`, `FATAL`, and `UNKNOWN`.

### Validation

When any of the four override patterns, the deploy-event contract, or a hard rule change in behavior, update this file (and its identical `CLAUDE.md` twin) in the same PR.
Documentation drift is a review blocker.

## Hard rules

- **Never commit `.env`, `terraform.tfvars`, or anything containing `TF_VAR_dash0_*_token`.**
  These tokens have write access to the wad-demo Dash0 dataset and the GCP project.
  Verify `.gitignore` covers new files that could leak them.
- **Never force-push to `main`.**
  Feature branches only.
  Force-push even on feature branches requires explicit user approval.
- **Never bypass the `dash0.com/origin` label semantics** on Dash0 assets managed here.
  Terraform-managed check rules, synthetic checks, and dashboards must carry the correct origin so the CLI and UI do not fight over ownership.
- **`imageOverride` tags must be SHA-immutable.**
  `main-<component>` is not acceptable — it moves under our feet and defeats the deploy-event correlation.
- **Chart version bumps require re-syncing the forked files listed above.**
  No exceptions — if upstream changed the file, our fork has bit-rot until re-synced.

## GitHub issues

Issues should describe **what** and **why** — the problem statement, the desired user-facing behavior, and acceptance criteria.
Not **how** — implementation choices belong in the PR that resolves the issue, not in the issue itself.
Keep the surface small so an implementer (human or agent) can meaningfully pick between approaches.
