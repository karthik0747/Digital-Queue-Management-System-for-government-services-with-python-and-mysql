"""
Custom exception classes for the Digital Queue Management System.

Demonstrates: Inheritance (every custom exception inherits from
QueueSystemError) and polymorphism (each builds its own message).
"""


class QueueSystemError(Exception):
    """Base exception class for all custom exceptions in this system."""


class InvalidServiceError(QueueSystemError):
    """Raised when an invalid/unregistered service type is requested."""

    def __init__(self, service_name):
        self.service_name = service_name
        super().__init__(f"Invalid service type: '{service_name}' is not offered at this center.")


class InvalidSubServiceError(QueueSystemError):
    """Raised when an invalid request type is requested under a valid service."""

    def __init__(self, sub_service, service_name):
        self.sub_service = sub_service
        self.service_name = service_name
        super().__init__(f"'{sub_service}' is not a valid request type under '{service_name}'.")


class QueueEmptyError(QueueSystemError):
    """Raised when trying to serve a citizen from an empty queue."""

    def __init__(self, service_name, sub_service=None):
        label = f"{service_name} - {sub_service}" if sub_service else service_name
        super().__init__(f"No citizens waiting today in the '{label}' queue.")


class CitizenNotFoundError(QueueSystemError):
    """Raised when a token number is not found in the system."""

    def __init__(self, token_no):
        super().__init__(f"Token number '{token_no}' was not found.")


class DuplicateTokenError(QueueSystemError):
    """Raised when a duplicate token number is generated/assigned."""

    def __init__(self, token_no):
        super().__init__(f"Token number '{token_no}' already exists in the system.")


class InvalidInputError(QueueSystemError):
    """Raised when user-provided input fails validation."""


class ServiceClosedError(QueueSystemError):
    """Raised when a staff action is attempted outside office hours."""


# ---------------- new in the MySQL version ----------------

class DatabaseError(QueueSystemError):
    """Raised when MySQL cannot be reached or a query fails."""


class SlotUnavailableError(QueueSystemError):
    """Raised when the chosen time slot is full, in the past, or the office is closed."""


class NoSlotsAvailableError(QueueSystemError):
    """Raised when no free slot exists in the booking window."""


class InvalidDateError(QueueSystemError):
    """Raised when a visit date is in the past or too far in the future."""


class InvalidTokenStateError(QueueSystemError):
    """Raised when an action is not allowed for the token's current status."""


class AuthenticationError(QueueSystemError):
    """Raised for a wrong staff PIN or a contact number that does not match the token."""
