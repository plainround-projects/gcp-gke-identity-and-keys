"""Named errors of the domain."""


class DomainError(Exception):
    """Base class for every error the domain raises."""


class InvalidPrincipal(DomainError):
    """A principal or one of its parts is not valid."""


class UnreadableAuditLog(DomainError):
    """The audit log input is not the JSON that `gcloud logging read --format=json` prints."""
