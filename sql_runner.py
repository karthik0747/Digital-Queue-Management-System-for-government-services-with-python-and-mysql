"""
Runs .sql script files from Python.

mysql-connector cannot understand the `DELIMITER $$` command that MySQL
Workbench / the mysql client use for stored procedures, so this small parser
splits a script into single statements and understands DELIMITER itself.
The same .sql files therefore also run unchanged in Workbench or the CLI.
"""

from pathlib import Path


def split_statements(text):
    """Split a script into statements, honouring `DELIMITER xx` lines."""
    statements, buffer, delimiter = [], [], ";"
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.upper().startswith("DELIMITER "):
            delimiter = stripped.split(None, 1)[1].strip()
            continue
        if not stripped or stripped.startswith("--"):
            continue                                   # blank / comment-only line
        buffer.append(line)
        if stripped.endswith(delimiter):
            statement = "\n".join(buffer).rstrip()
            statements.append(statement[: -len(delimiter)].rstrip())
            buffer = []
    if buffer:                                         # last statement without delimiter
        statements.append("\n".join(buffer).strip())
    return [s for s in statements if s]


def execute(cursor, statement):
    """
    Run ONE statement and return (rows, column_names). rows is None for
    statements without a result set. Leftover result sets (a CALL to a
    procedure leaves an extra OK packet) are drained so the next statement
    starts clean.
    """
    cursor.execute(statement)
    rows, columns = None, None
    if cursor.with_rows:
        columns = [d[0] for d in cursor.description]
        rows = cursor.fetchall()
    while cursor.nextset():
        if cursor.with_rows:
            cursor.fetchall()
    return rows, columns


def run_script(cursor, text):
    """Execute every statement; returns how many were run."""
    statements = split_statements(text)
    for statement in statements:
        execute(cursor, statement)
    return len(statements)


def run_file(cursor, path):
    return run_script(cursor, Path(path).read_text(encoding="utf-8"))
