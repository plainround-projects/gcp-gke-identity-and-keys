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

## Every module, in the order a request travels

The sections above explain Python's features one at a time. This part goes through every file of the package, whole, so that nothing is skipped. The package lives in `src/gke_triage/`. The folders are layers (see `import-linter.md`): `domain` knows nothing about files or the command line, `application` combines domain pieces into jobs, `infrastructure` talks to files, `interfaces` talks to the user.

First, a few words you will meet in every file.

- A **terminal** is a window where you type a command and press Return. The program prints its answer in the same window. A **command** such as `.venv/bin/gke-triage principal --help` is a program's path followed by **arguments**.
- A **directory** is a folder. A **path** is the text that names a file, such as `src/landing_zone/domain/design.py`. A path that does not start with a slash is **relative**: it starts from the folder you are in.
- A **virtual environment** is a private folder (here `.venv/`) that holds its own copy of Python and of the libraries this project needs, so installing them cannot disturb anything else on your computer. `.venv/bin/python` is that private Python.
- A **docstring** is a text in triple quotes as the first thing in a file, class or function. Python keeps it as the thing's documentation; tools and `help()` show it. A class or function whose body is only a docstring is a valid, empty one.
- An **exception** is Python's way of stopping normal flow when something went wrong. `raise` starts one; `except` catches it. If nobody catches it, the program stops and prints a **traceback** (the list of calls that led to the error).

### `__init__.py` files

Each folder under `src/gke_triage/` has an `__init__.py`. Its presence turns the folder into a **package**, so `import gke_triage.domain` works. The files hold at most a docstring. The test folders have empty ones too, so pytest treats each folder as a package and gives every test file a unique name.

### `domain/errors.py`

`src/gke_triage/domain/errors.py`

```python
"""Named errors of the domain."""


class DomainError(Exception):
    """Base class for every error the domain raises."""


class InvalidPrincipal(DomainError):
    """A principal or one of its parts is not valid."""


class UnreadableAuditLog(DomainError):
    """The audit log input is not the JSON that `gcloud logging read --format=json` prints."""
```

- `class DomainError(Exception):` defines a new kind of exception that **inherits** from `Exception` ("is a kind of"). The other two classes inherit from `DomainError`, so one `except DomainError` catches every error the program raises on purpose.
- `InvalidPrincipal`: a principal or one of its parts is wrong. `UnreadableAuditLog`: the audit-log input is not the JSON that `gcloud logging read --format=json` prints.
- Each class has only a docstring as its body, which is valid Python; the name carries the meaning.

### `domain/audit.py`

`src/gke_triage/domain/audit.py`

```python
"""A denied call as Cloud Audit Logs record it."""

from __future__ import annotations

from dataclasses import dataclass

_PERMISSION_DENIED = 7  # google.rpc.Code.PERMISSION_DENIED


@dataclass(frozen=True, slots=True)
class AuditDenial:
    """One denied Cloud Storage call: who, what permission, on which resource, when."""

    principal: str
    permission: str
    resource: str
    method: str
    timestamp: str


def is_denial(status_code: int | None, granted: bool | None) -> bool:
    """A call was denied when the authorization check says not granted or the status is PERMISSION_DENIED."""
    return granted is False or status_code == _PERMISSION_DENIED
```

- `_PERMISSION_DENIED = 7` is a module constant (capitals). The comment names where the number comes from: Google's standard error codes, where 7 is "permission denied". The leading underscore marks it as internal to the file.
- `AuditDenial` is a frozen dataclass of five texts: who (`principal`), what permission, on which `resource`, by which `method`, and when (`timestamp`).
- `is_denial(status_code, granted)` returns a boolean. `int | None` and `bool | None` in the signature mean "may be missing". The body is one expression: `granted is False or status_code == _PERMISSION_DENIED`. `is False` is deliberate: `None` (unknown) must not count as "not granted", only an explicit `False` does.

### `domain/triage.py`: the rules that read an error text

`src/gke_triage/domain/triage.py`

```python
"""Classify a failed Cloud Storage call from its error text: which layer failed, and what to check first."""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum


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


_AUTHORIZATION = re.compile(
    r"(?P<principal>\S+) does not have (?P<permission>[A-Za-z0-9_.]+) access to (?P<what>[^.]+)"
)
_KEY_DISABLED = re.compile(
    r"cloud kms key.{0,300}?(is disabled|disabled|destroyed|scheduled for destruction)", re.I | re.S
)
_KEY_PERMISSION = re.compile(r"Permission '(?P<permission>cloudkms\.[A-Za-z0-9_.]+)' denied", re.I)
_NO_CREDENTIALS = re.compile(
    r"could not (automatically )?determine credentials|default credentials were not found|"
    r"unable to (reach|connect to) the metadata server|HTTPError 401|invalid credentials|"
    r"reauthentication is needed",
    re.I,
)
_DEFAULT_ACCOUNT = re.compile(r"/sa/default$")


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
    """The first non-empty line, the part a person would paste into a table."""
    for line in text.splitlines():
        if line.strip():
            return line.strip()
    return ""
```

- `import re` brings in the regular-expression module (`regular-expressions.md` explains each pattern here).
- `Layer` has four members: `IDENTITY`, `AUTHORIZATION`, `KEY` and `UNKNOWN`. `Cause` has six. Their values are the words printed in the table and in the command output.
- `Finding` is a frozen dataclass: the layer, the cause, a one-line `symptom`, the `first_check` to make, the `fix`, and three optional fields (`principal`, `permission`, `evidence`) with defaults. Fields with defaults must come after those without.
- The six `re.compile(...)` lines at module level are the rules. They are compiled once when the file is imported, not on every call. Adjacent string literals inside parentheses are joined into one pattern.
- `classify(text)` tests the rules in a fixed order, and the first match wins: key disabled, then a key permission problem, then an authorization failure (split into the default account and a missing role), then missing credentials, then "unknown". The order matters: a key error contains words that could also match a later rule.
- `_KEY_DISABLED.search(text)` returns a match object or `None`; `if` treats a match as true and `None` as false.
- `key_permission["permission"]` reads a named group from the match. `authorization["principal"].rstrip(",:")` removes trailing commas or colons from the matched text.
- `_DEFAULT_ACCOUNT.search(principal)` decides between two causes of the same layer: the pod ran as the `default` Kubernetes service account (it forgot to name one), or it ran as the right one and lacks the role.
- Every branch returns a `Finding` with keyword arguments such as `permission=...` and `evidence=evidence`. The f-string in the missing-role branch inserts the permission into the advice.
- `_evidence` loops over the lines and returns the first that is not empty after `.strip()` (removes leading and trailing spaces and line breaks); if none, `""`.

### `domain/principal.py`: the pod's identity as an IAM member

`src/gke_triage/domain/principal.py`

```python
"""The identity of a pod under Workload Identity Federation for GKE, as an IAM principal."""

from __future__ import annotations

import re
from dataclasses import dataclass
from enum import Enum

from gke_triage.domain.errors import InvalidPrincipal

_PROJECT_ID = re.compile(r"[a-z][a-z0-9-]{4,28}[a-z0-9]")
_PROJECT_NUMBER = re.compile(r"[0-9]{1,19}")
_DNS_LABEL = re.compile(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?")
_URI = re.compile(
    r"principal://iam\.googleapis\.com/projects/(?P<number>[^/]+)/locations/global/workloadIdentityPools/"
    r"(?P<pool>[^/]+)/subject/ns/(?P<namespace>[^/]+)/sa/(?P<ksa>[^/]+)"
)


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
        )


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

- Four patterns: a project id (a lowercase letter, then letters, digits, hyphens, ending in a letter or digit, 6 to 30 characters), a project number (1 to 19 digits), a DNS label (what Kubernetes allows for names) and the whole `principal://` string with named parts.
- `WorkloadPrincipal` is a frozen dataclass of four texts. `__post_init__` validates after the automatic constructor. `fullmatch(...) is None` means "not a match". The first message is the lesson's common mistake: a project id where the number belongs, with the command that finds the number. `for label, value in ((...), (...))` loops over two pairs, so one rule checks both names.
- `uri` is a property that builds the exact text: the project number, then `workloadIdentityPools/PROJECT_ID.svc.id.goog` (the pool's name), then `subject/ns/NAMESPACE/sa/SERVICE_ACCOUNT`.
- `BindingProblem` is an enum whose values are the sentences shown to the user.
- `check_binding_member` compares a given member text with what this project's member must be: not a workload principal at all; the project id sitting where the number belongs (`match["number"] == project_id`); or the number or pool of another project. It returns the first problem or `None`. `BindingProblem | None` in the signature says so.

### `application/ports.py`: what the use cases ask for

`src/gke_triage/application/ports.py`

```python
"""Ports: where captured error texts and audit log entries come from."""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from typing import Protocol

from gke_triage.domain.audit import AuditDenial


@dataclass(frozen=True, slots=True)
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
        """Every denial in the export, in log order."""
        ...
```

- A **port** is a promise about shape without any code behind it. `class CaptureSource(Protocol):` defines a `Protocol`: any object with a method `captures()` returning a sequence of `Capture` counts as a `CaptureSource`, whether or not it says so. The `...` line is Python's way to write an empty body.
- Two ports exist: the captured error texts and the audit log entries. The use cases know the ports, never the files; the adapters in `infrastructure/` implement them, and the tests use small fakes.
- `Capture` is a frozen dataclass: a name (for example `wrong-service-account`) and the text.

### `application/diagnose.py`: the three jobs

`src/gke_triage/application/diagnose.py`

```python
"""Use cases: classify one error, summarize audit denials, build the triage table."""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass

from gke_triage.application.ports import AuditLogSource, CaptureSource
from gke_triage.domain.audit import AuditDenial
from gke_triage.domain.triage import Finding, classify


def diagnose(text: str) -> Finding:
    """Classify one failed call from its error text."""
    return classify(text)


@dataclass(frozen=True, slots=True)
class DenialSummary:
    """One distinct denial and how many times it appears."""

    denial: AuditDenial
    count: int


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


class BuildTriageTable:
    """Render the lesson's triage table, one row per captured failure."""

    def __init__(self, source: CaptureSource) -> None:
        """Create the use case around a capture source."""
        self._source = source

    def execute(self) -> str:
        """A Markdown table: symptom, exact error text, layer, first check, fix."""
        rows = ["| Symptom | Exact error text | Layer | First check | Fix |", "| --- | --- | --- | --- | --- |"]
        for capture in self._source.captures():
            finding = classify(capture.text)
            rows.append(
                "| "
                + " | ".join(
                    _cell(value)
                    for value in (
                        f"{finding.symptom} ({capture.name})",
                        finding.evidence,
                        finding.layer.value,
                        finding.first_check,
                        finding.fix,
                    )
                )
                + " |"
            )
        return "\n".join(rows) + "\n"


def _cell(value: str) -> str:
    return value.replace("|", "\\|").replace("\n", " ")
```

- `diagnose(text)` just calls `classify`; it exists so the command-line layer depends on the application layer, not on the domain rules directly.
- `DenialSummary` pairs a denial with its count. `SummarizeDenials.__init__` stores the source (`self._source`), and `execute` does the work: `keys` is a list of `(principal, permission, resource)` triples; `Counter(keys)` counts each triple; `first_seen` is a dictionary that keeps the first denial for each triple (`setdefault` stores only if the key is new); `zip(denials, keys, strict=True)` walks the two lists together and raises an error if their lengths differ; `sorted(first_seen, key=lambda key: -counts[key])` orders by descending count (`lambda` is a one-line anonymous function; the minus sign flips the order). Python's sort is **stable**, so ties keep the order they were first seen.
- `BuildTriageTable.execute` builds a Markdown table (`markdown.md`): a header row and a divider, then one row per capture. For each capture it classifies the text and joins five cells with `" | "`. `_cell` escapes a `|` inside a cell as `\|` and turns line breaks into spaces, so one failure stays on one table row.
- The expression `"| " + " | ".join(... for value in (...)) + " |"` uses a generator inside `join`; the five values are the symptom with the capture's name, the evidence, the layer, the first check and the fix.

### `infrastructure/audit_log.py`: reading the export

`src/gke_triage/infrastructure/audit_log.py`

```python
"""Adapter: the JSON that `gcloud logging read --format=json` prints for Cloud Storage data-access audit entries."""

from __future__ import annotations

import json
from collections.abc import Sequence
from typing import Any

from gke_triage.domain.audit import AuditDenial, is_denial
from gke_triage.domain.errors import UnreadableAuditLog


class JsonAuditLogSource:
    """Parses an export (a JSON array of log entries) into the denials it contains."""

    def __init__(self, text: str) -> None:
        """`text` is the whole export."""
        self._text = text

    def denials(self) -> Sequence[AuditDenial]:
        """The denied calls; entries that are not audit entries or were allowed are skipped."""
        try:
            entries = json.loads(self._text)
        except ValueError as error:
            raise UnreadableAuditLog("input is not JSON") from error
        if not isinstance(entries, list):
            raise UnreadableAuditLog("expected a JSON array, as `--format=json` prints")
        found: list[AuditDenial] = []
        for entry in entries:
            found.extend(_denials_in(entry))
        return found


def _denials_in(entry: Any) -> list[AuditDenial]:
    payload = entry.get("protoPayload") if isinstance(entry, dict) else None
    if not isinstance(payload, dict):
        return []
    authentication = payload.get("authenticationInfo") or {}
    principal = authentication.get("principalSubject") or authentication.get("principalEmail") or "unknown"
    status = payload.get("status") or {}
    status_code = status.get("code")
    results = []
    for authorization in payload.get("authorizationInfo") or []:
        if is_denial(status_code, authorization.get("granted")):
            results.append(
                AuditDenial(
                    principal=str(principal),
                    permission=str(authorization.get("permission", "")),
                    resource=str(authorization.get("resource") or payload.get("resourceName", "")),
                    method=str(payload.get("methodName", "")),
                    timestamp=str(entry.get("timestamp", "")),
                )
            )
    if not results and is_denial(status_code, None):
        results.append(
            AuditDenial(
                str(principal),
                "",
                str(payload.get("resourceName", "")),
                str(payload.get("methodName", "")),
                str(entry.get("timestamp", "")),
            )
        )
    return results
```

- `import json` is Python's standard JSON reader (`json.md`). `Any` is the type that means "anything"; it is used for `entry` because an export can hold any shape.
- `JsonAuditLogSource.__init__` keeps the whole text. `denials()` calls `json.loads(text)`, which turns JSON text into Python lists and dictionaries; a `ValueError` (invalid JSON) becomes `UnreadableAuditLog("input is not JSON")`, and `from error` keeps the original attached. The next check demands a list at the top, which is what `--format=json` prints.
- `_denials_in(entry)` is defensive: `entry.get("protoPayload") if isinstance(entry, dict) else None` means "take the key if the entry is a dictionary, otherwise nothing". An entry without a dictionary payload yields no denials.
- `authentication.get("principalSubject") or authentication.get("principalEmail") or "unknown"` uses `or` to take the first value that is not empty (a pod's identity is in `principalSubject`, a person's in `principalEmail`).
- The loop goes through `authorizationInfo`, the list of permission checks; `is_denial(status_code, authorization.get("granted"))` keeps the failed ones, each turned into an `AuditDenial` with `str(...)` around every field.
- The last `if` handles a denied call that carries no permission list: the status code alone says it was denied, so one denial is recorded with an empty permission.

### `infrastructure/captures.py`: reading the captured error texts

`src/gke_triage/infrastructure/captures.py`

```python
"""Adapter: capture files on disk, one `.txt` per failure."""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path

from gke_triage.application.ports import Capture


class DirectoryCaptureSource:
    """Reads every `*.txt` file of a directory, sorted by name; the file stem is the capture's name."""

    def __init__(self, directory: Path) -> None:
        """`directory` is where the break scripts save the error text of each failure."""
        self._directory = directory

    def captures(self) -> Sequence[Capture]:
        """All captures; raises `FileNotFoundError` when the directory does not exist."""
        if not self._directory.is_dir():
            raise FileNotFoundError(f"no such directory: {self._directory}")
        return [Capture(path.stem, path.read_text(encoding="utf-8")) for path in sorted(self._directory.glob("*.txt"))]
```

`Path.glob("*.txt")` finds the files whose name ends in `.txt`; `sorted(...)` orders them; `path.stem` is the file name without its extension (the capture's name); `read_text(encoding="utf-8")` reads the file. A missing folder raises `FileNotFoundError`, which the command turns into exit status 2.

### `interfaces/cli.py`: the command

`src/gke_triage/interfaces/cli.py`

```python
"""The `gke-triage` command: classify an error, summarize audit denials, build the table, print or check a principal."""

from __future__ import annotations

import argparse
import sys
from collections.abc import Sequence
from pathlib import Path

from gke_triage.application.diagnose import BuildTriageTable, SummarizeDenials, diagnose
from gke_triage.domain.errors import DomainError
from gke_triage.domain.principal import WorkloadPrincipal, check_binding_member
from gke_triage.infrastructure.audit_log import JsonAuditLogSource
from gke_triage.infrastructure.captures import DirectoryCaptureSource


def main(argv: Sequence[str] | None = None) -> int:
    """Run the command; returns the process exit status (0 ok, 1 a problem was found, 2 bad input)."""
    parser = _parser()
    args = parser.parse_args(argv)
    try:
        return int(args.handler(args))
    except (DomainError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2


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


def _read(file: str) -> str:
    return sys.stdin.read() if file == "-" else Path(file).read_text(encoding="utf-8")


def _classify(args: argparse.Namespace) -> int:
    finding = diagnose(_read(args.file))
    print(f"layer:       {finding.layer.value}")
    print(f"cause:       {finding.cause.value}")
    if finding.principal:
        print(f"principal:   {finding.principal}")
    if finding.permission:
        print(f"permission:  {finding.permission}")
    print(f"first check: {finding.first_check}")
    print(f"fix:         {finding.fix}")
    return 0


def _audit(args: argparse.Namespace) -> int:
    summaries = SummarizeDenials(JsonAuditLogSource(_read(args.file))).execute()
    if not summaries:
        print("no denials found")
        return 0
    for summary in summaries:
        denial = summary.denial
        print(f"{summary.count}x  {denial.principal}  {denial.permission}  {denial.resource}")
    return 1


def _table(args: argparse.Namespace) -> int:
    print(BuildTriageTable(DirectoryCaptureSource(Path(args.directory))).execute(), end="")
    return 0


def _principal(args: argparse.Namespace) -> int:
    print(WorkloadPrincipal(args.project_id, args.project_number, args.namespace, args.service_account).uri)
    return 0


def _check_binding(args: argparse.Namespace) -> int:
    problem = check_binding_member(args.member, args.project_id, args.project_number)
    if problem is None:
        print("ok: the member names this project's pool by number")
        return 0
    print(f"problem: {problem.value}")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
```

- The imports at the top bring each layer's pieces; the file is the only one that knows all layers.
- `main` and `_parser` are explained in `argparse.md`. `_read(file)` returns standard input when the argument is `-`, otherwise the file's text: `sys.stdin.read() if file == "-" else Path(file).read_text(...)`. Using `-` for standard input is a Unix habit, so you can pipe: `gcloud ... 2>&1 | gke-triage classify -`.
- `_classify` prints the finding, one labelled line each. The `if finding.principal:` lines print the optional parts only when present. It returns 0.
- `_audit` prints `COUNTx  principal  permission  resource` for each distinct denial and returns 1 when it found any (so a script can stop), 0 when none.
- `_table` prints the table without a second line break (`end=""`). `_principal` prints the member text. `_check_binding` prints `ok` and returns 0, or `problem: ...` and returns 1.
- The last two lines run `main` when the file is started as a program; `raise SystemExit(main())` ends the process with the number as exit status.

### The tests have no shared fixtures file

The test files use small helper functions at their tops (`finding(name)`, `principal(**overrides)`, `run(capsys, *argv)`) instead of a `conftest.py`. The folder `tests/integration/` holds only an empty `__init__.py`: this project's checks need no emulator, so the folder is a placeholder kept for the layout the repository rules ask for.

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
