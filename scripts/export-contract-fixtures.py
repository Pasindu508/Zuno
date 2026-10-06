#!/usr/bin/env python3
"""Exports real server responses as JSON fixtures for the iOS contract tests.

Creates a throwaway PostgreSQL cluster (PG_BIN), applies the Supabase stubs, every
migration and seed.sql, then runs the client-facing RPCs/views as the seeded users and
writes each JSON result to ZunoTests/Fixtures/contract/<name>.json. The iOS unit test
`ContractFixtureTests` decodes every file with the app's DTOs, so a mismatch between the
SQL and the Swift client fails the build's tests.

Usage: PG_BIN=/path/to/postgres/bin python3 scripts/export-contract-fixtures.py
LOCAL VERIFICATION ONLY.
"""
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "supabase" / "tests" / "support"))
import pgwire  # noqa: E402

PG_BIN = pathlib.Path(os.environ.get("PG_BIN", ""))
PORT = int(os.environ.get("ZUNO_FIXTURE_PORT", "54331"))
OUT = ROOT / "ZunoTests" / "Fixtures" / "contract"

DEV_USER = "b0000000-0000-4000-8000-0000000000aa"
BUILDERS_OWNER = "a0000000-0000-4000-8000-000000000001"
KANDYAN = "e1000000-0000-4000-8000-000000000003"
JAFFNA = "e1000000-0000-4000-8000-000000000005"
HACKATHON = "e1000000-0000-4000-8000-000000000001"
JUNIOR_CRICKET = "e1000000-0000-4000-8000-000000000014"


def as_user(user):
    return ("select set_config('request.jwt.claims', json_build_object('sub', '%s', 'role', 'authenticated')::text, false);"
            "set role authenticated;" % user)


AS_ANON = "select set_config('request.jwt.claims', '{\"role\":\"anon\"}', false); set role anon;"
RESET = "reset role; select set_config('request.jwt.claims', '', false);"

QUERIES = [
    # (fixture name, impersonation, SQL returning one json value)
    ("categories", AS_ANON, "select json_agg(c order by sort_order) from public.categories c"),
    ("search_events_anon", AS_ANON, "select json_agg(e) from public.search_events(null, '{}'::jsonb, 50, 0) e"),
    ("search_events_filtered", as_user(DEV_USER),
     "select coalesce(json_agg(e), '[]'::json) from public.search_events('kandy', '{\"price\":\"paid\",\"available_only\":true}'::jsonb, 20, 0) e"),
    ("event_detail_paid", as_user(DEV_USER), "select public.get_event_detail('%s')" % KANDYAN),
    ("event_detail_free", as_user(DEV_USER), "select public.get_event_detail('%s')" % HACKATHON),
    ("quote_free_registration", as_user(DEV_USER), "select public.quote_free_registration('%s')" % JAFFNA),
    ("my_tickets", as_user(DEV_USER), "select public.my_tickets()"),
    ("my_registrations", as_user(DEV_USER), "select public.my_registrations()"),
    ("wallet_summary", as_user(DEV_USER), "select public.wallet_summary()"),
    ("wallet_ledger", as_user(DEV_USER),
     "select json_agg(l order by created_at desc) from (select id, entry_type, amount_minor, balance_after_minor, status, "
     "reference_type, reference_id, description, created_at from public.wallet_ledger) l"),
    ("notifications", as_user(DEV_USER),
     "select coalesce(json_agg(n order by created_at desc), '[]'::json) from (select id, kind, title, body, event_id, read_at, created_at from public.notifications) n"),
    ("notification_preferences", as_user(DEV_USER),
     "select json_agg(p) from (select event_reminders, payment_updates, event_changes, waitlist_updates, organizer_news, push_enabled from public.notification_preferences) p"),
    ("profile", as_user(DEV_USER), "select json_agg(p) from public.profiles p"),
    ("organizer_dashboard", as_user(BUILDERS_OWNER), "select public.organizer_dashboard()"),
    ("organizer_event_stats", as_user(BUILDERS_OWNER), "select public.organizer_event_stats('%s')" % JUNIOR_CRICKET),
    ("organizer_attendees", as_user(BUILDERS_OWNER), "select public.organizer_attendees('%s')" % HACKATHON),
    ("organizer_settlements", as_user(BUILDERS_OWNER), "select public.organizer_settlements()"),
    ("check_in_invalid", as_user(BUILDERS_OWNER), "select public.check_in_ticket('%s', 'ZN-NOPE-NOPE')" % HACKATHON),
    ("venues", as_user(BUILDERS_OWNER),
     "select json_agg(v) from (select id, name, address_line, city, district, latitude, longitude from public.venues) v"),
]

# Mutations run inside a transaction that is rolled back.
MUTATIONS = [
    ("register_for_free_event", as_user(DEV_USER),
     "select public.register_for_free_event('%s', '[]'::jsonb, 0, 'fixture-key-0001')" % JAFFNA),
    ("join_waitlist_error", as_user(DEV_USER), None),
]


def run(conn, sql):
    return conn.query(sql, print_rows=False, out=open(os.devnull, "w"))


def main():
    if not (PG_BIN / "initdb").exists():
        print("set PG_BIN to a directory containing initdb, pg_ctl and postgres", file=sys.stderr)
        return 2
    work = pathlib.Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR")))
    data = work / "cluster"
    subprocess.run([PG_BIN / "initdb", "-D", data, "-U", "postgres", "--auth=trust", "--encoding=UTF8", "--no-locale"],
                   check=True, capture_output=True)
    subprocess.run([PG_BIN / "pg_ctl", "-D", data, "-l", work / "pg.log", "-w", "-o",
                    "-p %d -c listen_addresses=127.0.0.1 -c unix_socket_directories='' -c fsync=off -c timezone=UTC" % PORT,
                    "start"], check=True, capture_output=True)
    try:
        admin = pgwire.Connection("127.0.0.1", PORT, "postgres", "postgres")
        run(admin, "create database zuno_fixtures")
        admin.close()
        conn = pgwire.Connection("127.0.0.1", PORT, "postgres", "zuno_fixtures")
        files = [ROOT / "supabase/tests/support/supabase_stubs.sql"] + sorted((ROOT / "supabase/migrations").glob("*.sql")) \
            + [ROOT / "supabase/seed.sql"]
        for path in files:
            run(conn, path.read_text())
        OUT.mkdir(parents=True, exist_ok=True)
        for name, role, sql in QUERIES:
            run(conn, role)
            rows = run(conn, sql)
            run(conn, RESET)
            value = json.loads(rows[0][0]) if rows and rows[0][0] is not None else None
            (OUT / ("%s.json" % name)).write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
            print("exported %-28s %s" % (name, "null" if value is None else type(value).__name__))
        for name, role, sql in MUTATIONS:
            if sql is None:
                continue
            run(conn, "begin")
            run(conn, role)
            rows = run(conn, sql)
            run(conn, "rollback")
            run(conn, RESET)
            (OUT / ("%s.json" % name)).write_text(json.dumps(json.loads(rows[0][0]), indent=2, ensure_ascii=False) + "\n")
            print("exported %-28s (rolled back)" % name)
        conn.close()
    finally:
        subprocess.run([PG_BIN / "pg_ctl", "-D", data, "-m", "fast", "-w", "stop"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
