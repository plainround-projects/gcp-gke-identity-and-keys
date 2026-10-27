# Regular expressions (the `re` module)

## 1. What it is

A **regular expression** (regex) is a compact pattern that describes text: "digits only", "a word, then `@`, then a domain". Python's standard module `re` compiles a pattern and tests or searches text with it. Patterns are written in a small language of their own: `[0-9]` is one digit, `+` means "one or more", `.` is any character, `\S` is any non-space character, `(?P<name>...)` captures a part under a name, `^` and `$` are the start and end.

## 2. Why this repository uses it

The tool must read free-form error messages from `gcloud` and Cloud Storage and decide which of three failures they describe. It also validates identifiers such as the project number and Kubernetes names.

## 3. Where it appears

| Path | What it does |
| --- | --- |
| `src/gke_triage/domain/triage.py` | The rules that recognize an authorization failure, a key failure and missing credentials. |
| `src/gke_triage/domain/principal.py` | Validates the project id, the project number, namespace and service account names; parses a principal string. |

## 4. How it works underneath

`re.compile(pattern, flags)` turns the pattern into a small matching machine, done once at import. `.search(text)` looks for the pattern anywhere and returns a **match object** (or `None`). `.fullmatch(text)` demands that the whole string match. A match object gives the matched text and, for named groups, `match["name"]`. Flags change the rules: `re.I` ignores case; `re.S` lets `.` match a newline too.

A pattern is just a string, so write it as a **raw string** (`r"..."`) to stop Python from treating backslashes as its own escapes.

## 5. Walkthrough of this repository's use

`src/gke_triage/domain/principal.py`

```python
_PROJECT_ID = re.compile(r"[a-z][a-z0-9-]{4,28}[a-z0-9]")
_PROJECT_NUMBER = re.compile(r"[0-9]{1,19}")
_DNS_LABEL = re.compile(r"[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?")
```

- `[a-z][a-z0-9-]{4,28}[a-z0-9]`: a project id starts with a lowercase letter, has 4 to 28 letters, digits or hyphens in the middle, and ends with a letter or digit (6 to 30 characters in all).
- `[0-9]{1,19}`: a project number is only digits.
- `[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?`: a Kubernetes name (a DNS label): lowercase letters, digits and hyphens, not starting or ending with a hyphen, up to 63 characters. The `?` after the group makes the middle-and-end part optional so a one-letter name is allowed.
- `.fullmatch(...)` is used so a bad character anywhere makes it fail.

The principal parser:

`src/gke_triage/domain/principal.py`

```python
_URI = re.compile(
    r"principal://iam\.googleapis\.com/projects/(?P<number>[^/]+)/locations/global/workloadIdentityPools/"
    r"(?P<pool>[^/]+)/subject/ns/(?P<namespace>[^/]+)/sa/(?P<ksa>[^/]+)"
)
```

`(?P<number>[^/]+)` captures one or more characters that are not `/` under the name `number`. The long literal parts must match exactly (dots are escaped as `\.` to mean a real dot). This is how `check_binding_member` compares the number in a binding with the project's real number.

The error-text rules:

`src/gke_triage/domain/triage.py`

```python
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
```

- `_AUTHORIZATION` finds `PRINCIPAL does not have PERMISSION access to WHAT` and captures the three parts by name. `\S+` is a run of non-space characters; `[A-Za-z0-9_.]+` a permission like `storage.objects.create`; `[^.]+` everything up to the next dot.
- `_KEY_DISABLED` uses `.{0,300}?`: "any characters, at most 300, as few as possible" between the words `cloud kms key` and a state word. `re.I | re.S` makes it ignore case and cross line breaks.
- `_KEY_PERMISSION` finds `Permission 'cloudkms....' denied`.
- `_NO_CREDENTIALS` is a list of alternatives separated by `|` ("or").
- `_DEFAULT_ACCOUNT` is `/sa/default$`: the principal must end with that.

## 6. Try it yourself

```bash
.venv/bin/python -c "
import re
print(bool(re.fullmatch(r'[0-9]{1,19}', '123456789012')), bool(re.fullmatch(r'[0-9]{1,19}', 'example-sandbox-0000')))"
```
Expected: `True False`

```bash
.venv/bin/python -c "
from gke_triage.domain.triage import _AUTHORIZATION
m = _AUTHORIZATION.search(open('tests/fixtures/missing-role.txt').read())
print(m['permission']); print(m['principal'][-24:])"
```
Expected: `storage.objects.get` then the last 24 characters of the principal: `ns/demo/sa/reader-writer`.

```bash
.venv/bin/python -m pytest tests/unit/domain/test_triage.py tests/unit/domain/test_principal.py -q -p no:cacheprovider
```
Expected: `22 passed`.

## 7. Mistakes people make

- **Forgetting the raw string**, so `\.` becomes something else.
- **Using `.search` when the whole string must match.** Use `.fullmatch`.
- **Greedy matching** (`.*`) swallowing too much. The `?` after a quantifier makes it lazy.
- **Writing one giant pattern.** Each rule here is small and has a test with the lesson's real text.
- **Trusting a rule on text you never saw.** The key rule is the least certain, because the lesson elides the exact error; the README says to capture your own.

## 8. Check yourself

1. What is the difference between `search` and `fullmatch`? *`search` finds the pattern anywhere; `fullmatch` needs the whole string to match.*
2. What does `(?P<number>...)` do? *Captures that part under the name `number`.*
3. Why `r"..."`? *A raw string keeps backslashes for the regex engine.*
4. What does `re.I` do? *Ignore upper and lower case.*
5. What does `$` mean? *End of the text.*

## 9. Further reading

- `re` module: <https://docs.python.org/3.12/library/re.html>
- Regular expression HOWTO: <https://docs.python.org/3.12/howto/regex.html>
