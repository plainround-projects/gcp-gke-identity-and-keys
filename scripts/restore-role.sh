#!/usr/bin/env bash
# Step 4, the fix: put the role back. The test passes again with no restart. (Terraform owns the binding; this puts it back by hand.)
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="$PRINCIPAL" --role=roles/storage.objectUser
echo "waiting 60 seconds for the grant to propagate"
sleep 60
pod_test files
kubectl -n demo get pods -l app=files   # RESTARTS is still 0: no restart was needed
