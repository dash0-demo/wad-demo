#!/usr/bin/env bash
# One-time bootstrap: GCS state bucket, Terraform service account, and
# Workload Identity Federation between the GitHub repo and GCP.
#
# Idempotent — safe to re-run. Run from any directory.
#
# Usage:
#   PROJECT_ID=dash0-devrel REGION=europe-west1 GITHUB_REPO=dash0-demo/wad-demo \
#     ./deployment/terraform/bootstrap.sh

set -euo pipefail

: "${PROJECT_ID:?PROJECT_ID must be set (e.g. dash0-devrel)}"
: "${GITHUB_REPO:?GITHUB_REPO must be set as owner/repo (e.g. dash0-demo/wad-demo)}"
REGION="${REGION:-europe-west1}"

STATE_BUCKET="${PROJECT_ID}-tf-state-wad-demo"
SA_NAME="wad-demo-tf"
SA_EMAIL="${SA_NAME}@${PROJECT_ID}.iam.gserviceaccount.com"
POOL_ID="github-actions"
PROVIDER_ID="wad-demo"

gcloud config set project "$PROJECT_ID" >/dev/null

echo "[1/5] Enabling required APIs"
gcloud services enable \
  container.googleapis.com \
  iam.googleapis.com \
  iamcredentials.googleapis.com \
  storage.googleapis.com \
  cloudresourcemanager.googleapis.com \
  sts.googleapis.com >/dev/null

echo "[2/5] Ensuring Terraform state bucket gs://${STATE_BUCKET}"
if ! gcloud storage buckets describe "gs://${STATE_BUCKET}" >/dev/null 2>&1; then
  gcloud storage buckets create "gs://${STATE_BUCKET}" \
    --project="${PROJECT_ID}" \
    --location="${REGION}" \
    --uniform-bucket-level-access
fi
gcloud storage buckets update "gs://${STATE_BUCKET}" --versioning >/dev/null

echo "[3/5] Ensuring Terraform service account ${SA_EMAIL}"
if ! gcloud iam service-accounts describe "${SA_EMAIL}" >/dev/null 2>&1; then
  gcloud iam service-accounts create "${SA_NAME}" \
    --display-name="WAD demo Terraform"
fi
for role in roles/container.admin roles/iam.serviceAccountUser roles/compute.networkAdmin roles/storage.admin; do
  # Retry to absorb IAM propagation delay after a fresh service account.
  for attempt in 1 2 3 4 5; do
    if gcloud projects add-iam-policy-binding "${PROJECT_ID}" \
         --member="serviceAccount:${SA_EMAIL}" \
         --role="${role}" \
         --condition=None >/dev/null 2>&1; then
      break
    fi
    if [ "${attempt}" -eq 5 ]; then
      echo "Failed to bind ${role} to ${SA_EMAIL} after ${attempt} attempts" >&2
      exit 1
    fi
    sleep $((attempt * 5))
  done
done

echo "[4/5] Ensuring Workload Identity pool & provider for ${GITHUB_REPO}"
if ! gcloud iam workload-identity-pools describe "${POOL_ID}" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools create "${POOL_ID}" \
    --location=global \
    --display-name="GitHub Actions"
fi
POOL_FULL="projects/$(gcloud projects describe "${PROJECT_ID}" --format='value(projectNumber)')/locations/global/workloadIdentityPools/${POOL_ID}"

if ! gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
      --workload-identity-pool="${POOL_ID}" --location=global >/dev/null 2>&1; then
  gcloud iam workload-identity-pools providers create-oidc "${PROVIDER_ID}" \
    --workload-identity-pool="${POOL_ID}" \
    --location=global \
    --issuer-uri="https://token.actions.githubusercontent.com" \
    --attribute-mapping="google.subject=assertion.sub,attribute.actor=assertion.actor,attribute.repository=assertion.repository" \
    --attribute-condition="assertion.repository=='${GITHUB_REPO}'"
fi

gcloud iam service-accounts add-iam-policy-binding "${SA_EMAIL}" \
  --role=roles/iam.workloadIdentityUser \
  --member="principalSet://iam.googleapis.com/${POOL_FULL}/attribute.repository/${GITHUB_REPO}" >/dev/null

echo "[5/5] Done"
echo
echo "Set these as GitHub Actions repository variables (Settings → Secrets and variables → Actions → Variables):"
echo "  GCP_PROJECT_ID:        ${PROJECT_ID}"
echo "  GCP_REGION:            ${REGION}"
echo "  TF_STATE_BUCKET:       ${STATE_BUCKET}"
echo "  WIF_PROVIDER:          ${POOL_FULL}/providers/${PROVIDER_ID}"
echo "  WIF_SERVICE_ACCOUNT:   ${SA_EMAIL}"
echo
echo "And these as GitHub Actions repository secrets (Settings → Secrets and variables → Actions → Secrets):"
echo "  DASH0_AUTH_TOKEN:      <wad-demo Dash0 ingest token>"
echo "  DASH0_API_TOKEN:       <wad-demo Dash0 management API token (check_rules:write etc.)>"
