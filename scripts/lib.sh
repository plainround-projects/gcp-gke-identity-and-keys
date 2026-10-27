#!/usr/bin/env bash
# Shared by the runbook scripts: loads .env and sets the variables the lesson uses in every command.
# shellcheck disable=SC2034  # the variables are used by the scripts that source this file
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$ROOT/infra/environments/lab"
CAPTURES="$ROOT/captures"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

: "${PROJECT_ID:?set PROJECT_ID in .env (see .env.example)}"
REGION="${REGION:-europe-west1}"
BUCKET="$PROJECT_ID-files"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
KEY="projects/$PROJECT_ID/locations/$REGION/keyRings/files/cryptoKeys/files-key"
# Use the project NUMBER here, never the project id: with the id the binding matches nothing.
PRINCIPAL="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/demo/sa/reader-writer"

# The lesson's test, run again after every change, from inside the pod. Prints the command's output and exit status.
pod_test() {
  local deployment="${1:-files}"
  kubectl -n demo exec "deploy/$deployment" -- sh -c "echo hello > /tmp/a.txt && gcloud storage cp /tmp/a.txt gs://$BUCKET/a.txt && gcloud storage cat gs://$BUCKET/a.txt"
}

# capture NAME [deployment]: run the test, keep the error text in captures/NAME.txt for `make triage`.
capture() {
  local name="$1" deployment="${2:-files}"
  mkdir -p "$CAPTURES"
  if pod_test "$deployment" >"$CAPTURES/$name.txt" 2>&1; then
    echo "the test passed; nothing to capture for $name"
    rm -f "${CAPTURES:?}/${name:?}.txt"
    return 1
  fi
  cat "$CAPTURES/$name.txt"
}

check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $what"
  else
    echo "FAIL  $what"
    FAILED=1
  fi
}
FAILED=0
