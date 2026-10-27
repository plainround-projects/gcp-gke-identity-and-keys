#!/usr/bin/env bash
# Step 1 and 2: the cluster, the key, the bucket and the pod's bucket role (Terraform), then the service (kubectl).
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

cd "$ENV_DIR" || exit 1
terraform init
terraform apply -var-file=lab.tfvars

gcloud container clusters get-credentials demo --region="$REGION"
kubectl apply -k "$ROOT/manifests/base"
kubectl -n demo rollout status deploy/files --timeout=300s

echo "bucket encryption key:"
echo hi | gcloud storage cp - "gs://$BUCKET/first.txt"
gcloud storage objects describe "gs://$BUCKET/first.txt" --format='value(kms_key)'
