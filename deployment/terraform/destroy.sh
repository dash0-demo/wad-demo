#!/usr/bin/env bash
# Destroy the wad-demo cluster + Dash0 resources locally. Companion to
# .github/workflows/terraform-destroy.yml — same effect, but no 12-minute
# GitHub Actions Helm-uninstall deadline. Handy when the CI destroy times out
# in the operator's pre-delete hook (as the current wad-demo state does).
#
# Prereqs (one-time):
#   gcloud auth application-default login
#   gcloud config set project we-are-developers-501011
#   export TF_VAR_dash0_auth_token=<wad-demo Dash0 ingest token>
#   export TF_VAR_dash0_api_token=<wad-demo Dash0 management API token>
#   export TF_VAR_dash0_web_sdk_auth_token=<wad-demo Web SDK ingest token>
#   (export them in your shell — do NOT pass them on the command line, they'd
#   land in the transcript / shell history.)
#
# If the operator's pre-delete hook wedges again (`helm_release.dash0_operator
# Still destroying... 10m0s elapsed`), from a second shell:
#   gcloud container clusters get-credentials wad-demo --region europe-west1 \
#     --project we-are-developers-501011
#   kubectl -n dash0-system delete job dash0-operator-pre-delete \
#     --force --grace-period=0
# Then re-run this script — terraform picks up where it left off.

set -euo pipefail

PROJECT_ID="${TF_VAR_project_id:-we-are-developers-501011}"
REGION="${TF_VAR_region:-europe-west1}"
STATE_BUCKET="${PROJECT_ID}-tf-state-wad-demo"

missing=0
for v in TF_VAR_dash0_auth_token TF_VAR_dash0_api_token TF_VAR_dash0_web_sdk_auth_token; do
  if [ -z "${!v:-}" ]; then
    echo "Missing env var: $v" >&2
    missing=1
  fi
done
if [ "$missing" -eq 1 ]; then
  echo "Export the missing token(s) in your shell, then re-run." >&2
  exit 1
fi

if ! gcloud auth application-default print-access-token >/dev/null 2>&1; then
  echo "Application Default Credentials are not configured." >&2
  echo "Run: gcloud auth application-default login" >&2
  exit 1
fi

export TF_VAR_project_id="$PROJECT_ID"
export TF_VAR_region="$REGION"
export TF_IN_AUTOMATION=true
export TF_INPUT=0

cd "$(dirname "${BASH_SOURCE[0]}")"

echo "==> terraform init (backend: gs://${STATE_BUCKET}/wad-demo/gke)"
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="prefix=wad-demo/gke" \
  -reconfigure

echo "==> terraform destroy -auto-approve"
terraform destroy -auto-approve
