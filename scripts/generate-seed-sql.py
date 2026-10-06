#!/usr/bin/env python3
"""Generate supabase/seed.sql from supabase/seed/zuno_seed.json (stdlib only).

Usage:
    python3 scripts/generate-seed-sql.py            # writes supabase/seed.sql
    python3 scripts/generate-seed-sql.py --check    # exits 1 if seed.sql is stale

The generated SQL is LOCAL DEVELOPMENT ONLY: it creates sample auth users with
`.example` e-mail addresses and the placeholder password 'change-me-locally'.

Event dates in the JSON are relative (`start_offset_days` + `start_time` in
Asia/Colombo local time) and are resolved in SQL at the moment the seed runs,
so a fresh `supabase db reset` always produces upcoming events.
"""
import argparse
import json
import os
import sys
import uuid

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SOURCE = os.path.join(ROOT, "supabase", "seed", "zuno_seed.json")
TARGET = os.path.join(ROOT, "supabase", "seed.sql")

# Stable namespace so generated question ids never change between runs.
QUESTION_NAMESPACE = uuid.UUID("5b8f3c1e-7d2a-4e6b-9c0d-2a1f3e4b5c6d")
VENUE_NAMESPACE = uuid.UUID("0c7d9e2f-4a1b-4c3d-8e5f-6a7b8c9d0e1f")
INSTANCE_ID = "00000000-0000-0000-0000-000000000000"
LOCAL_PASSWORD = "change-me-locally"


def q(value):
    """SQL literal for str/int/float/bool/None."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def qjson(value):
    return q(json.dumps(value, ensure_ascii=False, separators=(",", ":"))) + "::jsonb"


def qarray(values):
    if not values:
        return "'{}'::text[]"
    return "array[" + ", ".join(q(v) for v in values) + "]::text[]"


def hours_interval(hours):
    seconds = int(round(float(hours) * 3600))
    return "make_interval(secs => %d)" % seconds


def fail(message):
    sys.stderr.write("generate-seed-sql: %s\n" % message)
    sys.exit(1)


def validate(data):
    categories = {c["id"] for c in data["categories"]}
    organizers = {o["id"] for o in data["organizers"]}
    venues = {v["id"]: v for v in data["venues"]}
    slugs = set()
    for v in data["venues"]:
        if v["organizer_id"] not in organizers:
            fail("venue %s references unknown organizer" % v["id"])
    for e in data["events"]:
        if e["category_id"] not in categories:
            fail("event %s has unknown category %s" % (e["slug"], e["category_id"]))
        if e["organizer_id"] not in organizers:
            fail("event %s has unknown organizer" % e["slug"])
        if e["venue_id"] and e["venue_id"] not in venues:
            fail("event %s has unknown venue" % e["slug"])
        if e["is_free"] and e["tiers"]:
            fail("free event %s has tiers" % e["slug"])
        if not e["is_free"] and not e["tiers"]:
            fail("paid event %s has no tiers" % e["slug"])
        for t in e["tiers"]:
            if t["sold"] > t["quantity"]:
                fail("tier %s oversold" % t["id"])
        slugs.add(e["slug"])
    dev = data["development_user"]
    for key in ("registered_event_slugs", "paid_ticket_event_slugs", "saved_event_slugs"):
        for slug in dev[key]:
            if slug not in slugs:
                fail("development_user.%s references unknown slug %s" % (key, slug))


def sample_answer(question):
    kind = question["kind"]
    if kind == "yes_no":
        return True
    if kind == "single_choice":
        return question["options"][0]
    if kind == "multi_choice":
        return [question["options"][0]]
    if kind == "long_text":
        return "Sample answer (local development seed)."
    return "Sample answer"


def question_id(event_id, index):
    return str(uuid.uuid5(QUESTION_NAMESPACE, "%s:%d" % (event_id, index)))


def resolve_shared_venues(data):
    """Venues belong to one organizer (events may only use their organizer's
    venues - enforced by private.events_validate). When the JSON points an event
    at another organizer's venue, give the event's organizer its own copy with a
    deterministic id so the data stays consistent with that rule."""
    venues = {v["id"]: v for v in data["venues"]}
    extra = {}
    for e in data["events"]:
        venue = venues.get(e["venue_id"]) if e["venue_id"] else None
        if venue and venue["organizer_id"] != e["organizer_id"]:
            copy_id = str(uuid.uuid5(VENUE_NAMESPACE, "%s:%s" % (e["organizer_id"], venue["id"])))
            if copy_id not in extra:
                copy = dict(venue)
                copy["id"] = copy_id
                copy["organizer_id"] = e["organizer_id"]
                extra[copy_id] = copy
            e["venue_id"] = copy_id
    data["venues"] = data["venues"] + list(extra.values())
    return len(extra)


def generate(data):
    shared = resolve_shared_venues(data)
    events_by_slug = {e["slug"]: e for e in data["events"]}
    organizers = data["organizers"]
    dev = data["development_user"]
    out = []
    w = out.append

    w("-- =============================================================================")
    w("-- Zuno development seed - GENERATED by scripts/generate-seed-sql.py from")
    w("-- supabase/seed/zuno_seed.json. Do not edit by hand; edit the JSON and re-run.")
    w("--")
    w("-- !!! LOCAL DEVELOPMENT ONLY !!!")
    w("-- * Creates sample auth users (organizer owners + one attendee) with *.example")
    w("--   e-mail addresses and the placeholder password '%s'." % LOCAL_PASSWORD)
    w("-- * All organizers, people and events are fictional.")
    w("-- * Never run this file against a production project.")
    w("-- Event dates are resolved relative to now() in Asia/Colombo local time.")
    w("-- =============================================================================")
    w("")
    w("set timezone = 'Asia/Colombo';")
    w("")
    w("-- Local date + offset days + local time -> timestamptz (Asia/Colombo).")
    w("create or replace function pg_temp.seed_at(p_offset_days integer, p_time text)")
    w("returns timestamptz language sql stable as $$")
    w("  select (((now() at time zone 'Asia/Colombo')::date + p_offset_days) + p_time::time) at time zone 'Asia/Colombo'")
    w("$$;")
    w("")
    w("-- Agenda items with offset_hours/duration_hours -> {starts_at, ends_at, title, detail}.")
    w("create or replace function pg_temp.seed_agenda(p_starts timestamptz, p_items jsonb)")
    w("returns jsonb language sql stable as $$")
    w("  select coalesce(jsonb_agg(jsonb_build_object(")
    w("      'starts_at', p_starts + make_interval(secs => ((i ->> 'offset_hours')::numeric * 3600)::double precision),")
    w("      'ends_at', p_starts + make_interval(secs => (((i ->> 'offset_hours')::numeric + (i ->> 'duration_hours')::numeric) * 3600)::double precision),")
    w("      'title', i ->> 'title',")
    w("      'detail', i ->> 'detail'")
    w("    ) order by ord), '[]'::jsonb)")
    w("  from jsonb_array_elements(p_items) with ordinality as t(i, ord)")
    w("$$;")
    w("")

    # ------------------------------------------------------------------ users
    w("-- -----------------------------------------------------------------------------")
    w("-- LOCAL DEVELOPMENT auth users (password: '%s')" % LOCAL_PASSWORD)
    w("-- -----------------------------------------------------------------------------")
    users = []
    for org in organizers:
        users.append((org["owner_id"], "owner.%s@zuno.example" % org["slug"], "%s Team" % org["name"]))
    users.append((dev["id"], dev["email"], dev["display_name"]))
    for user_id, email, name in users:
        if not email.endswith(".example"):
            fail("seed e-mail %s must use a .example domain" % email)
        w("insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,")
        w("                        raw_app_meta_data, raw_user_meta_data, created_at, updated_at,")
        w("                        confirmation_token, recovery_token, email_change_token_new, email_change)")
        w("values (%s, %s, 'authenticated', 'authenticated', %s," % (q(INSTANCE_ID), q(user_id), q(email)))
        w("        extensions.crypt(%s, extensions.gen_salt('bf')), now()," % q(LOCAL_PASSWORD))
        w("        '{\"provider\":\"email\",\"providers\":[\"email\"]}'::jsonb, %s," % qjson({"display_name": name}))
        w("        now(), now(), '', '', '', '')")
        w("on conflict (id) do nothing;")
        w("insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)")
        w("values (%s, %s, %s, 'email', now(), now(), now())" % (
            q(user_id), q(user_id), qjson({"sub": user_id, "email": email, "email_verified": True})))
        w("on conflict (provider_id, provider) do nothing;")
        w("")

    w("update public.profiles")
    w("   set display_name = %s, city = %s, district = %s," % (q(dev["display_name"]), q(dev["city"]), q(dev["district"])))
    w("       preferred_categories = %s," % qarray(dev["preferred_categories"]))
    w("       identity_status = 'verified_unique', onboarding_completed_at = now()")
    w(" where id = %s;" % q(dev["id"]))
    w("")

    # ------------------------------------------------------------- reference
    w("-- -----------------------------------------------------------------------------")
    w("-- Categories, organizers, venues")
    w("-- (%d venue(s) shared across organizers in the JSON were copied per organizer)" % shared)
    w("-- -----------------------------------------------------------------------------")
    for c in data["categories"]:
        w("insert into public.categories (id, name, symbol_name, sort_order) values (%s, %s, %s, %d)" % (
            q(c["id"]), q(c["name"]), q(c["symbol_name"]), c["sort_order"]))
        w("on conflict (id) do update set name = excluded.name, symbol_name = excluded.symbol_name, sort_order = excluded.sort_order;")
    w("")
    for o in organizers:
        w("insert into public.organizer_profiles (id, owner_id, name, slug, bio, contact_email, verification_status)")
        w("values (%s, %s, %s, %s, %s, %s, %s)" % (
            q(o["id"]), q(o["owner_id"]), q(o["name"]), q(o["slug"]), q(o["bio"]), q(o["contact_email"]),
            q(o["verification_status"])))
        w("on conflict (id) do nothing;")
    w("")
    for v in data["venues"]:
        w("insert into public.venues (id, organizer_id, name, address_line, city, district, latitude, longitude)")
        w("values (%s, %s, %s, %s, %s, %s, %s, %s)" % (
            q(v["id"]), q(v["organizer_id"]), q(v["name"]), q(v["address_line"]), q(v["city"]), q(v["district"]),
            q(v["latitude"]), q(v["longitude"])))
        w("on conflict (id) do nothing;")
    w("")

    # ----------------------------------------------------------------- events
    w("-- -----------------------------------------------------------------------------")
    w("-- Events (published; events that already ended are seeded as 'completed').")
    w("-- Paid events: seats_taken = sum of tier `sold` (the JSON's seats_taken is 0).")
    w("-- Online/hybrid events get a placeholder https://live.zuno.example/<slug> link.")
    w("-- -----------------------------------------------------------------------------")
    for e in data["events"]:
        seats_taken = e["seats_taken"] if e["is_free"] else sum(t["sold"] for t in e["tiers"])
        online_url = "https://live.zuno.example/%s" % e["slug"] if e["format"] in ("online", "hybrid") else None
        w("insert into public.events (id, organizer_id, category_id, venue_id, title, summary, description, format,")
        w("                           starts_at, ends_at, capacity, is_free, university, tags, cover_path, cover_alt,")
        w("                           agenda, speakers, refund_policy, online_url, status, seats_taken,")
        w("                           creation_fee_paid_at, published_at)")
        w("select %s, %s, %s, %s, %s, %s, %s, %s," % (
            q(e["id"]), q(e["organizer_id"]), q(e["category_id"]), q(e["venue_id"]), q(e["title"]),
            q(e["summary"]), q(e["description"]), q(e["format"])))
        w("       s.starts_at, s.starts_at + %s, %d, %s, %s, %s, %s, %s," % (
            hours_interval(e["duration_hours"]), e["capacity"], q(e["is_free"]), q(e["university"]),
            qarray(e["tags"]), q("seed/%s.jpg" % e["slug"]), q(e["cover_alt"])))
        w("       pg_temp.seed_agenda(s.starts_at, %s), %s, %s, %s," % (
            qjson(e["agenda"]), qjson(e["speakers"]), q(e["refund_policy"]), q(online_url)))
        w("       case when s.starts_at + %s <= now() then 'completed' else 'published' end, %d," % (
            hours_interval(e["duration_hours"]), seats_taken))
        w("       now() - interval '21 days', now() - interval '14 days'")
        w("  from (select pg_temp.seed_at(%d, %s) as starts_at) s" % (e["start_offset_days"], q(e["start_time"])))
        w("on conflict (id) do nothing;")
        w("insert into public.event_media (event_id, storage_path, kind, alt_text, sort_order)")
        w("select %s, %s, 'cover', %s, 0" % (q(e["id"]), q("seed/%s.jpg" % e["slug"]), q(e["cover_alt"])))
        w(" where not exists (select 1 from public.event_media where event_id = %s and kind = 'cover');" % q(e["id"]))
        for index, t in enumerate(e["tiers"]):
            w("insert into public.ticket_tiers (id, event_id, name, description, price_minor, currency, quantity,")
            w("                                 max_per_order, sort_order, sold)")
            w("values (%s, %s, %s, %s, %d, 'LKR', %d, %d, %d, %d)" % (
                q(t["id"]), q(e["id"]), q(t["name"]), q(t["description"]), t["price_minor"], t["quantity"],
                t["max_per_order"], index, t["sold"]))
            w("on conflict (id) do nothing;")
        for index, question in enumerate(e["questions"]):
            w("insert into public.registration_questions (id, event_id, prompt, kind, options, required, sort_order)")
            w("values (%s, %s, %s, %s, %s, %s, %d)" % (
                q(question_id(e["id"], index)), q(e["id"]), q(question["prompt"]), q(question["kind"]),
                qjson(question["options"]), q(question["required"]), index))
            w("on conflict (id) do nothing;")
        if not e["is_free"]:
            w("insert into public.event_settlements (event_id) values (%s) on conflict (event_id) do nothing;" % q(e["id"]))
        w("")

    # ------------------------------------------------------- development user
    w("-- -----------------------------------------------------------------------------")
    w("-- Development user state: wallet (via a posted ledger top-up so the ledger and")
    w("-- the balance agree), monthly allowance usage, registrations, tickets, saved")
    w("-- events and a few notifications. Skipped if already seeded.")
    w("-- -----------------------------------------------------------------------------")
    w("do $seed$")
    w("declare")
    w("  v_dev uuid := %s;" % q(dev["id"]))
    w("  v_month date := private.colombo_month();")
    w("  v_reg uuid;")
    w("  v_ticket uuid;")
    w("  v_order uuid;")
    w("  v_starts timestamptz;")
    w("  v_created timestamptz;")
    w("begin")
    w("  if exists (select 1 from public.registrations where user_id = v_dev) then")
    w("    raise notice 'development user already seeded';")
    w("    return;")
    w("  end if;")
    w("")
    w("  -- Wallet: balance changes only through the ledger.")
    w("  insert into public.wallet_ledger (user_id, entry_type, amount_minor, status, reference_type, description)")
    w("  values (v_dev, 'topup', %d, 'posted', 'seed', 'LOCAL DEVELOPMENT seed top-up');" % dev["wallet_balance_minor"])
    w("")
    w("  -- Allowance used this calendar month (Asia/Colombo).")
    w("  insert into public.allowance_usage (user_id, month, used) values (v_dev, v_month, %d)" % dev["allowance_used_this_month"])
    w("  on conflict (user_id, month) do update set used = excluded.used;")
    w("")

    for slug in dev["registered_event_slugs"]:
        e = events_by_slug[slug]
        answers = [
            {"question_id": question_id(e["id"], i), "value": sample_answer(qu)}
            for i, qu in enumerate(e["questions"]) if qu["required"]
        ]
        w("  -- Free registration: %s" % slug)
        w("  select starts_at into v_starts from public.events where id = %s;" % q(e["id"]))
        w("  v_created := least(now() - interval '2 days', v_starts - interval '3 days');")
        w("  insert into public.registrations (event_id, user_id, status, kind, used_allowance, allowance_month,")
        w("                                    fee_minor, reference, created_at)")
        w("  values (%s, v_dev, 'confirmed', 'free', true, private.colombo_month(v_created), 0," % q(e["id"]))
        w("          private.generate_registration_reference(), v_created)")
        w("  returning id into v_reg;")
        if answers:
            w("  insert into public.registration_answers (registration_id, question_id, value)")
            w("  select v_reg, (a ->> 'question_id')::uuid, a -> 'value' from jsonb_array_elements(%s) a;" % qjson(answers))
        w("  v_ticket := private.issue_ticket(v_reg, %s, v_dev, null, null);" % q(e["id"]))
        w("  if private.colombo_month(v_created) <> v_month then")
        w("    insert into public.allowance_usage (user_id, month, used) values (v_dev, private.colombo_month(v_created), 1)")
        w("    on conflict (user_id, month) do update set used = public.allowance_usage.used + 1;")
        w("  end if;")
        w("  if v_starts < now() then")
        w("    -- Past event: the development user attended.")
        w("    update public.tickets set status = 'checked_in', checked_in_at = v_starts + interval '20 minutes' where id = v_ticket;")
        w("    insert into public.check_ins (ticket_id, event_id, checked_in_at) values (v_ticket, %s, v_starts + interval '20 minutes');" % q(e["id"]))
        w("  else")
        w("    insert into public.notifications (user_id, kind, title, body, event_id, data, created_at)")
        w("    values (v_dev, 'registration_confirmed', 'You''re registered', %s, %s," % (q(e["title"]), q(e["id"])))
        w("            jsonb_build_object('registration_id', v_reg, 'ticket_id', v_ticket), v_created);")
        w("  end if;")
        w("")

    commission_bps = 500
    for slug in dev["paid_ticket_event_slugs"]:
        e = events_by_slug[slug]
        tier = e["tiers"][0]
        subtotal = tier["price_minor"]
        commission = (subtotal * commission_bps + 5000) // 10000
        answers = [
            {"question_id": question_id(e["id"], i), "value": sample_answer(qu)}
            for i, qu in enumerate(e["questions"]) if qu["required"]
        ]
        w("  -- Paid ticket (1 x %s): %s. Counted inside the tier's seeded `sold`." % (tier["name"], slug))
        w("  insert into public.orders (user_id, event_id, kind, status, subtotal_minor, commission_minor, total_minor,")
        w("                             idempotency_key, answers, expires_at, paid_at, created_at)")
        w("  values (v_dev, %s, 'ticket', 'paid', %d, (%d * private.setting('commission_bps') + 5000) / 10000, %d," % (
            q(e["id"]), subtotal, subtotal, subtotal))
        w("          %s, %s, now() - interval '6 days 23 hours', now() - interval '7 days', now() - interval '7 days')" % (
            q("seed-%s-dev" % slug), qjson(answers)))
        w("  returning id into v_order;")
        w("  insert into public.order_items (order_id, tier_id, quantity, unit_price_minor) values (v_order, %s, 1, %d);" % (
            q(tier["id"]), tier["price_minor"]))
        w("  insert into public.payments (order_id, provider_payment_id, status_code, amount_minor, currency, method, outcome, notification)")
        w("  values (v_order, %s, 2, %d, 'LKR', 'TEST', 'paid', %s);" % (
            q("seed-%s" % slug), subtotal, qjson({"note": "LOCAL DEVELOPMENT seed payment", "status_code": "2"})))
        w("  insert into public.registrations (event_id, user_id, status, kind, order_id, reference, created_at)")
        w("  values (%s, v_dev, 'confirmed', 'paid', v_order, private.generate_registration_reference(), now() - interval '7 days')" % q(e["id"]))
        w("  returning id into v_reg;")
        w("  v_ticket := private.issue_ticket(v_reg, %s, v_dev, %s, v_order);" % (q(e["id"]), q(tier["id"])))
        w("  insert into public.notifications (user_id, kind, title, body, event_id, data, created_at)")
        w("  values (v_dev, 'ticket_issued', 'Your ticket is ready', %s, %s," % (q(e["title"]), q(e["id"])))
        w("          jsonb_build_object('order_id', v_order, 'ticket_ids', jsonb_build_array(v_ticket)), now() - interval '7 days');")
        w("  -- expected commission for this seed order: %d" % commission)
        w("")

    for slug in dev["saved_event_slugs"]:
        e = events_by_slug[slug]
        w("  insert into public.saved_events (user_id, event_id) values (v_dev, %s) on conflict do nothing;" % q(e["id"]))
    w("")
    w("  insert into public.notifications (user_id, kind, title, body, data, created_at)")
    w("  values (v_dev, 'general', 'Welcome to Zuno', 'Discover events across Sri Lanka and keep your tickets in one place.',")
    w("          '{}'::jsonb, now() - interval '10 days');")
    w("end")
    w("$seed$;")
    w("")
    w("reset timezone;")
    return "\n".join(out) + "\n"


def main():
    parser = argparse.ArgumentParser(description="Generate supabase/seed.sql from zuno_seed.json")
    parser.add_argument("--check", action="store_true", help="fail if supabase/seed.sql is out of date")
    parser.add_argument("--source", default=SOURCE)
    parser.add_argument("--output", default=TARGET)
    args = parser.parse_args()

    with open(args.source, "r", encoding="utf-8") as handle:
        data = json.load(handle)
    validate(data)
    sql = generate(data)

    if args.check:
        try:
            with open(args.output, "r", encoding="utf-8") as handle:
                current = handle.read()
        except FileNotFoundError:
            current = ""
        if current != sql:
            sys.stderr.write("supabase/seed.sql is out of date; run scripts/generate-seed-sql.py\n")
            return 1
        print("seed.sql is up to date")
        return 0

    with open(args.output, "w", encoding="utf-8") as handle:
        handle.write(sql)
    print("wrote %s (%d events, %d organizers, %d venues)" % (
        os.path.relpath(args.output, ROOT), len(data["events"]), len(data["organizers"]), len(data["venues"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
