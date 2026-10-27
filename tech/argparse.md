# argparse

## 1. What it is

`argparse` is Python's standard module for building command-line programs. You describe the words and flags your program accepts (`gke-triage classify FILE`, `--project-id ID`); `argparse` reads `sys.argv` (the list of words typed after the program name), checks them, converts them, fills in defaults, prints `--help` for free, and reports mistakes with a usage message and exit status 2.

## 2. Why this repository uses it

`gke-triage` is a command with several actions: `classify`, `audit`, `table`, `principal`, `check-binding`. Each action is a **subcommand** with its own arguments, which is what `argparse` subparsers are for.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `src/gke_triage/interfaces/cli.py` | `_parser()` builds the parser; `main()` runs it. |
| `pyproject.toml` | `[project.scripts] gke-triage = "gke_triage.interfaces.cli:main"` makes `pip` install a `gke-triage` command that calls `main`. |
| `tests/unit/interfaces/test_cli.py`, `tests/e2e/test_cli_process.py` | Call `main([...])` and the real program as a subprocess. |

## 4. How it works underneath

`ArgumentParser.parse_args(argv)` walks the words. A word that names a subcommand switches to that subcommand's parser. Positional arguments (`file`) are matched in order; options (`--namespace demo`) by name. The result is a `Namespace` object with one attribute per argument. If a required argument is missing or a flag is unknown, `argparse` prints usage and **exits** (by raising `SystemExit(2)`).

## 5. Walkthrough of this repository's use

`src/gke_triage/interfaces/cli.py`

```python
def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="gke-triage", description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    classify = commands.add_parser(
        "classify", help="classify the error text in FILE (or stdin) as identity, authorization or key"
    )
    classify.add_argument("file", nargs="?", default="-")
    classify.set_defaults(handler=_classify)

    audit = commands.add_parser("audit", help="summarize denials in the JSON from `gcloud logging read --format=json`")
    audit.add_argument("file", nargs="?", default="-")
    audit.set_defaults(handler=_audit)

    table = commands.add_parser("table", help="render the triage table from the *.txt files in DIRECTORY")
    table.add_argument("directory", nargs="?", default="captures")
    table.set_defaults(handler=_table)

    principal = commands.add_parser("principal", help="print the IAM principal of a Kubernetes service account")
    principal.add_argument("--project-id", required=True)
    principal.add_argument("--project-number", required=True)
    principal.add_argument("--namespace", default="demo")
    principal.add_argument("--service-account", default="reader-writer")
    principal.set_defaults(handler=_principal)

    check = commands.add_parser(
        "check-binding", help="check that a binding's member uses the project number, not the id"
    )
    check.add_argument("member")
    check.add_argument("--project-id", required=True)
    check.add_argument("--project-number", required=True)
    check.set_defaults(handler=_check_binding)
    return parser
```

- `argparse.ArgumentParser(prog="gke-triage", description=__doc__)` names the program; `__doc__` is the module's docstring, shown in `--help`.
- `commands = parser.add_subparsers(dest="command", required=True)`: the first word after the program name must be one of the subcommands, and `required=True` makes a missing one an error.
- `classify = commands.add_parser("classify", help=...)` adds one subcommand. `classify.add_argument("file", nargs="?", default="-")`: a positional argument that is optional (`?`); the default `-` means "read standard input".
- `principal.add_argument("--project-id", required=True)`: a named option that must be given. Dashes become underscores on the result (`args.project_id`).
- `--namespace` and `--service-account` have defaults (`demo`, `reader-writer`), so they can be left out.
- `classify.set_defaults(handler=_classify)` stores the function to call on the result. `main` then runs `args.handler(args)`, so there is no long `if command == ...` chain.

Reading input and exit status:

`src/gke_triage/interfaces/cli.py`

```python
def main(argv: Sequence[str] | None = None) -> int:
    """Run the command; returns the process exit status (0 ok, 1 a problem was found, 2 bad input)."""
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except (DomainError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2
```

The program returns `0` for success, `1` when it found a problem worth failing a script (`audit` found denials, `check-binding` found a mistake), and `2` for unusable input.

## 6. Try it yourself

```bash
.venv/bin/gke-triage --help
```
Expected: usage with the five subcommands `classify,audit,table,principal,check-binding`.

```bash
.venv/bin/gke-triage principal --project-id example-sandbox-0000 --project-number 123456789012
```
Expected: `principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer`

```bash
.venv/bin/gke-triage principal --project-id example-sandbox-0000; echo "exit=$?"
```
Expected: a `usage: gke-triage principal ...` block, then `gke-triage principal: error: the following arguments are required: --project-number`, and `exit=2`.

```bash
.venv/bin/gke-triage classify tests/fixtures/wrong-service-account.txt | head -3
```
Expected: `layer:       authorization`, `cause:       default service account`, then the principal.

## 7. Mistakes people make

- **Reading `sys.argv` by hand.** You lose help text and error messages.
- **Printing errors and returning 0.** Scripts then cannot tell failure from success.
- **Forgetting that exits happen inside `parse_args`.** Tests catch `SystemExit` (`test_a_subcommand_is_required`).
- **Long if/else chains for subcommands.** `set_defaults(handler=...)` is cleaner.

## 8. Check yourself

1. What does `required=True` on `add_subparsers` do? *A missing subcommand is an error.*
2. What does `nargs="?"` mean? *The argument is optional.*
3. How does `--project-id` appear on the result? *As `args.project_id`.*
4. What exit status does `argparse` use for bad usage? *2.*
5. How does `pip` create the `gke-triage` command? *From `[project.scripts]`, pointing at `main`.*

## 9. Further reading

- `argparse`: <https://docs.python.org/3.12/library/argparse.html>
- Argparse tutorial: <https://docs.python.org/3.12/howto/argparse.html>
- Entry points: <https://packaging.python.org/en/latest/specifications/entry-points/>
