#!/usr/bin/env bash
# Step 5, the fix: enable the version again. Access returns within a minute or two.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

gcloud kms keys versions enable 1 --key=files-key --keyring=files --location="$REGION"
sleep 60
kubectl -n demo exec deploy/files -- gcloud storage cat "gs://$BUCKET/first.txt"
