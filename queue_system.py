"""
GovernmentQueueSystem - the central controller (business logic).

It combines the repository (MySQL), the business-hours rules and the slot
scheduler. New in this version:
  * every token has a booked TIME SLOT  -> "what time should I come?"
  * earliest-slot and least-crowded-slot recommendations
  * check / cancel a token, people-ahead count, arrival advice
"""

from datetime import datetime, timedelta

import config
from exceptions import (
    InvalidDateError, NoSlotsAvailableError, QueueEmptyError,
    ServiceClosedError, SlotUnavailableError
)
from models import Recommendation, Slot, Token, add_minutes, fmt_date, fmt_time
from repository import QueueRepository
from scheduler import SlotScheduler
from service_hours import BusinessHours


class GovernmentQueueSystem:
    def __init__(self, repo: QueueRepository, hours: BusinessHours,
                 scheduler: SlotScheduler = None, clock=None):
        self.repo = repo
        self.hours = hours
        self.scheduler = scheduler or SlotScheduler(hours)
        self._now = clock or datetime.now      # a fake clock can be passed in for testing

    def now(self):
        return self._now()

    # ---------------- catalogue ----------------

    def get_catalog(self):
        return self.repo.get_catalog()

    def get_sub_services(self, service_type):
        catalog = self.repo.get_catalog()
        if service_type not in catalog:
            self.repo.get_sub_service(service_type, "")     # raises InvalidServiceError
        return catalog[service_type]

    def get_sub_service_info(self, service_type, sub_service):
        return self.repo.get_sub_service(service_type, sub_service)

    # ---------------- slots & recommendations ----------------

    def _check_date(self, day, now):
        if day < now.date():
            raise InvalidDateError("You cannot choose a date in the past.")
        if day > now.date() + timedelta(days=config.MAX_ADVANCE_DAYS):
            raise InvalidDateError(
                f"Bookings open only {config.MAX_ADVANCE_DAYS} days ahead "
                f"(up to {fmt_date(now.date() + timedelta(days=config.MAX_ADVANCE_DAYS))}).")

    def _slots_for_day(self, info, day, now, cur=None):
        duration = self.scheduler.round_duration(info.avg_minutes)
        booked = self.repo.booked_intervals(info.service_id, day, cur)
        starts = self.scheduler.available_starts(day, duration, info.num_counters, booked, now)
        slots = []
        for s in starts:
            ratio, label = self.scheduler.crowd(s, duration, info.num_counters, booked)
            slots.append(Slot(day, s, add_minutes(s, duration), label, ratio))
        return slots

    def available_slots(self, service_type, sub_service, day):
        """All free slots for one request type on one date."""
        info = self.repo.get_sub_service(service_type, sub_service)
        now = self._now()
        self._check_date(day, now)
        return self._slots_for_day(info, day, now)

    def recommend(self, service_type, sub_service, working_days=7, top=3):
        """
        Suggest when to come:
          earliest  - the first free slot from right now
          quietest  - the least crowded slot on each of the next few working days
        """
        info = self.repo.get_sub_service(service_type, sub_service)
        now = self._now()
        earliest, per_day_best, seen_days = None, [], 0
        for offset in range(config.MAX_ADVANCE_DAYS + 1):
            if seen_days >= working_days:
                break
            day = now.date() + timedelta(days=offset)
            if not self.hours.is_working_day(day):
                continue
            slots = self._slots_for_day(info, day, now)
            if not slots:
                continue                      # e.g. today after closing time
            seen_days += 1
            if earliest is None:
                earliest = slots[0]
            per_day_best.append(min(slots, key=lambda s: (s.crowd_ratio, s.start)))
        if earliest is None:
            raise NoSlotsAvailableError(
                f"No free slots for {service_type} - {sub_service} in the next "
                f"{config.MAX_ADVANCE_DAYS} days.")
        quietest = sorted(per_day_best, key=lambda s: (s.crowd_ratio, s.date))[:top]
        return Recommendation(earliest=earliest, quietest=sorted(quietest, key=lambda s: s.date))

    # ---------------- booking ----------------

    def book(self, name, age, contact, service_type, sub_service, visit_date=None, slot_start=None):
        """
        Book a token.
          * no date, no time  -> earliest free slot from now
          * date only         -> earliest free slot on/after that date
          * date + time       -> that exact slot (error if it is taken)

        Python picks the slot (SlotScheduler); the stored procedure sp_book_token
        then re-checks capacity under a lock and saves everything in one
        transaction. If somebody else grabbed the slot in between, we look again.
        """
        info = self.repo.get_sub_service(service_type, sub_service)
        now = self._now()
        duration = self.scheduler.round_duration(info.avg_minutes)
        start_day = visit_date or now.date()
        self._check_date(start_day, now)
        exact = slot_start is not None

        for attempt in range(3):
            if exact:
                day, start = start_day, slot_start
                free = self._slots_for_day(info, day, now)
                if start not in [sl.start for sl in free]:
                    reason = self.hours.closed_reason_for_date(day)
                    if reason:
                        raise SlotUnavailableError(
                            f"The office is closed on {fmt_date(day)}: {reason}.")
                    raise SlotUnavailableError(
                        f"The {fmt_time(start)} slot on {fmt_date(day)} is no longer available.")
            else:
                day, start = self._first_free(info, start_day, now)

            try:
                token_no = self.repo.book_token(name, age, contact, info.sub_service_id, day,
                                                start, add_minutes(start, duration), now)
                return self.repo.get_token(token_no)
            except SlotUnavailableError:
                if exact or attempt == 2:       # lost a race: retry only for "earliest" bookings
                    raise
        raise NoSlotsAvailableError("Could not find a free slot. Please try again.")

    def _first_free(self, info, start_day, now, cur=None):
        last_day = now.date() + timedelta(days=config.MAX_ADVANCE_DAYS)
        day = start_day
        while day <= last_day:
            if self.hours.is_working_day(day):
                slots = self._slots_for_day(info, day, now, cur)
                if slots:
                    return day, slots[0].start
            day += timedelta(days=1)
        raise NoSlotsAvailableError(
            f"No free slots for {info.service_type} - {info.name} in the next "
            f"{config.MAX_ADVANCE_DAYS} days.")

    # ---------------- check / cancel ----------------

    def check_token(self, token_no):
        """Returns (token, people_ahead, advice_text)."""
        token = self.repo.get_token(token_no)
        ahead = self.repo.people_ahead(token) if token.status == "WAITING" else 0
        return token, ahead, self.visit_advice(token, ahead)

    def visit_advice(self, token, ahead=0):
        """Plain-language answer to 'when should I come?'."""
        now = self._now()
        slot = f"{fmt_time(token.slot_start)} - {fmt_time(token.slot_end)}"
        if token.status == "SERVED":
            return f"Already served on {token.served_at:%d-%b-%Y at %I:%M %p}."
        if token.status == "CANCELLED":
            return "This token was cancelled."
        if token.status == "EXPIRED":
            return "This token expired because the visit date has passed."
        if token.visit_date > now.date():
            days = (token.visit_date - now.date()).days
            return (f"Come on {fmt_date(token.visit_date)} ({days} day{'s' if days != 1 else ''} to go). "
                    f"Your slot is {slot} - please reach by {fmt_time(token.arrive_by)}.")
        # visit date is today
        slot_start_dt = datetime.combine(token.visit_date, token.slot_start)
        slot_end_dt = datetime.combine(token.visit_date, token.slot_end)
        if now < slot_start_dt:
            return (f"Come TODAY. Your slot is {slot} - please reach by "
                    f"{fmt_time(token.arrive_by)}. People ahead of you: {ahead}.")
        if now <= slot_end_dt:
            return f"Your slot ({slot}) is NOW. Please go to the counter. People ahead: {ahead}."
        return (f"Your slot ({slot}) has passed. Please report to the counter now; you will be "
                f"called in queue order. People ahead: {ahead}.")

    def cancel_token(self, token_no, contact):
        """The phone-number and status checks happen inside sp_cancel_token."""
        token_no = token_no.upper()
        self.repo.cancel_token(token_no, contact)
        return self.repo.get_token(token_no)

    # ---------------- staff operations ----------------

    def serve_next(self, service_type, sub_service):
        now = self._now()
        if not self.hours.is_open(now):
            raise ServiceClosedError(self.hours.status_message(now))
        info = self.repo.get_sub_service(service_type, sub_service)
        token = self.repo.serve_next(info.sub_service_id, now.date(), now)
        if token is None:
            raise QueueEmptyError(service_type, sub_service)
        return token                      # the trigger trg_tokens_au logs WAITING -> SERVED

    def get_queue_status(self, service_type, sub_service):
        info = self.repo.get_sub_service(service_type, sub_service)
        return self.repo.waiting_list(info.sub_service_id, self._now().date())

    def counters_summary(self, day=None):
        return self.repo.summary(day or self._now().date())

    def expire_old_tokens(self):
        return self.repo.expire_old_tokens(self._now().date())

    # ---------------- advanced reports (views, cursor, triggers) ----------------

    def hourly_report(self, day=None):
        return self.repo.hourly_report(day or self._now().date())

    def service_performance(self):
        return self.repo.service_performance()

    def recent_activity(self, limit=15):
        return self.repo.recent_activity(limit)

    # ---------------- holidays ----------------

    def add_holiday(self, day, name):
        self.repo.add_holiday(day, name)
        self.hours.reload()

    def remove_holiday(self, day):
        removed = self.repo.remove_holiday(day)
        self.hours.reload()
        return removed
