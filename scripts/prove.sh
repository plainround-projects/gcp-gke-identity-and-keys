#!/usr/bin/env bash
# Done when lines of steps 1 and 2, one check each. Exit status 1 if any check fails.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

echo "== Step 1: the key"
check "an uploaded object shows your key as its encryption key" \
  bash -c "gcloud storage objects describe 'gs://$BUCKET/first.txt' --format='value(kms_key)' | grep -q 'cryptoKeys/files-key'"

echo "== Step 2: the pod's identity"
check "the principal uses the project number, not the id" \
  test -z "$(gcloud storage buckets get-iam-policy "gs://$BUCKET" --flatten='bindings[].members' --filter="bindings.members:projects/$PROJECT_ID/" --format='value(bindings.members)')"
check "the bucket lists the pod's principal as objectUser" \
  test "$(gcloud storage buckets get-iam-policy "gs://$BUCKET" --flatten='bindings[].members' --filter='bindings.role:roles/storage.objectUser' --format='value(bindings.members)')" = "$PRINCIPAL"
check "the pod reads and writes the bucket" pod_test files
check "kubectl get secrets shows no credential" test -z "$(kubectl -n demo get secrets -o name)"
check "no key file exists in the pod" bash -c "! kubectl -n demo exec deploy/files -- sh -c 'ls /tmp/*.json /var/run/secrets 2>/dev/null' | grep -q ."
check "no key was ever created for any service account in the project" \
  bash -c "for sa in \$(gcloud iam service-accounts list --format='value(email)'); do gcloud iam service-accounts keys list --iam-account=\"\$sa\" --managed-by=user --format='value(name)'; done | wc -l | grep -qx 0"

echo "the identity the pod used, from the audit log (needs a few minutes after the first call):"
gcloud logging read "protoPayload.serviceName=\"storage.googleapis.com\" AND protoPayload.resourceName:\"$BUCKET\"" \
  --limit=3 --freshness=1h --format='value(protoPayload.authenticationInfo.principalSubject)' || true
exit "$FAILED"
