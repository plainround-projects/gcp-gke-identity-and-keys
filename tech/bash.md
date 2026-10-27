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
