# pytest (and coverage)

## 1. What it is

pytest is a Python **test runner**. A **test** is a small function that calls your code and checks the result; if a check fails, the test fails. pytest finds files named `test_*.py`, runs every function whose name starts with `test_`, and prints a summary. A plain `assert` statement is the check. **Coverage** measures which lines of your code the tests actually ran; the `pytest-cov` plug-in adds it to pytest. Versions are pinned in `requirements-dev.lock`.

## 2. Why this repository uses it

Tests are how the repository proves its rules without a cloud account: the validation rules, the error handling and the wiring all run in a few seconds. The README's "Done when" table points at them.

## 3. Where it appears

| Path | What it does with pytest |
| --- | --- |
| `tests/unit/` | Fast tests with no network: domain, application (with fakes), adapters, web or command-line layers, and checks on the infrastructure files. |
| `tests/e2e/` | The program as a user runs it: a subprocess over the lesson's error texts (marker `e2e`; no Docker needed). |
| `tests/conftest.py` | Shared **fixtures** (setup helpers) used by many tests. |
| `pyproject.toml` | `[tool.pytest.ini_options]` and `[tool.coverage.*]`. |
| `Makefile` | `make test-python` runs unit tests with coverage and fails below 95% on the domain and application layers. |
| `.github/workflows/ci.yml` | Runs the same make target on every push. |

## 4. How it works underneath

pytest imports each test file, collects the test functions, and calls them one by one. When it sees `assert a == b` it rewrites the assertion at import time so that a failure shows both values. A **fixture** is a function marked `@pytest.fixture`; a test that lists its name as a parameter receives its return value. `@pytest.mark.parametrize("x", [1, 2, 3])` runs one test function once per value. **Markers** are labels such as `e2e` that let you select tests (`-m e2e`). `monkeypatch` and `caplog` are built-in fixtures: the first changes environment variables or attributes for one test and undoes the change; the second captures log records.

Coverage works by watching which lines run. With `branch = true` it also notes whether each `if` took both ways.

## 5. Walkthrough of this repository's use

`pyproject.toml`

```toml
[tool.pytest.ini_options]
testpaths = ["tests"]
addopts = "-ra --strict-markers"
markers = [
    "e2e: runs the command-line program as a subprocess against the fixtures",
]
```

- `testpaths = ["tests"]`: where to look when you run plain `pytest`.
- `addopts = "-ra --strict-markers"`: `-ra` prints a summary of everything that was not a plain pass; `--strict-markers` turns an unknown marker (a typo) into an error.
- `markers = [...]` declares the allowed markers and explains them.

`pyproject.toml`

```toml
[tool.coverage.run]
source = ["gke_triage"]
branch = true

[tool.coverage.report]
show_missing = true

[tool.importlinter]
```

- `source = ["gke_triage"]` limits measuring to this package.
- `branch = true` measures branches as well as lines.
- `show_missing = true` lists the line numbers that no test reached.

The make target:

`Makefile`

```make
test-python: $(STAMP)
	$(PY) -m pytest tests/unit --cov=gke_triage --cov-report=term
	$(PY) -m coverage report --include='src/gke_triage/domain/*,src/gke_triage/application/*' --fail-under=95
```

`--cov=gke_triage --cov-report=term` prints a coverage table; the second command (`coverage report ... --fail-under=95`) fails the build if the domain and application layers drop below 95%, which keeps the core fully tested.

### An example test

`tests/unit/domain/test_triage.py`

```python
def test_the_default_service_account_authenticated_but_was_not_authorized():
    result = finding("wrong-service-account")
    assert (result.layer, result.cause) == (Layer.AUTHORIZATION, Cause.DEFAULT_SERVICE_ACCOUNT)
    assert result.principal is not None
    assert result.principal.endswith("/sa/default")
    assert result.permission == "storage.objects.create"
```

The fixture files under `tests/fixtures/` hold the lesson's real error texts. The helper `finding(name)` reads one and calls the classifier. The test checks the layer, the cause, the principal (it must end in `/sa/default`) and the permission. It needs no cluster and no cloud account, and its name states the behavior: authenticated, then not authorized.

## Every test file, and what each test proves

The basics first, as they appear in every file below.

- A **test** is a function whose name starts with `test_`. pytest finds it, calls it, and reports a pass if it returns normally and a failure if it raises an exception.
- `assert expression` raises `AssertionError` when the expression is false. pytest shows both sides of a failed comparison.
- A **fixture** is a helper marked `@pytest.fixture` whose result pytest passes to any test that names it as a parameter. These tests use pytest's built-in fixtures: `tmp_path` (a new empty folder for this test only), `capsys` (captures what the program prints, standard output and standard error) and `monkeypatch` (temporarily replaces something, undone after the test).
- `@pytest.mark.parametrize` runs one test function several times with different inputs, each run reported separately.
- `with pytest.raises(SomeError, match="text"):` passes only if the code inside raises that exception and its message matches `text` (a regular expression).
- `FIXTURES` (in several files) is the folder `tests/fixtures/`, found from the file's own path: `Path(__file__).resolve().parents[2] / "fixtures"` goes up from `tests/unit/domain/` to `tests/`. A **fixture file** is test data: here, the exact error texts of the lesson.

### The fixture files (`tests/fixtures/`)

Six error texts, one per kind of failure, and one audit-log export. They are the lesson's real messages (with the example project id and number), so the tests prove the rules work on the texts a learner will actually see.

`tests/fixtures/unknown.txt`

```text
ERROR: (gcloud.storage.ls) something nobody planned for happened
```

`unknown.txt` is a failure the rules should not recognize: the classifier must say so honestly. The others are `wrong-service-account.txt` (the pod ran as `sa/default` and lacks `storage.objects.create`), `missing-role.txt` (the right account lost `storage.objects.get`), `key-disabled.txt` (the key is disabled), `key-access-denied.txt` (the bucket cannot use its key: `Permission 'cloudkms...useToEncrypt' denied`) and `no-credentials.txt` (default credentials were not found). Each begins with `ERROR: (gcloud.storage.cp)` or `cat`, which is how `gcloud` prefixes its errors.

### `tests/unit/domain/test_audit.py`

`tests/unit/domain/test_audit.py`

```python
import pytest

from gke_triage.domain.audit import is_denial


@pytest.mark.parametrize(
    ("status", "granted", "expected"),
    [(7, None, True), (None, False, True), (0, True, False), (None, None, False), (7, True, True)],
)
def test_a_call_is_denied_when_not_granted_or_permission_denied(status, granted, expected):
    assert is_denial(status, granted) is expected
```

- One parametrized test, five cases of `(status, granted, expected)`: status 7 with no authorization answer is a denial; `granted=False` with no status is a denial; status 0 and granted is not; both missing is not (unknown is not a denial); status 7 wins even when `granted` is true. `is expected` compares with `True` or `False` exactly.

### `tests/unit/domain/test_triage.py`

`tests/unit/domain/test_triage.py`

```python
from pathlib import Path

import pytest

from gke_triage.domain.triage import Cause, Layer, classify

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"


def finding(name):
    return classify((FIXTURES / f"{name}.txt").read_text())


def test_the_default_service_account_authenticated_but_was_not_authorized():
    result = finding("wrong-service-account")
    assert (result.layer, result.cause) == (Layer.AUTHORIZATION, Cause.DEFAULT_SERVICE_ACCOUNT)
    assert result.principal is not None
    assert result.principal.endswith("/sa/default")
    assert result.permission == "storage.objects.create"


def test_a_removed_role_names_the_missing_permission_and_points_at_the_bucket_policy():
    result = finding("missing-role")
    assert (result.layer, result.cause) == (Layer.AUTHORIZATION, Cause.MISSING_ROLE)
    assert result.permission == "storage.objects.get"
    assert result.principal is not None
    assert result.principal.endswith("/sa/reader-writer")
    assert "get-iam-policy" in result.first_check


def test_a_disabled_key_is_a_key_failure_not_an_iam_failure():
    result = finding("key-disabled")
    assert (result.layer, result.cause) == (Layer.KEY, Cause.KEY_DISABLED)
    assert result.principal is None
    assert "kms keys versions list" in result.first_check


def test_the_service_agent_missing_the_key_role_is_also_a_key_failure():
    result = finding("key-access-denied")
    assert (result.layer, result.cause) == (Layer.KEY, Cause.KEY_ACCESS_DENIED)
    assert result.permission == "cloudkms.cryptoKeyVersions.useToEncrypt"


def test_missing_credentials_are_an_identity_failure():
    assert (finding("no-credentials").layer, finding("no-credentials").cause) == (Layer.IDENTITY, Cause.NO_CREDENTIALS)


def test_anything_else_is_unknown_and_says_so():
    result = finding("unknown")
    assert (result.layer, result.cause) == (Layer.UNKNOWN, Cause.UNRECOGNIZED)


def test_the_evidence_is_the_first_non_empty_line():
    assert classify("\n\n  first line  \nsecond").evidence == "first line"
    assert classify("").evidence == ""


@pytest.mark.parametrize("word", ["destroyed", "scheduled for destruction"])
def test_other_key_states_are_key_failures(word):
    assert (
        classify(f"HTTPError 403: Cloud KMS key projects/p/locations/l/keyRings/r/cryptoKeys/k is {word}").layer
        is Layer.KEY
    )
```

- `finding(name)` reads `tests/fixtures/NAME.txt` and classifies it.
- Test one: the default-account text is `AUTHORIZATION` / `DEFAULT_SERVICE_ACCOUNT`; the principal ends with `/sa/default` and the permission is `storage.objects.create`. The tuple comparison `(a, b) == (c, d)` checks two things in one assert. The line `assert result.principal is not None` first proves there is a principal so the next line can call a method on it (and keeps `mypy` satisfied).
- Test two: the removed role names `storage.objects.get`, the principal ends with `/sa/reader-writer`, and the first check mentions `get-iam-policy`.
- Test three: a disabled key is a key failure and has no principal. Test four: a missing key role for the service agent is also a key failure, with the permission `cloudkms.cryptoKeyVersions.useToEncrypt`.
- Test five: no credentials is an identity failure. Test six: an unrecognized text is `UNKNOWN` / `UNRECOGNIZED`.
- Test seven: the evidence is the first non-empty line (`"\n\n  first line  \nsecond"` gives `first line`) and `classify("")` gives an empty evidence.
- Test eight (parametrized): the words `destroyed` and `scheduled for destruction` in a key message are key failures too.

### `tests/unit/domain/test_principal.py`

`tests/unit/domain/test_principal.py`

```python
import pytest

from gke_triage.domain.errors import InvalidPrincipal
from gke_triage.domain.principal import BindingProblem, WorkloadPrincipal, check_binding_member

# The same literal appears in infra/environments/lab/tests/principal.tftest.hcl: Python and Terraform must agree.
EXPECTED = (
    "principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/"
    "example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer"
)


def principal(**overrides):
    values = {
        "project_id": "example-sandbox-0000",
        "project_number": "123456789012",
        "namespace": "demo",
        "service_account": "reader-writer",
    }
    return WorkloadPrincipal(**{**values, **overrides})


def test_the_uri_is_built_from_the_project_number_the_pool_and_the_subject():
    assert principal().uri == EXPECTED


def test_the_project_id_where_the_number_belongs_is_rejected_with_the_fix():
    with pytest.raises(InvalidPrincipal, match=r"digits only.*projectNumber"):
        principal(project_number="example-sandbox-0000")


@pytest.mark.parametrize(
    "overrides",
    [
        {"project_id": "Bad_ID"},
        {"namespace": "Demo"},
        {"service_account": "has space"},
        {"namespace": ""},
        {"project_number": ""},
    ],
)
def test_other_invalid_parts_are_rejected(overrides):
    with pytest.raises(InvalidPrincipal):
        principal(**overrides)


def test_a_correct_binding_member_has_no_problem():
    assert check_binding_member(EXPECTED, "example-sandbox-0000", "123456789012") is None


def test_the_project_id_in_place_of_the_number_is_the_common_mistake():
    wrong = EXPECTED.replace("projects/123456789012", "projects/example-sandbox-0000")
    assert (
        check_binding_member(wrong, "example-sandbox-0000", "123456789012")
        is BindingProblem.PROJECT_ID_WHERE_NUMBER_BELONGS
    )


def test_a_member_of_another_projects_pool_is_flagged():
    other = EXPECTED.replace("123456789012", "999999999999")
    assert check_binding_member(other, "example-sandbox-0000", "123456789012") is BindingProblem.POOL_OF_ANOTHER_PROJECT


@pytest.mark.parametrize(
    "member", ["serviceAccount:a@b.iam.gserviceaccount.com", "", "principal://iam.googleapis.com/x"]
)
def test_anything_else_is_not_a_workload_principal(member):
    assert (
        check_binding_member(member, "example-sandbox-0000", "123456789012") is BindingProblem.NOT_A_WORKLOAD_PRINCIPAL
    )
```

- `EXPECTED` is the exact principal text. The comment says the same literal appears in the Terraform test, so Python and Terraform must agree (see `terraform-test.md`).
- `principal(**overrides)` builds a valid `WorkloadPrincipal` and replaces the fields you name: `{**values, **overrides}` merges two dictionaries.
- Tests: the URI is built from the number, the pool and the subject; a project id in place of the number is rejected with a message matching `digits only.*projectNumber` (the `r"..."` raw string is a regular expression: `.*` is "anything"); five bad parts are each rejected (parametrized); a correct member has no problem; the project id in place of the number is `PROJECT_ID_WHERE_NUMBER_BELONGS`; another project's number is `POOL_OF_ANOTHER_PROJECT`; three non-principal texts (a service account email, an empty string, a truncated principal) are `NOT_A_WORKLOAD_PRINCIPAL`.

### `tests/unit/application/test_diagnose.py`

`tests/unit/application/test_diagnose.py`

```python
from collections.abc import Sequence

from gke_triage.application.diagnose import BuildTriageTable, SummarizeDenials, diagnose
from gke_triage.application.ports import Capture
from gke_triage.domain.audit import AuditDenial
from gke_triage.domain.triage import Layer


class FakeLog:
    def __init__(self, denials: Sequence[AuditDenial]) -> None:
        self._denials = denials

    def denials(self):
        return self._denials


class FakeCaptures:
    def __init__(self, captures):
        self._captures = captures

    def captures(self):
        return self._captures


def denial(principal="p/default", permission="storage.objects.create", resource="r"):
    return AuditDenial(principal, permission, resource, "storage.objects.create", "t")


def test_diagnose_returns_the_domain_finding():
    assert diagnose("Cloud KMS key x is disabled").layer is Layer.KEY


def test_repeated_denials_are_grouped_and_ordered_by_count():
    log = FakeLog([denial("a"), denial("b"), denial("b"), denial("b"), denial("a")])
    summary = SummarizeDenials(log).execute()
    assert [(s.denial.principal, s.count) for s in summary] == [("b", 3), ("a", 2)]


def test_ties_keep_the_order_they_were_first_seen():
    summary = SummarizeDenials(FakeLog([denial("x"), denial("y")])).execute()
    assert [s.denial.principal for s in summary] == ["x", "y"]


def test_no_denials_is_an_empty_summary():
    assert SummarizeDenials(FakeLog([])).execute() == []


def test_the_table_has_a_row_per_capture_with_the_layer_and_escaped_pipes():
    captures = FakeCaptures(
        [
            Capture("key", "ERROR: Cloud KMS key a|b is disabled"),
            Capture(
                "missing-role", "ERROR: p/sa/reader-writer does not have storage.objects.get access to the object."
            ),
        ]
    )
    lines = BuildTriageTable(captures).execute().splitlines()
    assert lines[0].startswith("| Symptom | Exact error text | Layer | First check | Fix |")
    assert len(lines) == 4
    assert "a\\|b" in lines[2]
    assert "| key |" in lines[2]
    assert "| authorization |" in lines[3]
```

- `FakeLog` and `FakeCaptures` are **fakes**: tiny classes that satisfy the ports with in-memory lists. They need no `Protocol` base; having the method is enough. No file is read.
- `denial(...)` builds an `AuditDenial` with defaults, so each test names only what differs.
- The tests: `diagnose` returns the domain's finding; repeated denials are grouped and ordered by count (`b` three times before `a` twice); ties keep first-seen order; no denials give an empty list; the table has a header, a divider and a row per capture, the `|` in `a|b` is escaped as `a\|b`, and each row carries the layer.

### `tests/unit/infrastructure/test_adapters.py`

`tests/unit/infrastructure/test_adapters.py`

```python
import json
from pathlib import Path

import pytest

from gke_triage.domain.errors import UnreadableAuditLog
from gke_triage.infrastructure.audit_log import JsonAuditLogSource
from gke_triage.infrastructure.captures import DirectoryCaptureSource

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"


def test_the_audit_export_yields_only_the_denied_calls():
    denials = JsonAuditLogSource((FIXTURES / "audit-log.json").read_text()).denials()
    assert [(d.permission, d.principal.rsplit("/", 1)[-1]) for d in denials] == [
        ("storage.objects.create", "default"),
        ("storage.objects.create", "default"),
        ("", "operator@example.org"),
    ]
    assert denials[0].resource.endswith("/objects/a.txt")
    assert denials[0].timestamp == "2026-10-26T10:00:01Z"


@pytest.mark.parametrize("text", ["not json", "{}", '"x"'])
def test_anything_but_a_json_array_is_unreadable(text):
    with pytest.raises(UnreadableAuditLog):
        JsonAuditLogSource(text).denials()


def test_entries_without_a_payload_are_skipped():
    assert JsonAuditLogSource(json.dumps([{"a": 1}, 5, {"protoPayload": 3}])).denials() == []


def test_captures_are_read_sorted_by_name():
    names = [c.name for c in DirectoryCaptureSource(FIXTURES).captures()]
    assert names == sorted(names)
    assert "wrong-service-account" in names


def test_a_missing_directory_is_an_error(tmp_path):
    with pytest.raises(FileNotFoundError):
        DirectoryCaptureSource(tmp_path / "nope").captures()
```

- The audit export test checks the three denials found in the sample (two for the `default` account, one with no permission for a person), the resource ending, and the timestamp.
- A parametrized test feeds `"not json"`, `"{}"` and `'"x"'`: none is a JSON array, so each raises `UnreadableAuditLog`.
- `json.dumps([{"a": 1}, 5, {"protoPayload": 3}])` builds odd entries (a dictionary without a payload, a number, a payload that is not a dictionary); all are skipped.
- The capture tests: names come back sorted; a missing directory (`tmp_path / "nope"`) raises `FileNotFoundError`.

### `tests/unit/interfaces/test_cli.py`

`tests/unit/interfaces/test_cli.py`

```python
import io
from pathlib import Path

import pytest

from gke_triage.interfaces.cli import main

FIXTURES = Path(__file__).resolve().parents[2] / "fixtures"
NUMBER = "123456789012"
PROJECT = "example-sandbox-0000"


def run(capsys, *argv):
    status = main(list(argv))
    captured = capsys.readouterr()
    return status, captured.out, captured.err


def test_classify_prints_layer_cause_principal_permission_and_checks(capsys):
    status, out, _ = run(capsys, "classify", str(FIXTURES / "wrong-service-account.txt"))
    assert status == 0
    assert "layer:       authorization" in out
    assert "cause:       default service account" in out
    assert "permission:  storage.objects.create" in out
    assert "/sa/default" in out


def test_classify_reads_standard_input_with_a_dash(capsys, monkeypatch):
    monkeypatch.setattr("sys.stdin", io.StringIO("Cloud KMS key k is disabled"))
    status, out, _ = run(capsys, "classify", "-")
    assert status == 0
    assert "layer:       key" in out


def test_audit_lists_distinct_denials_and_exits_1_when_there_are_some(capsys):
    status, out, _ = run(capsys, "audit", str(FIXTURES / "audit-log.json"))
    assert status == 1
    assert out.splitlines()[0].startswith("2x  principal://")
    assert "sa/default" in out


def test_audit_with_no_denials_exits_0(capsys, tmp_path):
    empty = tmp_path / "log.json"
    empty.write_text("[]")
    assert run(capsys, "audit", str(empty))[:2] == (0, "no denials found\n")


def test_table_renders_every_capture_in_the_directory(capsys):
    status, out, _ = run(capsys, "table", str(FIXTURES))
    assert status == 0
    assert out.count("\n") == 2 + len(list(FIXTURES.glob("*.txt")))


def test_principal_prints_the_member_for_a_binding(capsys):
    status, out, _ = run(capsys, "principal", "--project-id", PROJECT, "--project-number", NUMBER)
    assert status == 0
    assert out.strip().endswith("/subject/ns/demo/sa/reader-writer")


def test_principal_rejects_the_project_id_in_place_of_the_number(capsys):
    status, _, err = run(capsys, "principal", "--project-id", PROJECT, "--project-number", PROJECT)
    assert status == 2
    assert "digits only" in err


def test_check_binding_flags_the_project_id_and_accepts_the_number(capsys):
    good = f"principal://iam.googleapis.com/projects/{NUMBER}/locations/global/workloadIdentityPools/{PROJECT}.svc.id.goog/subject/ns/demo/sa/reader-writer"
    bad = good.replace(NUMBER, PROJECT)
    assert run(capsys, "check-binding", good, "--project-id", PROJECT, "--project-number", NUMBER)[0] == 0
    status, out, _ = run(capsys, "check-binding", bad, "--project-id", PROJECT, "--project-number", NUMBER)
    assert status == 1
    assert "project id is used where the project number is needed" in out


def test_a_missing_file_is_a_clean_error_not_a_traceback(capsys):
    status, _, err = run(capsys, "classify", "does-not-exist.txt")
    assert status == 2
    assert err.startswith("error:")


def test_an_unreadable_audit_export_is_a_clean_error(capsys, tmp_path):
    bad = tmp_path / "bad.json"
    bad.write_text("nope")
    status, _, err = run(capsys, "audit", str(bad))
    assert status == 2
    assert "not JSON" in err


def test_a_subcommand_is_required():
    with pytest.raises(SystemExit):
        main([])
```

- `run(capsys, *argv)` calls `main` in the same process and returns `(status, out, err)`.
- `monkeypatch.setattr("sys.stdin", io.StringIO("..."))` replaces standard input with a text in memory, so the `-` argument can be tested without a pipe; the replacement is undone after the test.
- The tests cover each subcommand: `classify` prints layer, cause, permission and principal; with `-` it reads standard input; `audit` lists distinct denials (`2x principal://...` first), exits 1 when there are some and 0 with `no denials found` for `[]`; `table` prints the two header lines plus one line per `.txt` capture; `principal` prints the member and rejects a project id as the number (status 2, "digits only"); `check-binding` accepts the right member (0) and flags the project id (1); a missing file and an unreadable audit export are clean errors with `error:` on standard error; a missing subcommand makes `argparse` exit (`pytest.raises(SystemExit)`).

### `tests/unit/test_infrastructure_policy.py`

`tests/unit/test_infrastructure_policy.py`

```python
"""Guardrails over the Terraform source, checked without Terraform or Google Cloud.

They encode the lesson's rules as tests: no keys anywhere, no project-level role for the pod, the project number in the
principal, no public data, and an API endpoint that is never open to the world.
"""

import re
from pathlib import Path

import pytest

INFRA = Path(__file__).resolve().parents[2] / "infra"
SOURCES = {path: path.read_text() for path in INFRA.rglob("*.tf") if ".terraform" not in path.parts}
CODE = {path: re.sub(r"(?m)^\s*#.*$", "", text) for path, text in SOURCES.items()}


def _hits(pattern: str) -> list[str]:
    return [str(path.relative_to(INFRA)) for path, text in CODE.items() if re.search(pattern, text)]


def test_the_sources_were_found():
    assert len(SOURCES) >= 20


def test_no_service_account_key_is_ever_created():
    assert _hits(r'resource\s+"google_service_account_key"') == []


PROJECT_IAM = ["google_project_iam_member", "google_project_iam_binding", "google_project_iam_policy"]


@pytest.mark.parametrize("kind", PROJECT_IAM)
def test_no_project_level_role_is_granted(kind):
    assert _hits(rf'resource\s+"{kind}"') == []


@pytest.mark.parametrize("role", ["roles/owner", "roles/editor", "roles/storage.admin", "roles/cloudkms.admin"])
def test_no_broad_role_appears(role):
    assert _hits(re.escape(role)) == []


def test_nothing_is_public():
    assert _hits("allUsers|allAuthenticatedUsers") == []


def test_the_pod_principal_is_built_from_the_project_number_not_the_project_id():
    main = (INFRA / "environments/lab/main.tf").read_text()
    number_part = (
        "principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/"
    )
    subject_part = "${var.project_id}.svc.id.goog/subject/ns/${var.namespace}/sa/${var.kubernetes_service_account}"
    assert number_part + subject_part in main


def test_the_pod_principal_gets_a_role_on_the_bucket_and_none_on_the_key():
    main = (INFRA / "environments/lab/main.tf").read_text()
    assert main.count("local.pod_principal") == 1
    assert "object_users = { reader_writer = local.pod_principal }" in main
    assert "encrypter_decrypter_members = { storage_agent = local.storage_service_agent }" in main


def test_the_bucket_is_created_only_after_the_key_is_authorized():
    main = (INFRA / "environments/lab/main.tf").read_text()
    bucket = main[main.index('module "bucket"') : main.index('module "audit"')]
    assert "depends_on = [module.key]" in bucket


def test_the_api_endpoint_is_never_open_to_the_world():
    # Only the rule that rejects it and the deny-all firewall mention it.
    assert sorted(_hits("0\\.0\\.0\\.0/0")) == ["modules/gke-autopilot/variables.tf", "modules/network/main.tf"]
    assert '!= "0.0.0.0/0"' in (INFRA / "modules/gke-autopilot/variables.tf").read_text()


def test_the_provider_is_pinned_in_every_root_and_module():
    for path in INFRA.rglob("versions.tf"):
        if ".terraform" in path.parts:
            continue
        assert re.search(r'version\s*=\s*"(~>|>=)\s*8', path.read_text()), path
```

- The regular-expression part was explained in `regular-expressions.md`. `SOURCES` and `CODE` hold the text of all Terraform files, with and without comment lines.
- The rules: at least 20 files found; no `google_service_account_key`; none of the three project-level IAM kinds; none of four broad roles (`roles/owner`, `roles/editor`, `roles/storage.admin`, `roles/cloudkms.admin`); nothing public.
- The principal test checks that `main.tf` contains the exact text `principal://iam.googleapis.com/projects/${var.project_number}/locations/global/workloadIdentityPools/` followed by `${var.project_id}.svc.id.goog/subject/ns/...`: the number, not the id.
- The role test checks that `local.pod_principal` appears exactly once (`main.count(...) == 1`), as the bucket's `object_users`, and that the key's only member is the storage agent.
- The ordering test cuts the text of `main.tf` between `module "bucket"` and `module "audit"` with string slicing (`main[a:b]`) and asserts `depends_on = [module.key]` is inside.
- The endpoint test demands that the text `0.0.0.0/0` appears in exactly two files: the variable rule that rejects it, and the deny-all firewall rule. `\\.` is an escaped dot in the pattern string.

### `tests/unit/test_manifests.py`

`tests/unit/test_manifests.py`

```python
"""The Kubernetes manifests, checked as data: schema-valid, keyless, hardened, and wrong in exactly the lesson's way."""

from pathlib import Path
from typing import Any

import kubernetes_validate
import pytest
import yaml

ROOT = Path(__file__).resolve().parents[2] / "manifests"
K8S_VERSION = "1.33"


def load(path: str) -> list[dict[str, Any]]:
    return [doc for doc in yaml.safe_load_all((ROOT / path).read_text()) if doc]


def all_manifests() -> list[Path]:
    return sorted(p for p in ROOT.rglob("*.yaml") if p.name != "kustomization.yaml")


def deployment(path: str) -> dict[str, Any]:
    return next(doc for doc in load(path) if doc["kind"] == "Deployment")


@pytest.mark.parametrize("path", all_manifests(), ids=lambda p: str(p.relative_to(ROOT)))
def test_every_manifest_is_valid_against_the_kubernetes_schema(path):
    for doc in yaml.safe_load_all(path.read_text()):
        kubernetes_validate.validate(doc, K8S_VERSION, strict=True)


def test_the_service_deployment_runs_as_the_reader_writer_account_in_the_demo_namespace():
    spec = deployment("base/deployment.yaml")
    assert spec["metadata"]["namespace"] == "demo"
    assert spec["spec"]["template"]["spec"]["serviceAccountName"] == "reader-writer"


def test_the_wrong_identity_copy_has_no_service_account_name_so_it_runs_as_default():
    pod = deployment("overlays/wrong-identity/files-default.yaml")["spec"]["template"]["spec"]
    assert "serviceAccountName" not in pod


def test_the_two_deployments_differ_only_in_the_identity_and_the_name():
    good = deployment("base/deployment.yaml")["spec"]["template"]["spec"]
    bad = deployment("overlays/wrong-identity/files-default.yaml")["spec"]["template"]["spec"]
    good = {k: v for k, v in good.items() if k != "serviceAccountName"}
    assert good == bad


@pytest.mark.parametrize("path", ["base/deployment.yaml", "overlays/wrong-identity/files-default.yaml"])
def test_no_credential_reaches_the_pod(path):
    pod = deployment(path)["spec"]["template"]["spec"]
    assert pod["automountServiceAccountToken"] is False
    assert all("secret" not in volume for volume in pod.get("volumes", []))
    container = pod["containers"][0]
    assert "envFrom" not in container
    assert not any(e["name"].startswith("GOOGLE_APPLICATION_CREDENTIALS") for e in container.get("env", []))
    assert all("hostPath" not in volume for volume in pod.get("volumes", []))


@pytest.mark.parametrize("path", ["base/deployment.yaml", "overlays/wrong-identity/files-default.yaml"])
def test_the_pod_meets_the_restricted_pod_security_standard(path):
    pod = deployment(path)["spec"]["template"]["spec"]
    container = pod["containers"][0]
    assert pod["securityContext"]["runAsNonRoot"] is True
    assert pod["securityContext"]["seccompProfile"]["type"] == "RuntimeDefault"
    assert container["securityContext"]["allowPrivilegeEscalation"] is False
    assert container["securityContext"]["capabilities"]["drop"] == ["ALL"]
    assert container["securityContext"]["readOnlyRootFilesystem"] is True
    assert container["resources"]["requests"]
    assert container["resources"]["limits"]


@pytest.mark.parametrize("path", ["base/deployment.yaml", "overlays/wrong-identity/files-default.yaml"])
def test_the_image_is_pinned_to_a_version(path):
    image = deployment(path)["spec"]["template"]["spec"]["containers"][0]["image"]
    tag = image.rsplit(":", 1)[-1]
    assert tag not in {"latest", "slim", "stable"}
    assert image.startswith("gcr.io/google.com/cloudsdktool/google-cloud-cli:")
    assert "@sha256:" in image


def test_the_service_account_carries_no_annotation_and_no_key_reference():
    account = next(doc for doc in load("base/serviceaccount.yaml") if doc["kind"] == "ServiceAccount")
    assert "annotations" not in account["metadata"]
    assert "secrets" not in account


def test_nothing_may_connect_to_the_pod():
    policy = next(doc for doc in load("base/networkpolicy.yaml") if doc["kind"] == "NetworkPolicy")
    assert policy["spec"]["podSelector"] == {}
    assert policy["spec"]["policyTypes"] == ["Ingress"]
    assert "ingress" not in policy["spec"]
```

- `import kubernetes_validate` checks a manifest against the Kubernetes API schema of version `1.33` offline (`kubernetes-validate.md`); `strict=True` also rejects unknown fields. `yaml.safe_load_all` reads the manifests (`pyyaml.md`).
- `load`, `all_manifests` and `deployment` are helpers: read all documents of a file; list every manifest file except the kustomizations; pick the Deployment of a file with `next(... for ... if ...)`.
- The tests: every manifest is valid (parametrized by path, with readable `ids`); the service deployment runs as `reader-writer` in `demo`; the wrong-identity copy has **no** `serviceAccountName` so Kubernetes uses `default`; the two deployments differ only in the identity (a dictionary comprehension removes that key from the good one and compares); no credential reaches the pod (no token mounted, no secret volume, no `envFrom`, no `GOOGLE_APPLICATION_CREDENTIALS` variable, no `hostPath` volume); the pod meets the restricted security standard (non-root, default seccomp profile, no privilege escalation, all capabilities dropped, read-only root filesystem, requests and limits set); the image is pinned by version and digest (`@sha256:`); the service account has no annotation and no secret; the network policy selects all pods (`podSelector == {}`), covers ingress, and has no ingress rule, so nothing may connect.

### `tests/e2e/test_cli_process.py`

`tests/e2e/test_cli_process.py`

```python
"""The installed `gke-triage` program as a user runs it: a subprocess, standard input, exit statuses."""

import subprocess
import sys
from pathlib import Path

import pytest

pytestmark = pytest.mark.e2e

FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
PROGRAM = [sys.executable, "-m", "gke_triage.interfaces.cli"]


def run(*args, stdin=None):
    return subprocess.run([*PROGRAM, *args], input=stdin, capture_output=True, text=True, timeout=60, check=False)


def test_the_lessons_triage_table_comes_out_of_the_captured_error_texts():
    result = run("table", str(FIXTURES))
    assert result.returncode == 0
    rows = [line for line in result.stdout.splitlines() if line.startswith("| ")][2:]
    layers = {row.split(" | ")[2] for row in rows}
    assert {"authorization", "key", "identity", "unknown"} <= layers
    assert any("sa/default" in row for row in rows)


def test_an_error_piped_in_is_classified_as_the_layer_that_failed():
    result = run("classify", "-", stdin=(FIXTURES / "key-disabled.txt").read_text())
    assert result.returncode == 0
    assert "layer:       key" in result.stdout


def test_the_audit_export_exits_1_because_it_holds_denials():
    result = run("audit", str(FIXTURES / "audit-log.json"))
    assert result.returncode == 1
    assert "sa/default" in result.stdout


def test_the_project_id_where_the_number_belongs_is_caught_with_exit_2():
    result = run("principal", "--project-id", "example-sandbox-0000", "--project-number", "example-sandbox-0000")
    assert result.returncode == 2
    assert "projectNumber" in result.stderr
```

- A **process** is a running program. `subprocess.run([...])` starts a new one and waits. `sys.executable` is the Python running the tests; `-m gke_triage.interfaces.cli` runs a module as a program.
- `input=stdin` feeds text to its standard input; `capture_output=True` collects what it prints; `text=True` gives text instead of bytes; `timeout=60` kills it after a minute; `check=False` means a non-zero exit status does not raise (the tests read `returncode`).
- `pytestmark = pytest.mark.e2e` puts every test of the file in the `e2e` group (`-m e2e` selects it).
- The four tests: the triage table comes out of the captured texts (`row.split(" | ")[2]` takes the third cell, the layer, and the set of layers must include all four); an error piped in is classified; the audit export exits 1 because it holds denials; the project id in place of the number exits 2 and mentions `projectNumber` on standard error.

## 6. Try it yourself

```bash
make test-python
```
Expected: a line of dots, then a coverage table ending with `TOTAL` and a pass count such as `81 passed`.

```bash
.venv/bin/python -m pytest tests/unit -q -p no:cacheprovider -k "key or default"
```
Expected: only the tests whose names contain the words run; the others show as deselected.

```bash
.venv/bin/python -m pytest tests/unit --collect-only -q -p no:cacheprovider | tail -3
```
Expected: the last lines list test ids and a count like `81 tests collected`.

```bash
.venv/bin/python -m coverage report --include='src/gke_triage/domain/*,src/gke_triage/application/*' --fail-under=95 | tail -3
```
Expected: a `TOTAL` line at or above 95% (run `make test-python` first so coverage data exists).

## 7. Mistakes people make

- **Tests that need the network or the cloud.** These are slow and flaky; this repository keeps them in a separate folder and behind markers or containers.
- **Tests that depend on each other's order.** Each test builds its own world.
- **Asserting too little** (`assert result`) or too much (every field of a huge object). Assert the behavior the test name states.
- **Chasing 100% coverage.** Coverage shows what was not run; it does not prove the checks were good.
- **Forgetting that a hidden bug can sit on a path no test takes.** This project once had a logging bug visible only at INFO level; a regression test now runs at INFO.

## 8. Check yourself

1. How does pytest decide something is a test? *File named `test_*.py`, function named `test_*`.*
2. What is a fixture? *A setup function whose result is passed to tests by name.*
3. What does `parametrize` do? *Runs one test with several inputs.*
4. What does `--strict-markers` prevent? *Silent typos in marker names.*
5. What does `branch = true` add to coverage? *Whether both outcomes of each condition ran.*

## 9. Further reading

- pytest documentation: <https://docs.pytest.org/en/stable/>
- Fixtures: <https://docs.pytest.org/en/stable/how-to/fixtures.html>
- Parametrize: <https://docs.pytest.org/en/stable/how-to/parametrize.html>
- Coverage.py: <https://coverage.readthedocs.io/>
- pytest-cov: <https://pytest-cov.readthedocs.io/>
