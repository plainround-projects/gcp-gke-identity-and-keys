#!/usr/bin/env bash
# Step 6: remove the cluster, the bucket and the key's versions, then delete the project. Same day.
# Key versions are destroyed after the scheduled period (24 hours here) and cannot be recovered after that;
# the key ring itself can never be deleted, which is one more reason to use a project you throw away.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

read -r -p "Delete project $PROJECT_ID? Type the project id to confirm: " answer
[[ "$answer" == "$PROJECT_ID" ]] || { echo "not confirmed"; exit 1; }

kubectl delete -k "$ROOT/manifests/overlays/wrong-identity" --ignore-not-found || true
(cd "$ENV_DIR" && terraform destroy -var-file=lab.tfvars) || echo "terraform destroy did not finish; deleting the project removes the resources anyway"
gcloud projects delete "$PROJECT_ID" --quiet
gcloud projects describe "$PROJECT_ID" --format='value(lifecycleState)'   # DELETE_REQUESTED
