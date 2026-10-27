import pytest

from gke_triage.domain.audit import is_denial


@pytest.mark.parametrize(
    ("status", "granted", "expected"),
    [(7, None, True), (None, False, True), (0, True, False), (None, None, False), (7, True, True)],
)
def test_a_call_is_denied_when_not_granted_or_permission_denied(status, granted, expected):
    assert is_denial(status, granted) is expected
