"""
Time-slot scheduler - the part that answers "what time should I come?".

Rules
-----
* The day is cut into SLOT_MINUTES (15 min) units between opening and closing.
* Each request type needs some minutes at the counter (e.g. Aadhar mobile
  update = 10 min -> 1 unit, Aadhar new enrollment = 30 min -> 2 units).
* A department has N counters, so at most N people can be booked in the same
  unit of time. A slot is FREE only if every unit it covers has < N bookings.
* Appointments never overlap the lunch break or run past closing time.
* For today, slots that have already started are hidden.

This module has no database code, so it is easy to unit-test.
"""

import math
from datetime import time

import config
from service_hours import BusinessHours


def to_min(t):
    return t.hour * 60 + t.minute


def to_time(minutes):
    return time(minutes // 60, minutes % 60)


class SlotScheduler:
    def __init__(self, hours: BusinessHours, slot_minutes=config.SLOT_MINUTES):
        self.hours = hours
        self.slot = slot_minutes

    def round_duration(self, avg_minutes):
        """Round the counter time UP to whole slots (10 min -> 15, 20 min -> 30)."""
        return max(self.slot, math.ceil(avg_minutes / self.slot) * self.slot)

    # ---------- candidate start times ----------

    def _candidate_starts(self, duration):
        open_m, close_m = to_min(config.OPEN_TIME), to_min(config.CLOSE_TIME)
        lunch = None
        if config.LUNCH_START and config.LUNCH_END:
            lunch = (to_min(config.LUNCH_START), to_min(config.LUNCH_END))
        starts = []
        for m in range(open_m, close_m - duration + 1, self.slot):
            end = m + duration
            if lunch and m < lunch[1] and end > lunch[0]:
                continue                         # would touch the lunch break
            starts.append(m)
        return starts

    @staticmethod
    def _count_at(unit_start, booked_min):
        return sum(1 for b_start, b_end in booked_min if b_start <= unit_start < b_end)

    @staticmethod
    def _to_minutes(booked):
        return [(to_min(s), to_min(e)) for s, e in booked]

    # ---------- public API ----------

    def available_starts(self, day, duration, capacity, booked, now=None):
        """
        Free start times on `day`.
        booked: list of (start_time, end_time) already taken in this department.
        now:    current datetime; hides slots that have already begun today.
        """
        if not self.hours.is_working_day(day):
            return []
        booked_min = self._to_minutes(booked)

        earliest = 0
        if now is not None and day == now.date():
            now_m = now.hour * 60 + now.minute + (1 if now.second or now.microsecond else 0)
            earliest = math.ceil(now_m / self.slot) * self.slot

        free = []
        for m in self._candidate_starts(duration):
            if m < earliest:
                continue
            if all(self._count_at(u, booked_min) < capacity
                   for u in range(m, m + duration, self.slot)):
                free.append(to_time(m))
        return free

    def crowd(self, start, duration, capacity, booked):
        """
        How busy is the office around this slot? Looks 30 minutes before and
        after the slot. Returns (ratio 0..1, "Low" | "Medium" | "High").
        """
        booked_min = self._to_minutes(booked)
        s = to_min(start)
        lo = max(to_min(config.OPEN_TIME), s - 30)
        hi = min(to_min(config.CLOSE_TIME), s + duration + 30)
        units = list(range(lo, hi, self.slot)) or [s]
        ratio = sum(min(1.0, self._count_at(u, booked_min) / capacity) for u in units) / len(units)
        if ratio < 0.34:
            label = "Low"
        elif ratio < 0.67:
            label = "Medium"
        else:
            label = "High"
        return ratio, label
