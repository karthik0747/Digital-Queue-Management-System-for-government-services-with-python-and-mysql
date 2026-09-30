"""
Service availability / business hours.

Offices are open Monday-Friday 8:00 AM - 6:00 PM (with a lunch break) and
closed on Saturdays, Sundays and public holidays. The holiday list now lives
in the MySQL `holidays` table, so staff can add/remove holidays from the
Staff menu without touching any code.
"""

from datetime import datetime, timedelta

import config


class BusinessHours:
    def __init__(self, holiday_loader=None):
        """holiday_loader: a function returning {date: "Holiday name"}."""
        self._loader = holiday_loader
        self._holidays = {}
        self.reload()

    def reload(self):
        self._holidays = dict(self._loader()) if self._loader else {}

    # ---------- date-level checks ----------

    @property
    def holidays(self):
        return dict(self._holidays)

    def is_working_day(self, day):
        return day.weekday() not in config.CLOSED_WEEKDAYS and day not in self._holidays

    def closed_reason_for_date(self, day):
        """Why the office is closed on this date, or None if it is a working day."""
        if day.weekday() == 5:
            return "Saturday"
        if day.weekday() == 6:
            return "Sunday"
        if day in self._holidays:
            return f"public holiday ({self._holidays[day]})"
        return None

    def next_working_day(self, day):
        """First working day strictly after `day`."""
        d = day + timedelta(days=1)
        while not self.is_working_day(d):
            d += timedelta(days=1)
        return d

    # ---------- moment-level checks ----------

    def _in_lunch(self, t):
        if config.LUNCH_START is None or config.LUNCH_END is None:
            return False
        return config.LUNCH_START <= t < config.LUNCH_END

    def is_open(self, check_datetime=None):
        check_datetime = check_datetime or datetime.now()
        if not self.is_working_day(check_datetime.date()):
            return False
        t = check_datetime.time()
        if self._in_lunch(t):
            return False
        return config.OPEN_TIME <= t <= config.CLOSE_TIME

    def status_message(self, check_datetime=None):
        """Human-readable line describing whether the office is open right now."""
        check_datetime = check_datetime or datetime.now()
        note = "Office hours: Mon-Fri, 8:00 AM - 6:00 PM (closed Sat, Sun & public holidays)."
        if config.LUNCH_START and config.LUNCH_END:
            note = note[:-1] + f"; lunch {_fmt(config.LUNCH_START)} - {_fmt(config.LUNCH_END)}."
        if self.is_open(check_datetime):
            return f"Office is OPEN. Closes today at {_fmt(config.CLOSE_TIME)}. {note}"
        return f"Office is CLOSED - {self._closed_reason(check_datetime)}. {note}"

    def _closed_reason(self, dt):
        day_reason = self.closed_reason_for_date(dt.date())
        if day_reason:
            return f"today is {day_reason}"
        t = dt.time()
        if self._in_lunch(t):
            return f"lunch break, reopens at {_fmt(config.LUNCH_END)}"
        if t < config.OPEN_TIME:
            return f"office opens at {_fmt(config.OPEN_TIME)}"
        return f"office closed for the day at {_fmt(config.CLOSE_TIME)}"


def _fmt(t):
    return t.strftime("%I:%M %p").lstrip("0")
