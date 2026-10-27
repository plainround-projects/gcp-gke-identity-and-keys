# gcloud (the Google Cloud command-line tool)

## 1. What it is

`gcloud` is a program you run in a terminal to control Google Cloud: create projects, read logs, change permissions, and fetch cluster credentials. Each command is a sentence of nouns and a verb, such as `gcloud storage buckets remove-iam-policy-binding`. It signs in as you (or as a service account) and sends the matching requests to Google's APIs.

## 2. Why this repository uses it

Terraform builds the infrastructure. `gcloud` is what the owner types to **prove** and **break** it, in the exact commands the lesson gives: remove a bucket role, disable a key version, read an audit log, look at a key version's state.

## 3. Where it appears

| Path | What it does with gcloud |
| --- | --- |
| `scripts/lib.sh` | Sets the project; looks up the project number. |
| `scripts/create-project.sh` | `gcloud projects create`, `gcloud billing projects link`, `gcloud projects describe`. |
| `scripts/deploy.sh` | `gcloud container clusters get-credentials`, `gcloud storage cp`, `objects describe`. |
| `scripts/prove.sh` | Reads bucket policy; lists service accounts and their keys; reads audit logs. |
| `scripts/break-missing-role.sh`, `restore-role.sh` | `buckets remove-iam-policy-binding`, `add-iam-policy-binding`. |
| `scripts/break-key.sh`, `restore-key.sh` | `gcloud kms keys versions list/disable/enable`. |
| `scripts/break-wrong-sa.sh` | `gcloud logging read` into a JSON file. |
| `scripts/teardown.sh` | `gcloud projects delete`. |

None of these ran against a real project when the repository was built.

## 4. How it works underneath

- **Configuration.** `gcloud config set project ID` stores a default project in a file in your home folder; later commands use it unless you pass `--project`.
- **Credentials.** `gcloud auth login` stores your login. Commands send your token. In this repository the *pod* uses `gcloud` too, but with the token the GKE metadata server gives it, not yours.
- **Output control.** `--format='value(field)'` prints just a field; `--filter` selects rows; `--flatten='bindings[].members'` turns a list into one row per item, which is how the IAM policy checks work.
- **Exit status.** A failed command exits non-zero, which scripts use to decide pass or fail.

## 5. Walkthrough of this repository's use

`scripts/lib.sh`

```bash
: "${PROJECT_ID:?set PROJECT_ID in .env (see .env.example)}"
REGION="${REGION:-europe-west1}"
BUCKET="$PROJECT_ID-files"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
KEY="projects/$PROJECT_ID/locations/$REGION/keyRings/files/cryptoKeys/files-key"
# Use the project NUMBER here, never the project id: with the id the binding matches nothing.
PRINCIPAL="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/demo/sa/reader-writer"
```

- `: "${PROJECT_ID:?...}"` stops the script with a message if the variable is empty.
- `gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)'` prints only the project's **number**. The principal needs the number, not the id.
- `PRINCIPAL=...` builds the pod's IAM member from the number and id.

The break and the fix, copied from the lesson:

`scripts/break-missing-role.sh`

```bash
gcloud storage buckets remove-iam-policy-binding "gs://$BUCKET" --member="$PRINCIPAL" --role=roles/storage.objectUser
echo "waiting 60 seconds for the removal to propagate"
sleep 60
capture missing-role files || true
"$ROOT/.venv/bin/gke-triage" classify "$CAPTURES/missing-role.txt"
```

`scripts/break-key.sh`

```bash
gcloud kms keys versions list --key=files-key --keyring=files --location="$REGION"
gcloud kms keys versions disable 1 --key=files-key --keyring=files --location="$REGION"
```

- `remove-iam-policy-binding gs://BUCKET --member=... --role=...` takes away exactly one binding.
- `kms keys versions disable 1 --key=files-key --keyring=files --location=REGION` disables version 1 of the key. Never `destroy` here: a destroyed version cannot be recovered.

Proving the pod holds no project-level role and no key exists:

`scripts/prove.sh`

```bash
check "no key was ever created for any service account in the project" \
  bash -c "for sa in \$(gcloud iam service-accounts list --format='value(email)'); do gcloud iam service-accounts keys list --iam-account=\"\$sa\" --managed-by=user --format='value(name)'; done | wc -l | grep -qx 0"

echo "the identity the pod used, from the audit log (needs a few minutes after the first call):"
gcloud logging read "protoPayload.serviceName=\"storage.googleapis.com\" AND protoPayload.resourceName:\"$BUCKET\"" \
  --limit=3 --freshness=1h --format='value(protoPayload.authenticationInfo.principalSubject)' || true
exit "$FAILED"
```

`gcloud iam service-accounts list` lists accounts; for each, `keys list --managed-by=user` lists keys that a person created (those would be downloaded key files). The count must be zero. The lesson's checks `exit "$FAILED"` at the end.

## 6. Try it yourself

You can read the commands without an account:

```bash
grep -rhn "gcloud " scripts/*.sh | wc -l
```
Expected: a count of lines (25 at the time of writing) that use the tool.

```bash
shellcheck scripts/*.sh && echo clean
```
Expected: `clean`.

With an account and your own project (these only read):

```bash
gcloud config list
gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)'
```
Expected: your configuration, then the number of your project.

## 7. Mistakes people make

- **Running against the wrong project.** Check `gcloud config list`; the scripts set the project from `.env`.
- **Not waiting after an IAM or key change.** Wait about a minute before testing.
- **Using the project id where the number is needed** (the principal). The script reads the number.
- **Destroying a key version instead of disabling it.** Destruction is permanent.
- **Parsing human-readable output.** Use `--format`.

## 8. Check yourself

1. Why does the script call `gcloud projects describe` with `value(projectNumber)`? *The principal needs the project number.*
2. What does `kms keys versions disable` do? *Makes the version unusable until it is enabled again.*
3. What does `--managed-by=user` select? *Keys that people created (not Google-managed ones).*
4. What does `${VAR:?msg}` do? *Stops with `msg` if `VAR` is empty.*
5. What does a non-zero exit status tell a script? *The command failed.*

## 9. Further reading

- gcloud CLI overview: <https://cloud.google.com/sdk/gcloud>
- Reference: <https://cloud.google.com/sdk/gcloud/reference>
- Formatting output: <https://cloud.google.com/sdk/gcloud/reference/topic/formats>
- Filters: <https://cloud.google.com/sdk/gcloud/reference/topic/filters>
