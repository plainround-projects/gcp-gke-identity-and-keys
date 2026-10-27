#!/usr/bin/env bash
# Step 3: a copy of the service on the default Kubernetes service account. It authenticates; it is not authorized.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

kubectl apply -k "$ROOT/manifests/overlays/wrong-identity"
kubectl -n demo rollout status deploy/files-default --timeout=300s
echo "== the error as the command shows it (saved to captures/wrong-service-account.txt)"
capture wrong-service-account files-default || true
echo
echo "== the same denial in Cloud Logging (data-access audit log); classify it:"
sleep 30
gcloud logging read "protoPayload.serviceName=\"storage.googleapis.com\" AND protoPayload.status.code=7 AND protoPayload.resourceName:\"$BUCKET\"" \
  --limit=20 --freshness=1h --format=json >"$CAPTURES/wrong-service-account-audit.json"
"$ROOT/.venv/bin/gke-triage" audit "$CAPTURES/wrong-service-account-audit.json" || true
"$ROOT/.venv/bin/gke-triage" classify "$CAPTURES/wrong-service-account.txt"
