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
