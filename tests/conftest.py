"""Isolated pytest database fixtures.

Set DATABASE_URL to a dedicated disposable test database. Tests fail fast if
the database name does not look like a test database.
"""
from __future__ import annotations

import os
from urllib.parse import urlparse

import psycopg
import pytest


def _dsn() -> str:
    return os.environ.get(
        "DATABASE_URL",
        "postgresql://subly:subly@localhost:5432/subly_test_test",
    )


@pytest.fixture(scope="session")
def dsn() -> str:
    value = _dsn()
    parsed = urlparse(value)
    database = parsed.path.lstrip("/").lower()
    if not database.endswith(("_test", "_test_db", "test")):
        raise RuntimeError(
            f"Refusing to run tests against database {database!r}; "
            "set DATABASE_URL to a dedicated database ending in 'test'."
        )
    return value


@pytest.fixture()
def conn(dsn: str):
    """A fresh connection per test; always roll back test changes."""
    connection = psycopg.connect(dsn)
    try:
        yield connection
    finally:
        if not connection.closed:
            connection.rollback()
            connection.close()


@pytest.fixture()
def cur(conn):
    with conn.cursor() as cursor:
        yield cursor
