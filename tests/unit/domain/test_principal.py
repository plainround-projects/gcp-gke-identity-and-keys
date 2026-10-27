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
