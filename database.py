"""
MySQL connection handling.

Every query goes through a pooled connection. `transaction()` gives you a
cursor and automatically COMMITs when the block ends fine, or ROLLBACKs if
anything goes wrong - so a booking is either fully saved or not saved at all.
"""

from contextlib import contextmanager

import mysql.connector
from mysql.connector import pooling

import config
from exceptions import DatabaseError

MySQLError = mysql.connector.Error


class Database:
    def __init__(self, db_config=None, pool_size=5, pool_name="queue_pool"):
        self._config = dict(db_config or config.DB_CONFIG)
        try:
            self._pool = pooling.MySQLConnectionPool(
                pool_name=pool_name, pool_size=pool_size, **self._config
            )
        except MySQLError as e:
            raise DatabaseError(f"Cannot connect to MySQL: {e}") from e

    @contextmanager
    def transaction(self):
        """Yield a dict-cursor; commit on success, rollback on any error."""
        try:
            conn = self._pool.get_connection()
        except MySQLError as e:
            raise DatabaseError(f"Cannot connect to MySQL: {e}") from e
        cur = conn.cursor(dictionary=True)
        try:
            yield cur
            conn.commit()
        except MySQLError as e:
            self._safe_rollback(conn)
            raise DatabaseError(f"Database error: {e}") from e
        except Exception:
            self._safe_rollback(conn)
            raise
        finally:
            cur.close()
            conn.close()          # returns the connection to the pool

    @staticmethod
    def _safe_rollback(conn):
        try:
            conn.rollback()
        except MySQLError:
            pass

    # ---- small helpers used by the repository ----
    # If `cur` is given the statement runs inside the caller's transaction.

    def fetch_all(self, sql, params=(), cur=None):
        if cur is not None:
            cur.execute(sql, params)
            return cur.fetchall()
        with self.transaction() as c:
            c.execute(sql, params)
            return c.fetchall()

    def fetch_one(self, sql, params=(), cur=None):
        rows = self.fetch_all(sql, params, cur)
        return rows[0] if rows else None

    def execute(self, sql, params=(), cur=None):
        """Run INSERT/UPDATE/DELETE. Returns the number of affected rows."""
        if cur is not None:
            cur.execute(sql, params)
            return cur.rowcount
        with self.transaction() as c:
            c.execute(sql, params)
            return c.rowcount

    def insert(self, sql, params=(), cur=None):
        """Run an INSERT and return the new auto-increment id."""
        if cur is not None:
            cur.execute(sql, params)
            return cur.lastrowid
        with self.transaction() as c:
            c.execute(sql, params)
            return c.lastrowid
