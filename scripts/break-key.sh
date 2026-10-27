#!/usr/bin/env bash
# Step 5: disable the key version the bucket uses, then read an existing object. Reads fail even though IAM is fine.
# Never destroy a version here: a destroyed version cannot be recovered.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

gcloud kms keys versions list --key=files-key --keyring=files --location="$REGION"
gcloud kms keys versions disable 1 --key=files-key --keyring=files --location="$REGION"
echo "waiting 60 seconds for the change to propagate"
sleep 60
echo "== read an object written before the key was disabled"
mkdir -p "$CAPTURES"
if kubectl -n demo exec deploy/files -- gcloud storage cat "gs://$BUCKET/first.txt" >"$CAPTURES/key-disabled.txt" 2>&1; then
  echo "the read worked; wait longer or check which version the bucket uses"
else
  cat "$CAPTURES/key-disabled.txt"
  "$ROOT/.venv/bin/gke-triage" classify "$CAPTURES/key-disabled.txt"
fi
