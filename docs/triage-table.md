# Triage table

Fill this in from your own run (`scripts/triage-table.sh` renders it from `captures/*.txt`). The rows below are the lesson's expected pattern with placeholder ids; replace the error text with what you captured. The key row's wording in particular must come from your run.

| Symptom | Exact error text | Layer | First check | Fix |
| --- | --- | --- | --- | --- |
| authenticated but denied (sa/default) | `ERROR: (gcloud.storage.cp) HTTPError 403: principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/default does not have storage.objects.create access to the Google Cloud Storage object. Permission 'storage.objects.create' denied on resource (or it may not exist).` | authorization | print the principal in the error: is it the account you meant? | set `serviceAccountName` on the pod to the account that holds the bucket role |
| denied after a role was removed | `ERROR: (gcloud.storage.cat) HTTPError 403: principal://.../subject/ns/demo/sa/reader-writer does not have storage.objects.get access to the Google Cloud Storage object. Permission 'storage.objects.get' denied on resource (or it may not exist).` | authorization | read the bucket policy: `gcloud storage buckets get-iam-policy gs://BUCKET` | grant a role that includes the permission to the principal, on the bucket |
| reads fail, IAM is fine | `ERROR: (gcloud.storage.cat) HTTPError 403: ... Cloud KMS key ... files-key ... is disabled` (the lesson's pattern; use your own text) | key | `gcloud kms keys versions list --key=files-key --keyring=files --location=REGION` | `gcloud kms keys versions enable 1 ...` (a destroyed version cannot be recovered) |

The three first checks differ on purpose: the first reads the principal in the message, the second the bucket's policy, the third the key's versions.
