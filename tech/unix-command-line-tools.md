# Small command-line tools used by the scripts: grep, sed, sort, wc, tee, find, cat, mkdir, sleep, test

## 1. What it is

These are small programs that ship with macOS and Linux, each doing one job; the shell connects them. **grep** finds lines that match a pattern. **sed** edits text as it flows through. **sort** orders lines. **wc** counts lines or words. **tee** copies its input to a file and to the screen. **find** searches folders. **cat** prints files. **mkdir** makes folders. **sleep** waits. **test** (also written `[ ... ]`) checks a condition and sets the exit status.

## 2. Why this repository uses it

The Makefile and the runbook scripts stay short by combining these tools: list the make targets, count keys, wait for a permission change to spread, save the triage table while showing it.

## 3. Where it appears

| Path | Tool and use |
| --- | --- |
| `Makefile` (`help`) | `grep`, `sed` and `sort` build the target list. |
| `Makefile` (`triage`) | `tee` writes the table to a file and prints it. |
| `Makefile` (`clean`) | `find infra -name .terraform -type d -prune -exec rm -rf {} +`. |
| `scripts/prove.sh` | `grep -q`, `wc -l`, `test -z`. |
| `scripts/break-*.sh`, `restore-*.sh` | `sleep 60` waits for IAM and key changes. |
| `scripts/lib.sh` | `mkdir -p`, `cat` the saved error text. |

## 4. How it works underneath

Each tool reads **standard input** (text piped in), writes **standard output**, and returns an **exit status** (0 for success; `grep` returns 1 when nothing matched). That is why they combine: `cmd1 | cmd2` sends the output of the first into the second.

## 5. Walkthrough of this repository's use

`Makefile`

```make
help: ## list the targets
	@grep -E '^[a-z0-9-]+:.*## ' $(MAKEFILE_LIST) | sed -E 's/:.*## /\t/' | sort
```

- `grep -E '^[a-z0-9-]+:.*## ' FILES` keeps lines that start with a target name, a colon, anything, then `## `. `-E` enables extended patterns.
- `sed -E 's/:.*## /\t/'` replaces the text from the first colon through `## ` with a tab. `s/old/new/` is substitute.
- `sort` orders the lines alphabetically.

`Makefile`

```make
triage: $(STAMP) ## render the triage table from captures/*.txt (written by the break scripts)
	$(VENV)/bin/gke-triage table captures | tee docs/triage-table.generated.md
```

`gke-triage table captures | tee docs/triage-table.generated.md` prints the table and also saves it.

`Makefile`

```make
clean:
	rm -rf $(VENV) .pytest_cache .mypy_cache .ruff_cache .coverage .import_linter_cache
	find infra -name .terraform -type d -prune -exec rm -rf {} +
```

`find infra -name .terraform -type d -prune -exec rm -rf {} +` finds directories named `.terraform` under `infra`, does not descend into them (`-prune`), and removes them. The `{} +` passes many found paths to one `rm`.

`scripts/prove.sh`

```bash
check "no key file exists in the pod" bash -c "! kubectl -n demo exec deploy/files -- sh -c 'ls /tmp/*.json /var/run/secrets 2>/dev/null' | grep -q ."
check "no key was ever created for any service account in the project" \
```

- `! kubectl ... | grep -q .` — the `!` negates the result: the check passes when `grep` finds *no* output line. `grep -q .` succeeds if there is at least one character.
- `... | wc -l | grep -qx 0` counts lines and requires the count to be exactly `0` (`-x` matches the whole line).

## 6. Try it yourself

```bash
printf 'a\nb\n' | grep -c b
```
Expected: `1`.

```bash
echo 'build: ## compile' | sed -E 's/:.*## /\t/'
```
Expected: `build<TAB>compile` (a tab between the words).

```bash
printf 'b\na\n' | sort
```
Expected: `a` then `b`.

```bash
printf 'x\ny\n' | wc -l
```
Expected: `2` (macOS may pad it with spaces).

```bash
echo hello | tee /tmp/tee-demo.txt && cat /tmp/tee-demo.txt && rm -f /tmp/tee-demo.txt
```
Expected: `hello` printed twice (once by `tee`, once by `cat`).

```bash
test -z "" && echo "empty"
```
Expected: `empty`.

## 7. Mistakes people make

- **`grep` returning 1 and `set -e` stopping the script.** In a condition that is intended; elsewhere add `|| true` deliberately.
- **`sed -i` differs between macOS and Linux.** On macOS `sed -i ''` is required.
- **`rm -rf $VAR/...` with an empty variable.** The scripts use `${VAR:?}`.
- **Forgetting `-p` on `mkdir`.** It fails if the folder exists.
- **Using `sleep` instead of checking.** Here it is only a pause for IAM and key changes, which have no completion signal to poll.

## 8. Check yourself

1. What does `grep -q` print? *Nothing; only the exit status.*
2. What does `tee` do? *Copies input to a file and to the screen.*
3. What does `-prune` do in `find`? *Does not descend into matched directories.*
4. What does `test -z "$x"` check? *That the text is empty.*
5. Why `${VAR:?}` before `rm`? *To stop if the variable is empty.*

## 9. Further reading

- GNU grep: <https://www.gnu.org/software/grep/manual/grep.html>
- GNU sed: <https://www.gnu.org/software/sed/manual/sed.html>
- GNU findutils: <https://www.gnu.org/software/findutils/manual/html_mono/find.html>
- GNU coreutils (sort, wc, tee, cat, test): <https://www.gnu.org/software/coreutils/manual/coreutils.html>
