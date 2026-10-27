#!/usr/bin/env bash
# Creates the project, links billing and writes the Terraform variables file. Delete everything the same day.
# Needs PROJECT_ID, BILLING_ACCOUNT and MASTER_AUTHORIZED_CIDR (your address as a /32) in .env.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
: "${PROJECT_ID:?set PROJECT_ID in .env}"
: "${BILLING_ACCOUNT:?set BILLING_ACCOUNT in .env (gcloud billing accounts list)}"
: "${MASTER_AUTHORIZED_CIDR:?set MASTER_AUTHORIZED_CIDR in .env: your public address as a /32}"
REGION="${REGION:-europe-west1}"

gcloud projects create "$PROJECT_ID" ${ORG_ID:+--organization="$ORG_ID"} --labels=purpose=lab
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

cat >"$ROOT/infra/environments/lab/lab.tfvars" <<VARS
project_id     = "$PROJECT_ID"
project_number = "$PROJECT_NUMBER"
region         = "$REGION"

master_authorized_cidrs = {
  laptop = "$MASTER_AUTHORIZED_CIDR"
}
VARS
echo "wrote infra/environments/lab/lab.tfvars"
