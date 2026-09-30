"""
All SQL lives here (the "repository" / data-access layer).
The rest of the program never writes SQL - it calls these methods.
Methods with a `cur` argument run inside the caller's transaction.
"""

from datetime import datetime

from database import Database
from exceptions import (InvalidServiceError, InvalidSubServiceError, CitizenNotFoundError)
from models import SubServiceInfo, SystemSettings, Token, to_time

_TOKEN_SELECT = """
    SELECT t.token_id, t.token_no, t.citizen_id, t.sub_service_id, t.visit_date,
           t.slot_start, t.slot_end, t.status, t.booked_at, t.served_at,
           c.name, c.age, c.contact,
            s.name AS service_type, ss.name AS sub_service, ss.avg_minutes,
            os.arrive_early_minutes, os.open_time AS office_open_time
    FROM tokens t
    JOIN citizens c      ON c.citizen_id = t.citizen_id
    JOIN sub_services ss ON ss.sub_service_id = t.sub_service_id
    JOIN services s      ON s.service_id = ss.service_id
        JOIN office_settings os ON os.setting_id = 1
"""


class QueueRepository:
    def __init__(self, db: Database):
        self.db = db

    def transaction(self):
        return self.db.transaction()

    # ---------------- catalogue ----------------

    def get_catalog(self):
        """{service_name: [request type names]} in display order."""
        rows = self.db.fetch_all(
            "SELECT s.name AS service, ss.name AS sub "
            "FROM services s JOIN sub_services ss ON ss.service_id = s.service_id "
            "ORDER BY s.service_id, ss.sub_service_id")
        catalog = {}
        for r in rows:
            catalog.setdefault(r["service"], []).append(r["sub"])
        return catalog

    def get_sub_service(self, service_type, sub_service, cur=None):
        row = self.db.fetch_one(
            "SELECT ss.sub_service_id, ss.service_id, s.name AS service_type, ss.name, "
            "       ss.abbrev, s.token_prefix AS prefix, ss.avg_minutes, "
            "       COALESCE(ss.documents_required, '') AS documents, s.num_counters "
            "FROM sub_services ss JOIN services s ON s.service_id = ss.service_id "
            "WHERE s.name = %s AND ss.name = %s", (service_type, sub_service), cur)
        if row:
            return SubServiceInfo(**row)
        if not self.db.fetch_one("SELECT 1 AS x FROM services WHERE name = %s", (service_type,), cur):
            raise InvalidServiceError(service_type)
        raise InvalidSubServiceError(sub_service, service_type)

    # ---------------- booking ----------------

    def lock_service(self, cur, service_id):
        """Serialise bookings for one department so two people never get the same slot."""
        self.db.fetch_one("SELECT service_id FROM services WHERE service_id = %s FOR UPDATE",
                          (service_id,), cur)

    def booked_intervals(self, service_id, visit_date, cur=None):
        rows = self.db.fetch_all(
            "SELECT t.slot_start, t.slot_end FROM tokens t "
            "JOIN sub_services ss ON ss.sub_service_id = t.sub_service_id "
            "WHERE ss.service_id = %s AND t.visit_date = %s "
            "AND t.status IN ('WAITING', 'SERVED')", (service_id, visit_date), cur)
        return [(to_time(r["slot_start"]), to_time(r["slot_end"])) for r in rows]

    def get_or_create_citizen(self, cur, name, age, contact, now):
        row = self.db.fetch_one(
            "SELECT citizen_id FROM citizens WHERE contact = %s AND name = %s LIMIT 1",
            (contact, name), cur)
        if row:
            self.db.execute("UPDATE citizens SET age = %s WHERE citizen_id = %s",
                            (age, row["citizen_id"]), cur)
            return row["citizen_id"]
        return self.db.insert(
            "INSERT INTO citizens (name, age, contact, created_at) VALUES (%s, %s, %s, %s)",
            (name, age, contact, now), cur)

    def next_token_number(self, cur, sub_service_id):
        """Atomic counter - safe even if two people book at the same moment."""
        self.db.execute("INSERT IGNORE INTO token_sequences (sub_service_id, last_number) "
                        "VALUES (%s, 0)", (sub_service_id,), cur)
        self.db.execute("UPDATE token_sequences SET last_number = LAST_INSERT_ID(last_number + 1) "
                        "WHERE sub_service_id = %s", (sub_service_id,), cur)
        return self.db.fetch_one("SELECT LAST_INSERT_ID() AS n", (), cur)["n"]

    def insert_token(self, cur, token_no, citizen_id, sub_service_id, visit_date,
                     slot_start, slot_end, booked_at):
        return self.db.insert(
            "INSERT INTO tokens (token_no, citizen_id, sub_service_id, visit_date, "
            "slot_start, slot_end, status, booked_at) VALUES (%s,%s,%s,%s,%s,%s,'WAITING',%s)",
            (token_no, citizen_id, sub_service_id, visit_date, slot_start, slot_end, booked_at), cur)

    # ---------------- token lookups ----------------

    def get_token(self, token_no, cur=None):
        row = self.db.fetch_one(_TOKEN_SELECT + " WHERE t.token_no = %s", (token_no,), cur)
        if not row:
            raise CitizenNotFoundError(token_no)
        return Token.from_row(row)

    def _get_token_by_id(self, token_id, cur=None):
        return Token.from_row(
            self.db.fetch_one(_TOKEN_SELECT + " WHERE t.token_id = %s", (token_id,), cur))

    def waiting_list(self, sub_service_id, visit_date):
        rows = self.db.fetch_all(
            _TOKEN_SELECT + " WHERE t.sub_service_id = %s AND t.visit_date = %s "
            "AND t.status = 'WAITING' ORDER BY t.slot_start, t.token_id",
            (sub_service_id, visit_date))
        return [Token.from_row(r) for r in rows]

    def people_ahead(self, token: Token):
        row = self.db.fetch_one(
            "SELECT COUNT(*) AS n FROM tokens WHERE sub_service_id = %s AND visit_date = %s "
            "AND status = 'WAITING' AND (slot_start < %s OR (slot_start = %s AND token_id < %s))",
            (token.sub_service_id, token.visit_date, token.slot_start,
             token.slot_start, token.token_id))
        return row["n"]

    # ---------------- staff actions ----------------

    def serve_next(self, sub_service_id, visit_date, now):
        """Mark the next waiting person (earliest slot first) as SERVED. Returns Token or None."""
        with self.db.transaction() as cur:
            row = self.db.fetch_one(
                "SELECT token_id FROM tokens WHERE sub_service_id = %s AND visit_date = %s "
                "AND status = 'WAITING' ORDER BY slot_start, token_id LIMIT 1 FOR UPDATE",
                (sub_service_id, visit_date), cur)
            if not row:
                return None
            self.db.execute("UPDATE tokens SET status = 'SERVED', served_at = %s "
                            "WHERE token_id = %s", (now, row["token_id"]), cur)
            return self._get_token_by_id(row["token_id"], cur)

    def cancel_token(self, token_no):
        return self.db.execute(
            "UPDATE tokens SET status = 'CANCELLED' WHERE token_no = %s AND status = 'WAITING'",
            (token_no,))

    def expire_old_tokens(self, today):
        """Tokens still WAITING from a past day were never used."""
        return self.db.execute(
            "UPDATE tokens SET status = 'EXPIRED' WHERE status = 'WAITING' AND visit_date < %s",
            (today,))

    # ---------------- reports ----------------

    def summary(self, day):
        rows = self.db.fetch_all(
            "SELECT s.name AS service_type, ss.name AS sub_service, "
            "  COALESCE(SUM(t.status = 'WAITING'), 0)   AS waiting, "
            "  COALESCE(SUM(t.status = 'SERVED'), 0)    AS served, "
            "  COALESCE(SUM(t.status = 'CANCELLED'), 0) AS cancelled "
            "FROM sub_services ss JOIN services s ON s.service_id = ss.service_id "
            "LEFT JOIN tokens t ON t.sub_service_id = ss.sub_service_id AND t.visit_date = %s "
            "GROUP BY s.service_id, ss.sub_service_id, s.name, ss.name "
            "ORDER BY s.service_id, ss.sub_service_id", (day,))
        return [(r["service_type"], r["sub_service"], int(r["waiting"]),
                 int(r["served"]), int(r["cancelled"])) for r in rows]

    def busiest_hour(self, day):
        row = self.db.fetch_one(
            "SELECT HOUR(slot_start) AS hr, COUNT(*) AS n FROM tokens "
            "WHERE visit_date = %s AND status IN ('WAITING', 'SERVED') "
            "GROUP BY HOUR(slot_start) ORDER BY n DESC, hr LIMIT 1", (day,))
        return (row["hr"], row["n"]) if row else None

    # ---------------- holidays & log ----------------

    def load_holidays(self):
        rows = self.db.fetch_all("SELECT holiday_date, name FROM holidays ORDER BY holiday_date")
        return {r["holiday_date"]: r["name"] for r in rows}

    def load_settings(self):
        row = self.db.fetch_one("SELECT * FROM office_settings WHERE setting_id = 1")
        if not row:
            raise RuntimeError("Office settings are missing. Run: python src/setup_db.py")
        return SystemSettings(
            open_time=to_time(row["open_time"]),
            close_time=to_time(row["close_time"]),
            closed_weekdays=frozenset(int(day) for day in row["closed_weekdays"].split(",") if day),
            lunch_start=to_time(row["lunch_start"]) if row["lunch_start"] is not None else None,
            lunch_end=to_time(row["lunch_end"]) if row["lunch_end"] is not None else None,
            slot_minutes=row["slot_minutes"],
            arrive_early_minutes=row["arrive_early_minutes"],
            max_advance_days=row["max_advance_days"],
        )

    def save_report(self, day, generated_at, report_text):
        return self.db.insert(
            "INSERT INTO report_snapshots (report_date, generated_at, report_text) "
            "VALUES (%s, %s, %s)", (day, generated_at, report_text))

    def add_holiday(self, day, name):
        self.db.execute("REPLACE INTO holidays (holiday_date, name) VALUES (%s, %s)", (day, name))

    def remove_holiday(self, day):
        return self.db.execute("DELETE FROM holidays WHERE holiday_date = %s", (day,))

    def log(self, message, now=None, cur=None):
        """Write to activity_log. Never crashes the app."""
        try:
            self.db.execute("INSERT INTO activity_log (logged_at, message) VALUES (%s, %s)",
                            (now or datetime.now(), message[:500]), cur)
        except Exception:
            if cur is None:
                print(f"(logging failed) {message}")
