"""
One-time database setup.

    python src/setup_db.py            create the database, tables and starting data
    python src/setup_db.py --reset    DELETE the database and build it again from scratch

Safe to run more than once (it will not duplicate data).
"""

import re
import sys
from datetime import datetime

import mysql.connector

import config

# service -> (token prefix, number of counters, [(request type, abbrev, minutes at counter, documents)])
SERVICES = {
    "Passport": ("PA", 2, [
        ("New Passport Application", "NEW", 45,
         "Proof of address, proof of date of birth, ID proof, passport-size photos, online application (ARN) printout."),
        ("Passport Renewal", "REN", 30,
         "Old passport (original + photocopy of first and last pages), address proof, online application printout."),
        ("Reissue - Lost or Damaged", "RIS", 30,
         "Police complaint copy (if lost) or the damaged passport, address proof, ID proof, online application printout."),
        ("Address Change", "ADR", 20,
         "Old passport, new address proof, online application printout."),
    ]),
    "Driving License": ("DL", 2, [
        ("New License", "NEW", 30,
         "Learner's licence, age proof, address proof, passport-size photos, medical certificate (if required)."),
        ("License Renewal", "REN", 20,
         "Old driving licence, address proof, passport-size photo, medical certificate (if above 40)."),
        ("Duplicate License", "DUP", 15,
         "FIR / police complaint copy, ID proof, address proof, passport-size photo."),
        ("Address Update", "ADR", 15,
         "Driving licence, new address proof."),
    ]),
    "Aadhar Card": ("AC", 3, [
        ("New Enrollment", "NEW", 30,
         "Proof of identity, proof of address, proof of date of birth (original documents). "
         "For children under 5: parent's Aadhaar and the child's birth certificate."),
        ("Date of Birth Update", "DOB", 30,
         "Aadhaar card / number, valid proof of date of birth (birth certificate, school certificate or passport)."),
        ("Address Update", "ADR", 15,
         "Aadhaar card / number, valid proof of address (passport, bank statement, ration card, recent utility bill or rent agreement)."),
        ("Name Correction", "NAME", 20,
         "Aadhaar card / number, proof of identity that shows the correct name (passport, PAN, voter ID or driving licence)."),
        ("Mobile Number Update", "MOB", 10,
         "Aadhaar card / number. You must come in person - your fingerprints are checked."),
        ("Photo Update", "PHO", 15,
         "Aadhaar card / number. Your new photo is taken at the counter; no other document is needed."),
    ]),
    "Birth Certificate": ("BC", 1, [
        ("New Registration", "NEW", 20,
         "Hospital birth/discharge report, parents' ID and address proof, parents' marriage certificate."),
        ("Correction", "COR", 20,
         "Original certificate, proof of the correct details, parent's ID proof."),
        ("Duplicate Copy", "DUP", 10,
         "Details of the registration (date and place of birth, parents' names), applicant's ID proof."),
    ]),
    "Income Certificate": ("IC", 1, [
        ("New Application", "NEW", 20,
         "Ration card / Aadhaar, address proof, salary slips or self-declaration of income, passport-size photo."),
        ("Certificate Renewal", "REN", 15,
         "Old income certificate, updated income proof, Aadhaar."),
        ("Correction", "COR", 15,
         "Original certificate, proof of the correct details, Aadhaar."),
    ]),
}


def _split_sql(text):
    """Split schema.sql into single statements (ignores '--' comment lines)."""
    lines = [ln for ln in text.splitlines() if not ln.strip().startswith("--")]
    return [s.strip() for s in "\n".join(lines).split(";") if s.strip()]


def _read_holidays_file(path):
    """Import holidays from the old text file (format: YYYY-MM-DD|Name)."""
    found = []
    if not path.exists():
        return found
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split("|")
        try:
            day = datetime.strptime(parts[0].strip(), "%Y-%m-%d").date()
        except ValueError:
            continue
        found.append((day, parts[1].strip() if len(parts) > 1 else "Public Holiday"))
    return found


def setup(database=None, reset=False):
    db_name = database or config.DB_NAME
    if not re.fullmatch(r"[A-Za-z0-9_]+", db_name):
        raise ValueError("Database name may contain only letters, digits and underscore.")
    server_cfg = {k: v for k, v in config.DB_CONFIG.items() if k != "database"}

    conn = mysql.connector.connect(**server_cfg)
    cur = conn.cursor()
    if reset:
        cur.execute(f"DROP DATABASE IF EXISTS `{db_name}`")
    cur.execute(f"CREATE DATABASE IF NOT EXISTS `{db_name}` CHARACTER SET utf8mb4")
    cur.execute(f"USE `{db_name}`")

    for statement in _split_sql(config.SCHEMA_FILE.read_text(encoding="utf-8")):
        cur.execute(statement)

    cur.execute(
        "INSERT IGNORE INTO office_settings "
        "(setting_id, open_time, close_time, closed_weekdays, lunch_start, lunch_end, "
        "slot_minutes, arrive_early_minutes, max_advance_days) "
        "VALUES (1, %s, %s, %s, %s, %s, %s, %s, %s)",
        (config.OPEN_TIME, config.CLOSE_TIME,
         ",".join(str(day) for day in sorted(config.CLOSED_WEEKDAYS)),
         config.LUNCH_START, config.LUNCH_END, config.SLOT_MINUTES,
         config.ARRIVE_EARLY_MINUTES, config.MAX_ADVANCE_DAYS))

    for service, (prefix, counters, subs) in SERVICES.items():
        cur.execute("INSERT IGNORE INTO services (name, token_prefix, num_counters) VALUES (%s,%s,%s)",
                    (service, prefix, counters))
        cur.execute("SELECT service_id FROM services WHERE name = %s", (service,))
        service_id = cur.fetchone()[0]
        for name, abbrev, minutes, documents in subs:
            cur.execute(
                "INSERT INTO sub_services (service_id, name, abbrev, avg_minutes, documents_required) "
                "VALUES (%s,%s,%s,%s,%s) "
                "ON DUPLICATE KEY UPDATE avg_minutes = VALUES(avg_minutes), "
                "documents_required = VALUES(documents_required)",
                (service_id, name, abbrev, minutes, documents))

    cur.execute("INSERT IGNORE INTO token_sequences (sub_service_id, last_number) "
                "SELECT sub_service_id, 0 FROM sub_services")

    for day, name in _read_holidays_file(config.HOLIDAYS_FILE):
        cur.execute("INSERT IGNORE INTO holidays (holiday_date, name) VALUES (%s,%s)", (day, name))

    conn.commit()
    cur.close()
    conn.close()
    return db_name


if __name__ == "__main__":
    try:
        name = setup(reset="--reset" in sys.argv)
        print(f"Database '{name}' is ready. You can now run:  python src/main.py")
    except mysql.connector.Error as e:
        print(f"Could not set up the database: {e}")
        print("Check DB_HOST / DB_USER / DB_PASSWORD in your .env file and that MySQL is running.")
        sys.exit(1)
