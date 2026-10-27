# Bash

## 1. What it is

Bash is a **shell**: a program that reads commands you type (or that a file contains) and runs other programs for you. A **shell script** is a text file of such commands. A **command** is a program name followed by **arguments** (the words after it) and **flags** (arguments that start with `-`). Bash also has variables, `if`, `for` and functions, so a script can make decisions. The scripts here need Bash (the macOS one is fine, version 3.2 or newer).

## 2. Why this repository uses it

The runbook is a list of `gcloud`, `kubectl` and `terraform` commands that a person runs in order: create the project, deploy, prove the keyless pod, break access three ways and fix each, build the triage table, tear down. Putting them in scripts makes them exact, repeatable and checkable with `shellcheck`.

## 3. Where it appears

| Path | What the script does |
| --- | --- |
| `scripts/lib.sh` | Shared by the others (`source`d): loads `.env`, sets names, defines `pod_test`, `capture` and `check`. |
| `scripts/create-project.sh` | Creates the project, links billing, writes `lab.tfvars`. |
| `scripts/deploy.sh` | Terraform apply, cluster credentials, `kubectl apply -k`, first upload. |
| `scripts/prove.sh` | One PASS/FAIL line per check of steps 1 and 2. |
| `scripts/break-wrong-sa.sh`, `break-missing-role.sh`, `break-key.sh` | The three breaks; each captures the error. |
| `scripts/restore-role.sh`, `restore-key.sh` | The two fixes. |
| `scripts/triage-table.sh` | Renders the captured errors as the lesson's table. |
| `scripts/teardown.sh` | Destroys everything and deletes the project after you type its id. |

## 4. How it works underneath

- Bash starts a program as a new **process** and waits for it. Each process has an **exit status**, a number: `0` means success, anything else means failure. `$?` holds the last one.
- **Variables** hold text. `NAME=value` sets one; `"$NAME"` reads it. **Always put quotes around expansions**: without them Bash splits the text at spaces and expands `*`.
- `$(command)` runs a command and substitutes its output. `|` (a **pipe**) sends one program's output into the next program's input. `>file` writes output to a file; `>/dev/null` throws it away; `2>&1` sends error output where normal output goes.
- `source file` runs another file's lines in the *current* shell, so its variables and functions become available. That is how `lib.sh` works.
- `[[ ... ]]` is Bash's test: `-f path` (file exists), `-n text` (not empty), `==` (text equals; the right side can be a pattern).
- Environment variables are copied into child processes if they are **exported**. `set -a` makes every variable assigned afterwards exported automatically.

## 5. Walkthrough of this repository's use

### The shared header

`scripts/lib.sh`

```bash
#!/usr/bin/env bash
# Shared by the runbook scripts: loads .env and sets the variables the lesson uses in every command.
# shellcheck disable=SC2034  # the variables are used by the scripts that source this file
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$ROOT/infra/environments/lab"
CAPTURES="$ROOT/captures"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

: "${PROJECT_ID:?set PROJECT_ID in .env (see .env.example)}"
REGION="${REGION:-europe-west1}"
BUCKET="$PROJECT_ID-files"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
KEY="projects/$PROJECT_ID/locations/$REGION/keyRings/files/cryptoKeys/files-key"
# Use the project NUMBER here, never the project id: with the id the binding matches nothing.
PRINCIPAL="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/demo/sa/reader-writer"
```

- `#!/usr/bin/env bash` (the **shebang**) tells the system to run the file with Bash found on the PATH.
- `set -euo pipefail` makes the script strict. `-e`: stop at the first failing command. `-u`: using an unset variable is an error. `-o pipefail`: a pipe fails if *any* stage fails.
- `ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"`: `BASH_SOURCE[0]` is this file's path; `dirname` takes its folder; `/..` goes up to the repository root; `pwd` prints the absolute path. The script works from any current folder.
- `if [[ -f "$ROOT/.env" ]]; then set -a; source ...; set +a; fi` loads `.env` and exports its variables. The `# shellcheck disable=SC1091` comment tells the linter it cannot follow a file chosen at run time.
- `: "${PROJECT_ID:?...}"` stops with that message if the variable is empty. `${REGION:-europe-west1}` supplies a default.
- `PROJECT_NUMBER="$(gcloud projects describe ...)"` captures a command's output in a variable.
- `PRINCIPAL=...` builds the pod's IAM member from the number and the id.

### Run the lesson's test and keep the failure

`scripts/lib.sh`

```bash
# The lesson's test, run again after every change, from inside the pod. Prints the command's output and exit status.
pod_test() {
  local deployment="${1:-files}"
  kubectl -n demo exec "deploy/$deployment" -- sh -c "echo hello > /tmp/a.txt && gcloud storage cp /tmp/a.txt gs://$BUCKET/a.txt && gcloud storage cat gs://$BUCKET/a.txt"
}

# capture NAME [deployment]: run the test, keep the error text in captures/NAME.txt for `make triage`.
capture() {
  local name="$1" deployment="${2:-files}"
  mkdir -p "$CAPTURES"
  if pod_test "$deployment" >"$CAPTURES/$name.txt" 2>&1; then
    echo "the test passed; nothing to capture for $name"
    rm -f "${CAPTURES:?}/${name:?}.txt"
    return 1
  fi
  cat "$CAPTURES/$name.txt"
}
```

- `pod_test`: `local deployment="${1:-files}"` takes the first argument or `files`. `kubectl -n demo exec "deploy/$deployment" -- sh -c "..."` runs the lesson's upload-and-read command inside the pod.
- `capture NAME [deployment]`: `mkdir -p` creates the folder; `if pod_test ... >"$CAPTURES/$name.txt" 2>&1; then` runs the test with both output streams written to a file and branches on its exit status. If the test passed there is nothing to capture, so the file is removed; the `${CAPTURES:?}/${name:?}` form guarantees neither variable is empty when `rm` runs. If it failed, `cat` prints the saved text.

### The PASS/FAIL helper

`scripts/lib.sh`

```bash
check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $what"
  else
    echo "FAIL  $what"
    FAILED=1
  fi
}
FAILED=0
```

`check` takes a description, then `shift` removes that first argument so `"$@"` is the command to run, each word kept intact. `if "$@" >/dev/null 2>&1; then` runs it silently and branches on its exit status. `FAILED=1` records a failure; `prove.sh` ends with `exit "$FAILED"`.

### A script that proves requirements

`scripts/prove.sh`

```bash
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
```

- `bash -c "..."` runs a string as a small script, used here because `check` needs one command.
- `grep -q 'cryptoKeys/files-key'` is true when the pipe's text contains the key name.
- `test -z "$(...)"` passes when the command's output is empty: no `secrets` in the namespace; no key file in the pod.
- The `for sa in $(...)` loop asks for each service account's user-created keys and counts the lines with `wc -l`; `grep -qx 0` demands the count be exactly `0`.

### Waiting for a change to spread

`scripts/break-missing-role.sh`

```bash
gcloud storage buckets remove-iam-policy-binding "gs://$BUCKET" --member="$PRINCIPAL" --role=roles/storage.objectUser
echo "waiting 60 seconds for the removal to propagate"
sleep 60
capture missing-role files || true
"$ROOT/.venv/bin/gke-triage" classify "$CAPTURES/missing-role.txt"
```

`sleep 60` waits for the IAM change; `capture missing-role files || true` runs the test and keeps the failure but does not stop the script (`|| true` says "a failure here is expected"). Then the classifier explains the saved text.

### A heredoc that writes a file

`scripts/create-project.sh`

```bash
cat >"$ROOT/infra/environments/lab/lab.tfvars" <<VARS
project_id     = "$PROJECT_ID"
project_number = "$PROJECT_NUMBER"
region         = "$REGION"

master_authorized_cidrs = {
  laptop = "$MASTER_AUTHORIZED_CIDR"
}
VARS
echo "wrote infra/environments/lab/lab.tfvars"
```

A **here-document** (`<<VARS` ... `VARS`) feeds the lines between the markers to `cat`, which writes them to the file. Unquoted `VARS` means `$PROJECT_ID` and the other variables are replaced first.

### A guarded dangerous action

`scripts/teardown.sh`

```bash
read -r -p "Delete project $PROJECT_ID? Type the project id to confirm: " answer
[[ "$answer" == "$PROJECT_ID" ]] || { echo "not confirmed"; exit 1; }

kubectl delete -k "$ROOT/manifests/overlays/wrong-identity" --ignore-not-found || true
(cd "$ENV_DIR" && terraform destroy -var-file=lab.tfvars) || echo "terraform destroy did not finish; deleting the project removes the resources anyway"
gcloud projects delete "$PROJECT_ID" --quiet
```

`read -r -p "prompt" answer` waits for you to type; `-r` keeps backslashes literal. The `[[ ... ]] || { echo ...; exit 1; }` line exits unless you typed the exact project id. `|| echo "..."` after the Terraform destroy lets the script go on to delete the project even if the destroy did not finish.

## Every script, whole, in the order you run them

Words used in the scripts, explained once. A **comment** starts with `#`. The first line `#!/usr/bin/env bash` is the **shebang**: it tells the system which program runs the file. A script must be **executable** (`chmod +x`, already done) to be started as `scripts/deploy.sh`. A **variable in capitals** such as `ORG_ID` is by convention an environment variable or a constant. **Standard output** is where a program prints normal text, **standard error** is where it prints complaints (`>&2` sends text there). An **exit status** is the number a program returns: 0 means success.

Every script except `create-project.sh`, `prove.sh`-style helpers and `triage-table.sh` starts with `source "$(dirname "$0")/lib.sh"`. `$0` is the path the script was started with, `dirname` takes its folder, `$(...)` substitutes the result, and `source` runs `lib.sh` as if its lines were written here. The comment above it, `# shellcheck source=lib.sh`, tells the linter which file `source` loads.

### `scripts/lib.sh`

`scripts/lib.sh`

```bash
#!/usr/bin/env bash
# Shared by the runbook scripts: loads .env and sets the variables the lesson uses in every command.
# shellcheck disable=SC2034  # the variables are used by the scripts that source this file
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_DIR="$ROOT/infra/environments/lab"
CAPTURES="$ROOT/captures"

if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi

: "${PROJECT_ID:?set PROJECT_ID in .env (see .env.example)}"
REGION="${REGION:-europe-west1}"
BUCKET="$PROJECT_ID-files"
gcloud config set project "$PROJECT_ID" --quiet >/dev/null
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"
KEY="projects/$PROJECT_ID/locations/$REGION/keyRings/files/cryptoKeys/files-key"
# Use the project NUMBER here, never the project id: with the id the binding matches nothing.
PRINCIPAL="principal://iam.googleapis.com/projects/$PROJECT_NUMBER/locations/global/workloadIdentityPools/$PROJECT_ID.svc.id.goog/subject/ns/demo/sa/reader-writer"

# The lesson's test, run again after every change, from inside the pod. Prints the command's output and exit status.
pod_test() {
  local deployment="${1:-files}"
  kubectl -n demo exec "deploy/$deployment" -- sh -c "echo hello > /tmp/a.txt && gcloud storage cp /tmp/a.txt gs://$BUCKET/a.txt && gcloud storage cat gs://$BUCKET/a.txt"
}

# capture NAME [deployment]: run the test, keep the error text in captures/NAME.txt for `make triage`.
capture() {
  local name="$1" deployment="${2:-files}"
  mkdir -p "$CAPTURES"
  if pod_test "$deployment" >"$CAPTURES/$name.txt" 2>&1; then
    echo "the test passed; nothing to capture for $name"
    rm -f "${CAPTURES:?}/${name:?}.txt"
    return 1
  fi
  cat "$CAPTURES/$name.txt"
}

check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo "PASS  $what"
  else
    echo "FAIL  $what"
    FAILED=1
  fi
}
FAILED=0
```

The header lines, the PASS/FAIL helper and the `${VAR:?}` idiom were explained above. In addition: `gcloud config set project "$PROJECT_ID" --quiet >/dev/null` makes every later `gcloud` call use the lab project without asking; `BUCKET="$PROJECT_ID-files"` and `KEY=...` build the lesson's names; `PRINCIPAL=...` builds the pod's IAM member from the project **number** (the comment says why). `pod_test` runs the lesson's upload-and-read command inside the pod with `kubectl exec` (`deploy/NAME` picks a pod of that deployment, `--` separates kubectl's own flags from the command, `sh -c "..."` runs a string in the pod's shell). `capture` runs it, saves the output in `captures/NAME.txt` (`>file 2>&1` sends both output streams to the file) and returns 1 when the test passed because there is then nothing to capture. `local` makes a variable private to the function; `"${2:-files}"` is the second argument or `files`.

### `scripts/create-project.sh`

`scripts/create-project.sh`

```bash
#!/usr/bin/env bash
# Creates the project, links billing and writes the Terraform variables file. Delete everything the same day.
# Needs PROJECT_ID, BILLING_ACCOUNT and MASTER_AUTHORIZED_CIDR (your address as a /32) in .env.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$ROOT/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT/.env"
  set +a
fi
: "${PROJECT_ID:?set PROJECT_ID in .env}"
: "${BILLING_ACCOUNT:?set BILLING_ACCOUNT in .env (gcloud billing accounts list)}"
: "${MASTER_AUTHORIZED_CIDR:?set MASTER_AUTHORIZED_CIDR in .env: your public address as a /32}"
REGION="${REGION:-europe-west1}"

gcloud projects create "$PROJECT_ID" ${ORG_ID:+--organization="$ORG_ID"} --labels=purpose=lab
gcloud billing projects link "$PROJECT_ID" --billing-account="$BILLING_ACCOUNT"
PROJECT_NUMBER="$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')"

cat >"$ROOT/infra/environments/lab/lab.tfvars" <<VARS
project_id     = "$PROJECT_ID"
project_number = "$PROJECT_NUMBER"
region         = "$REGION"

master_authorized_cidrs = {
  laptop = "$MASTER_AUTHORIZED_CIDR"
}
VARS
echo "wrote infra/environments/lab/lab.tfvars"
```

It does not source `lib.sh` because `lib.sh` needs a project that does not exist yet; it repeats the small `.env` loading instead. `${ORG_ID:+--organization="$ORG_ID"}` expands to the flag only when `ORG_ID` is set (`:+` means "use this if the variable is non-empty"). The project number is read back with `--format='value(projectNumber)'`. The **here-document** `<<VARS ... VARS` writes the file `lab.tfvars` with the values substituted.

### `scripts/deploy.sh`

`scripts/deploy.sh`

```bash
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
```

`cd "$ENV_DIR" || exit 1`, `terraform init`, `terraform apply -var-file=lab.tfvars` build the infrastructure. `gcloud container clusters get-credentials demo --region=...` writes the cluster's address and login method into your kubeconfig file so `kubectl` can talk to it. `kubectl apply -k DIR` applies a Kustomize folder (`kustomize.md`); `kubectl rollout status deploy/files --timeout=300s` waits until the pod is ready. `echo hi | gcloud storage cp - gs://...` uploads the text from standard input (`-`). The last line prints which key encrypted the object.

### `scripts/prove.sh`

`scripts/prove.sh`

```bash
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
```

Each `check "what is proved" command...` prints PASS or FAIL. `grep -q` succeeds if a pattern is found; `test -z "$(...)"` succeeds if the output is empty; the `get-iam-policy --flatten='bindings[].members' --filter=... --format='value(...)'` lines turn the bucket's policy into one line per member and keep the ones asked for. `bash -c "..."` runs a string as a small script because `check` needs one command; `\$` and `\"` keep characters for the inner shell. The last command prints the identity the audit log recorded (`|| true` ignores its failure) and `exit "$FAILED"` reports the verdict.

### `scripts/break-wrong-sa.sh`: step 3

`scripts/break-wrong-sa.sh`

```bash
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
```

Applies the wrong-identity overlay (a second deployment without a service account name), waits for it, runs the lesson's test in it and keeps the error, waits 30 seconds, reads the denial from Cloud Logging into a JSON file (`--format=json`, `status.code=7`), and asks the Python tool to summarize it (`audit`) and classify the text (`classify`). `|| true` after a command says "a failure here is expected, keep going". The backslash before a quote inside the double-quoted filter keeps the quote as part of the filter text.

### `scripts/break-missing-role.sh`: step 4

`scripts/break-missing-role.sh`

```bash
#!/usr/bin/env bash
# Step 4: remove the bucket role from the correct identity. Do not restart the pod: the next request already fails.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

gcloud storage buckets remove-iam-policy-binding "gs://$BUCKET" --member="$PRINCIPAL" --role=roles/storage.objectUser
echo "waiting 60 seconds for the removal to propagate"
sleep 60
capture missing-role files || true
"$ROOT/.venv/bin/gke-triage" classify "$CAPTURES/missing-role.txt"
```

Removes exactly one binding with `gcloud storage buckets remove-iam-policy-binding`, waits 60 seconds (there is no signal to poll), captures the failure, classifies it. The comment reminds you not to restart the pod: IAM is checked on every request.

### `scripts/restore-role.sh`: step 4's fix

`scripts/restore-role.sh`

```bash
#!/usr/bin/env bash
# Step 4, the fix: put the role back. The test passes again with no restart. (Terraform owns the binding; this puts it back by hand.)
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

gcloud storage buckets add-iam-policy-binding "gs://$BUCKET" --member="$PRINCIPAL" --role=roles/storage.objectUser
echo "waiting 60 seconds for the grant to propagate"
sleep 60
pod_test files
kubectl -n demo get pods -l app=files   # RESTARTS is still 0: no restart was needed
```

Adds the binding back, waits, runs the test again, and lists the pods: the `RESTARTS` column is still `0`.

### `scripts/break-key.sh`: step 5

`scripts/break-key.sh`

```bash
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
```

Lists the key's versions, disables version 1 (`disable`, never `destroy`), waits, then reads an object that was written earlier. `if command >file 2>&1; then ... else ... fi` runs the read, saving its output, and branches on its exit status: success means the key change has not spread yet; failure prints the saved error and classifies it.

### `scripts/restore-key.sh`: step 5's fix

`scripts/restore-key.sh`

```bash
#!/usr/bin/env bash
# Step 5, the fix: enable the version again. Access returns within a minute or two.
# shellcheck source=lib.sh
source "$(dirname "$0")/lib.sh"

gcloud kms keys versions enable 1 --key=files-key --keyring=files --location="$REGION"
sleep 60
kubectl -n demo exec deploy/files -- gcloud storage cat "gs://$BUCKET/first.txt"
```

### `scripts/triage-table.sh`: step 6

`scripts/triage-table.sh`

```bash
#!/usr/bin/env bash
# Step 6: the triage table from the error texts the break scripts captured. Copy the output into your README.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/.venv/bin/gke-triage" table "$ROOT/captures"
```

Sets its own `set -euo pipefail` and `ROOT` (it does not need the cloud, so it skips `lib.sh`) and prints the table from the saved captures.

### `scripts/teardown.sh`: step 6

`scripts/teardown.sh`

```bash
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
```

The typed project id is the confirmation. `kubectl delete -k ... --ignore-not-found || true` removes the extra deployment; `(cd "$ENV_DIR" && terraform destroy ...)` runs in a subshell so the `cd` does not leak, and `|| echo "..."` lets the script go on to delete the project even if the destroy did not finish. The last line prints the project's state, `DELETE_REQUESTED`.

## 6. Try it yourself

```bash
bash -n scripts/lib.sh && echo "syntax ok"
```
Expected: `syntax ok` (`-n` parses without running).

```bash
shellcheck scripts/*.sh && echo clean
```
Expected: `clean`.

```bash
bash -c 'set -euo pipefail; echo before; false; echo after'; echo "exit=$?"
```
Expected: `before` then `exit=1`. `after` never prints, which is what `-e` does.

```bash
bash -c 'x=; : "${x:?x must be set}"' ; echo "exit=$?"
```
Expected: the message `x: x must be set` and a non-zero exit status (`exit=127` in Bash 5; the exact number differs between shells).

```bash
bash -c 'check() { local w="$1"; shift; if "$@" >/dev/null 2>&1; then echo "PASS  $w"; else echo "FAIL  $w"; fi; }; check "a file exists" test -f Makefile; check "no such file" test -f nope'
```
Expected: `PASS  a file exists` then `FAIL  no such file`.

## 7. Mistakes people make

- **Unquoted variables** (`rm $DIR/*`) split on spaces and can delete the wrong thing. Quote everything.
- **No `set -euo pipefail`.** Scripts keep going after an error and report success.
- **Using `cd` without checking it worked.** Scripts here use `cd ... || exit 1`.
- **Parsing `ls` output.** Use globs and loops.
- **Putting secrets on the command line.** They show up in process lists. Secrets here travel in environment variables or files.
- **Relying on the current folder.** `lib.sh` computes `ROOT` from the script's own path.

## 8. Check yourself

1. What does `set -e` do? *Stops the script at the first failing command.*
2. What does `"$@"` mean in `check`? *All remaining arguments, each kept as one word.*
3. What does `${VAR:?msg}` do? *Stops with `msg` if `VAR` is empty or unset.*
4. What does `source lib.sh` do differently from running `./lib.sh`? *It runs in the current shell, so variables and functions stay available.*
5. What does `curl -o /dev/null -w '%{http_code}'` print? *Only the HTTP status code.*

## 9. Further reading

- GNU Bash manual (Bash 5.2; the scripts also run on macOS's 3.2): <https://www.gnu.org/software/bash/manual/bash.html>
- Shell parameter expansion (`:?`, `:-`): <https://www.gnu.org/software/bash/manual/bash.html#Shell-Parameter-Expansion>
- The set builtin (`-e`, `-u`, `pipefail`): <https://www.gnu.org/software/bash/manual/bash.html#The-Set-Builtin>
- ShellCheck wiki: <https://www.shellcheck.net/wiki/>
