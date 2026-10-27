#!/usr/bin/env bash
# Step 4: remove the bucket role from the correct identity. Do not restart the pod: the next request already fails.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

gcloud storage buckets remove-iam-policy-binding "gs://$BUCKET" --member="$PRINCIPAL" --role=roles/storage.objectUser
echo "waiting 60 seconds for the removal to propagate"
sleep 60
capture missing-role files || true
"$ROOT/.venv/bin/gke-triage" classify "$CAPTURES/missing-role.txt"
