# Python

## 1. What it is

Python is a programming language. You write text files that end in `.py`, and a program called the **interpreter** reads them and runs them. This repository needs Python 3.12 or newer (`requires-python = ">=3.12"`) and was tested with 3.13. A **type hint** is a note such as `name: str` that says what kind of value something holds; Python ignores it when running, and the tool `mypy` checks that the hints fit together. The program here uses only Python's **standard library** (the modules that ship with Python): there are no run-time dependencies.

## 2. Why this repository uses it

The lesson says the pod's "service" needs no application code. What the learner does need is a way to tell the three failures apart by reading an error: identity, authorization or key. Step 6 asks for a triage table. This repository turns that skill into a small, tested Python program, `gke-triage`, and also uses Python for its tests.

## 3. Where it appears

| Path | What it does with Python |
| --- | --- |
| `src/gke_triage/domain/` | Pure rules: `WorkloadPrincipal` (build and check the IAM principal string), `classify` (error text to layer), `AuditDenial`. |
| `src/gke_triage/application/` | The use cases (`diagnose`, `SummarizeDenials`, `BuildTriageTable`) and the ports they read from. |
| `src/gke_triage/infrastructure/` | Adapters that read an audit-log export and a folder of captured errors. |
| `src/gke_triage/interfaces/cli.py` | The command-line program. |
| `tests/` | Unit and end-to-end tests. |

## 4. How it works underneath

The interpreter turns each file into **bytecode** and runs it. `import gke_triage.domain.triage` makes Python search the folders in `sys.path` for `gke_triage/domain/triage.py`. After `pip install -e .`, `src/` is on that path for the virtual environment `.venv` (a private folder of installed packages). Every value is an **object**; types are checked while the program runs, which is why `mypy` is added.

A program starts at the top of the file. The line `if __name__ == "__main__":` is true only when the file is run directly, so a module can be both imported and run.

## 5. Walkthrough of this repository's use

### An immutable value that validates itself

`src/gke_triage/domain/principal.py`

```python
@dataclass(frozen=True, slots=True)
class WorkloadPrincipal:
    """One Kubernetes service account in one namespace of a project's workload identity pool."""

    project_id: str
    project_number: str
    namespace: str
    service_account: str

    def __post_init__(self) -> None:
        """Reject a project id where the number belongs, and names that Kubernetes would not accept."""
        if _PROJECT_NUMBER.fullmatch(self.project_number) is None:
            raise InvalidPrincipal(
                f"project number must be digits only, got {self.project_number!r}: "
                "use `gcloud projects describe PROJECT_ID --format='value(projectNumber)'`, not the project id"
            )
        if _PROJECT_ID.fullmatch(self.project_id) is None:
            raise InvalidPrincipal(f"not a project id: {self.project_id!r}")
        for label, value in (("namespace", self.namespace), ("service account", self.service_account)):
            if _DNS_LABEL.fullmatch(value) is None:
                raise InvalidPrincipal(f"{label} must be a lowercase DNS label, got {value!r}")

    @property
    def uri(self) -> str:
        """The `principal://` string used as the member of an IAM binding."""
        return (
            f"principal://iam.googleapis.com/projects/{self.project_number}/locations/global/"
            f"workloadIdentityPools/{self.project_id}.svc.id.goog/subject/ns/{self.namespace}/sa/{self.service_account}"
```

- `@dataclass(frozen=True, slots=True)` is a **decorator**: it writes `__init__`, `__repr__` and `__eq__` from the four fields. `frozen=True` forbids changing a field after creation; `slots=True` saves memory and rejects misspelled attributes.
- `__post_init__` runs right after the automatic `__init__`. It checks each part with a regular expression (see `regular-expressions.md`). A project id where the project number belongs raises `InvalidPrincipal` with the fix in the message, so a wrong object can never exist.
- `for label, value in (("namespace", ...), ("service account", ...)):` loops over a tuple of pairs; each pair is **unpacked** into two names.
- `@property def uri(self)` makes `principal.uri` look like a field but run code. It builds the long `principal://iam.googleapis.com/projects/NUMBER/...` string with an **f-string** (a string with `{expressions}` inside).

### An enumeration and a rule function

`src/gke_triage/domain/principal.py`

```python
class BindingProblem(Enum):
    """What is wrong with a principal string, if anything."""

    NOT_A_WORKLOAD_PRINCIPAL = "not a principal:// string for a workload identity pool"
    PROJECT_ID_WHERE_NUMBER_BELONGS = "the project id is used where the project number is needed"
    POOL_OF_ANOTHER_PROJECT = "the pool belongs to a different project than the number says"


def check_binding_member(member: str, project_id: str, project_number: str) -> BindingProblem | None:
    """Return the first problem with `member` as a binding for this project, or None when it looks right."""
    match = _URI.fullmatch(member)
    if match is None:
        return BindingProblem.NOT_A_WORKLOAD_PRINCIPAL
    if match["number"] == project_id:
        return BindingProblem.PROJECT_ID_WHERE_NUMBER_BELONGS
    if match["number"] != project_number or match["pool"] != f"{project_id}.svc.id.goog":
        return BindingProblem.POOL_OF_ANOTHER_PROJECT
    return None
```

An `Enum` is a fixed set of named values. `BindingProblem | None` means "a problem, or nothing". The function returns the first problem it finds, and `None` when the binding looks right. `match["number"]` reads a named group from a regular-expression match.

### Rules as data: classify

`src/gke_triage/domain/triage.py`

```python
class Layer(Enum):
    """The three places access can fail, plus the case the rules do not recognize."""

    IDENTITY = "identity"
    AUTHORIZATION = "authorization"
    KEY = "key"
    UNKNOWN = "unknown"


class Cause(Enum):
    """The specific reason inside a layer."""

    NO_CREDENTIALS = "no credentials"
    DEFAULT_SERVICE_ACCOUNT = "default service account"
    MISSING_ROLE = "missing role"
    KEY_DISABLED = "key disabled"
    KEY_ACCESS_DENIED = "key access denied"
    UNRECOGNIZED = "unrecognized"


@dataclass(frozen=True, slots=True)
class Finding:
    """The result of classifying one error text."""

    layer: Layer
    cause: Cause
    symptom: str
    first_check: str
    fix: str
    principal: str | None = None
    permission: str | None = None
    evidence: str = ""
```

`Layer` and `Cause` are enums. `Finding` is a frozen dataclass that holds the answer: the layer, the cause, what to check first, and optional details. A field with `= None` or `= ""` is optional and must come after required ones.

`src/gke_triage/domain/triage.py`

```python
def classify(text: str) -> Finding:
    """Classify `text`, the output of a failed `gcloud storage` command or a Cloud Storage client error."""
    evidence = _evidence(text)
    if _KEY_DISABLED.search(text):
        return Finding(
            Layer.KEY,
            Cause.KEY_DISABLED,
            "reads fail although IAM is fine",
            "gcloud kms keys versions list --key=KEY --keyring=RING --location=LOCATION",
            "gcloud kms keys versions enable VERSION ... (a destroyed version cannot be recovered)",
            evidence=evidence,
        )
    key_permission = _KEY_PERMISSION.search(text)
    if key_permission:
        return Finding(
            Layer.KEY,
            Cause.KEY_ACCESS_DENIED,
            "the bucket cannot use its key",
            "gcloud kms keys get-iam-policy KEY ...: does the Cloud Storage service agent hold encrypterDecrypter?",
            "gcloud storage service-agent --project=PROJECT --authorize-cmek=KEY",
            permission=key_permission["permission"],
            evidence=evidence,
        )
    authorization = _AUTHORIZATION.search(text)
    if authorization:
        principal = authorization["principal"].rstrip(",:")
        permission = authorization["permission"]
        if _DEFAULT_ACCOUNT.search(principal):
            return Finding(
                Layer.AUTHORIZATION,
                Cause.DEFAULT_SERVICE_ACCOUNT,
                "authenticated but denied (sa/default)",
                "print the principal in the error: is it the account you meant?",
                "set serviceAccountName on the pod to the account that holds the bucket role",
                principal=principal,
                permission=permission,
                evidence=evidence,
            )
        return Finding(
            Layer.AUTHORIZATION,
            Cause.MISSING_ROLE,
            "denied after a role was removed, or never granted",
            "read the bucket policy: gcloud storage buckets get-iam-policy gs://BUCKET",
            f"grant a role that includes {permission} to the principal, on the bucket",
            principal=principal,
            permission=permission,
            evidence=evidence,
        )
    if _NO_CREDENTIALS.search(text):
        return Finding(
            Layer.IDENTITY,
            Cause.NO_CREDENTIALS,
            "the call has no usable credentials",
            "kubectl exec ... -- gcloud auth list; is Workload Identity Federation enabled on the cluster?",
            "enable the workload pool on the cluster (Autopilot has it); run the pod with a Kubernetes service account",
            evidence=evidence,
        )
    return Finding(
        Layer.UNKNOWN,
        Cause.UNRECOGNIZED,
        "not one of the three known failures",
        "read the full error and the audit log entry for the call",
        "extend gke_triage.domain.triage with a rule once you know the cause",
        evidence=evidence,
    )


def _evidence(text: str) -> str:
```

`classify` is a plain function: text in, `Finding` out, no files and no printing, so it is trivial to test. It tries the rules in order from most to least specific: a disabled key first, then a key permission failure, then the IAM "does not have PERMISSION access" form, then missing credentials, and finally "unknown". `.search(text)` returns a match or `None`; `if authorization:` is true only for a match. `_DEFAULT_ACCOUNT.search(principal)` decides between "wrong service account" and "missing role" by whether the principal ends in `/sa/default`. The helper `_evidence` (the last quoted line starts it) returns the first non-empty line of the text, the part you would paste into a table.

### Counting and grouping

`src/gke_triage/application/diagnose.py`

```python
class SummarizeDenials:
    """Group an audit log export by principal, permission and resource."""

    def __init__(self, source: AuditLogSource) -> None:
        """Create the use case around an audit log source."""
        self._source = source

    def execute(self) -> list[DenialSummary]:
        """Distinct denials, most frequent first, ties in first-seen order."""
        denials = self._source.denials()
        keys = [(d.principal, d.permission, d.resource) for d in denials]
        counts = Counter(keys)
        first_seen: dict[tuple[str, str, str], AuditDenial] = {}
        for denial, key in zip(denials, keys, strict=True):
            first_seen.setdefault(key, denial)
        ordered = sorted(first_seen, key=lambda key: -counts[key])
        return [DenialSummary(first_seen[key], counts[key]) for key in ordered]
```

- `Counter` counts how many times each key occurs. The keys are tuples `(principal, permission, resource)`.
- `zip(denials, keys, strict=True)` walks two lists side by side; `strict=True` raises if their lengths differ.
- `first_seen.setdefault(key, denial)` stores the first denial for a key and leaves later ones alone.
- `sorted(first_seen, key=lambda key: -counts[key])` sorts by count, highest first (`lambda` is a one-line anonymous function; the minus sign reverses the order). Python's sort is **stable**, so ties keep first-seen order.

### Ports

`src/gke_triage/application/ports.py`

```python
class Capture:
    """The text of one failure as you captured it, under a name such as `wrong-service-account`."""

    name: str
    text: str


class CaptureSource(Protocol):
    """Yields the captured failures to put in the triage table."""

    def captures(self) -> Sequence[Capture]:
        """All captures, in a stable order."""
        ...


class AuditLogSource(Protocol):
    """Yields the denied calls found in an audit log export."""

    def denials(self) -> Sequence[AuditDenial]:
```

A `Protocol` states the shape an object must have, without inheritance. `DirectoryCaptureSource` and the test fakes both fit `CaptureSource`.

### The program's entry point

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

`main` parses the command line (see `argparse.md`), runs the chosen handler and turns domain errors and file errors into a short message on standard error and exit status 2. `int(args.handler(args))` calls the handler stored by `set_defaults(handler=...)`. The last lines of the file, `if __name__ == "__main__": raise SystemExit(main())`, make `python -m gke_triage.interfaces.cli` return that status to the shell.

## 6. Try it yourself

Run from the repository root after `make install`.

```bash
.venv/bin/python --version
```
Expected: `Python 3.13.x` (3.12 or newer).

```bash
.venv/bin/python -c "
from gke_triage.domain.principal import WorkloadPrincipal
p = WorkloadPrincipal('example-sandbox-0000', '123456789012', 'demo', 'reader-writer')
print(p.uri)"
```
Expected: `principal://iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/example-sandbox-0000.svc.id.goog/subject/ns/demo/sa/reader-writer`

```bash
.venv/bin/python -c "
from gke_triage.domain.principal import WorkloadPrincipal
WorkloadPrincipal('example-sandbox-0000', 'example-sandbox-0000', 'demo', 'reader-writer')" 2>&1 | tail -1
```
Expected: `gke_triage.domain.errors.InvalidPrincipal: project number must be digits only, got 'example-sandbox-0000': use `gcloud projects describe PROJECT_ID --format='value(projectNumber)'`, not the project id`

```bash
.venv/bin/python -c "
from gke_triage.domain.triage import classify
f = classify(open('tests/fixtures/key-disabled.txt').read())
print(f.layer.value, f.cause.value)"
```
Expected: `key key disabled`

```bash
.venv/bin/python -c "
from gke_triage.domain.principal import WorkloadPrincipal
p = WorkloadPrincipal('example-sandbox-0000', '123456789012', 'demo', 'a'); p.namespace = 'x'" 2>&1 | tail -1
```
Expected: `dataclasses.FrozenInstanceError: cannot assign to field 'namespace'`

## 7. Mistakes people make

- **Mutable default arguments** (`def f(x=[])`) share one list between calls. None here: the values are frozen.
- **Comparing with `==` to `None`.** Use `is None`.
- **Catching `Exception` everywhere.** Here the CLI catches only `DomainError` and `OSError`.
- **Putting file or print code inside rules.** `classify` stays pure; an import-linter contract forbids `pathlib`, `json`, `argparse` and `subprocess` in the domain and application layers.
- **Relying on dictionary order or sort ties without knowing it.** Python keeps insertion order and sorts stably, and a test checks the tie order.

## 8. Check yourself

1. What does `frozen=True` do? *Forbids changing a field after creation.*
2. What does `__post_init__` do here? *Validates the fields right after the automatic constructor.*
3. Why is `classify` a function with no I/O? *So the rules can be tested with plain strings.*
4. What does `zip(..., strict=True)` add? *An error if the sequences differ in length.*
5. What does `if __name__ == "__main__":` guard? *Code that should run only when the file is executed, not imported.*

## 9. Further reading

- Python 3.12 documentation: <https://docs.python.org/3.12/>
- `dataclasses`: <https://docs.python.org/3.12/library/dataclasses.html>
- `enum`: <https://docs.python.org/3.12/library/enum.html>
- `collections.Counter`: <https://docs.python.org/3.12/library/collections.html#collections.Counter>
- `typing.Protocol`: <https://docs.python.org/3.12/library/typing.html#typing.Protocol>
