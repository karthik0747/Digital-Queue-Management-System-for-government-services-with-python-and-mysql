"""
Core OOP models for the Digital Queue Management System.

Demonstrates: Abstraction (Person is abstract), Inheritance (Citizen is a
Person), Encapsulation (protected attributes + properties) and Polymorphism
(display_info() behaves differently for Citizen and Token).

Each government service (Passport, Aadhar Card, ...) has several REQUEST TYPES.
Every request type has its own token sequence, e.g.
    Aadhar Card -> Date of Birth Update -> AC-DOB-0001, AC-DOB-0002 ...
and every token now carries a booked TIME SLOT (the time the citizen should come).
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta

import config


def to_time(value):
    """MySQL returns TIME columns as timedelta - convert to datetime.time."""
    if isinstance(value, time):
        return value
    if isinstance(value, timedelta):
        secs = int(value.total_seconds())
        return time(secs // 3600 % 24, (secs % 3600) // 60, secs % 60)
    if isinstance(value, str):
        parts = [int(p) for p in value.split(":")]
        return time(*parts)
    raise TypeError(f"Cannot convert {value!r} to time")


def add_minutes(t, minutes):
    return (datetime.combine(date.today(), t) + timedelta(minutes=minutes)).time()


class Person(ABC):
    """Abstract base class demonstrating abstraction."""

    def __init__(self, name, age, contact):
        self._name = name
        self._age = age
        self._contact = contact

    @property
    def name(self):
        return self._name

    @property
    def age(self):
        return self._age

    @property
    def contact(self):
        return self._contact

    @abstractmethod
    def display_info(self):
        """Every subclass must define how it presents itself."""


class Citizen(Person):
    """A citizen who books a token."""

    def __init__(self, name, age, contact, citizen_id=None):
        super().__init__(name, age, contact)
        self.citizen_id = citizen_id

    @property
    def masked_contact(self):
        return "XXXXXX" + self._contact[-4:]

    def display_info(self):
        return f"{self._name} (age {self._age}, phone {self.masked_contact})"

    def __str__(self):
        return self.display_info()


@dataclass(frozen=True)
class SubServiceInfo:
    """One request type, e.g. Aadhar Card -> Date of Birth Update."""
    sub_service_id: int
    service_id: int
    service_type: str
    name: str
    abbrev: str
    prefix: str
    avg_minutes: int
    documents: str
    num_counters: int


@dataclass(frozen=True)
class Slot:
    """A bookable time slot and how crowded the office is around it."""
    date: date
    start: time
    end: time
    crowd: str          # "Low" / "Medium" / "High"
    crowd_ratio: float


@dataclass(frozen=True)
class Recommendation:
    earliest: Slot
    quietest: list      # best (least crowded) slot on each of the next few days


class Token:
    """A booked visit: who, for what, on which day, at what time."""

    def __init__(self, token_no, citizen, service_type, sub_service, visit_date,
                 slot_start, slot_end, status, booked_at, served_at=None,
                 token_id=None, sub_service_id=None, avg_minutes=None):
        self.token_no = token_no
        self.citizen = citizen
        self.service_type = service_type
        self.sub_service = sub_service
        self.visit_date = visit_date
        self.slot_start = slot_start
        self.slot_end = slot_end
        self.status = status                  # WAITING / SERVED / CANCELLED / EXPIRED
        self.booked_at = booked_at
        self.served_at = served_at
        self.token_id = token_id
        self.sub_service_id = sub_service_id
        self.avg_minutes = avg_minutes

    @property
    def arrive_by(self):
        """Reach the office this many minutes before the slot (but never before opening)."""
        earliest = add_minutes(self.slot_start, -config.ARRIVE_EARLY_MINUTES)
        return max(earliest, config.OPEN_TIME)

    def display_info(self):
        return (f"Token: {self.token_no} | {self.citizen.display_info()} | "
                f"{self.service_type} ({self.sub_service}) | "
                f"Visit: {self.visit_date:%d-%b-%Y} {fmt_time(self.slot_start)}-"
                f"{fmt_time(self.slot_end)} | Status: {self.status}")

    def __str__(self):
        return self.display_info()

    @staticmethod
    def from_row(row):
        citizen = Citizen(row["name"], row["age"], row["contact"], row["citizen_id"])
        return Token(
            token_no=row["token_no"], citizen=citizen,
            service_type=row["service_type"], sub_service=row["sub_service"],
            visit_date=row["visit_date"],
            slot_start=to_time(row["slot_start"]), slot_end=to_time(row["slot_end"]),
            status=row["status"], booked_at=row["booked_at"], served_at=row["served_at"],
            token_id=row["token_id"], sub_service_id=row["sub_service_id"],
            avg_minutes=row["avg_minutes"],
        )


def fmt_time(t):
    return t.strftime("%I:%M %p").lstrip("0")


def fmt_date(d):
    return d.strftime("%a, %d %b %Y")
