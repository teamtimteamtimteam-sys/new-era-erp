#!/usr/bin/env python3
"""MES-9a — fault-injection matrix for fixture 275 and verdict 8, against a LOCAL rebuild (never live).

It builds its own throwaway cluster (db/verify_rebuild.py --skip-diff, then the storage stub + mirror the gate installs), so it can be
re-run on a fresh rebuild after the last database edit. Each fixture cell runs inside the fixture's own transaction (the injection is the
first statement after an outer BEGIN; the fixture's ROLLBACK undoes both), so every cell starts from the clean rebuild. A function is
injected by re-creating it from its MIRROR with one targeted edit — the edit must actually change the text, or the cell is reported as
not injected (an injection that did not happen is not a pass).
Every cell must print a FIXTURE 275 failure naming its arm; the baseline cell must pass. Verdict 8 is then injected both ways.
Usage: python3 db/scripts/2026-10-19-mes9a-fixture-injections.py > <log> 2>&1 ; verdict: the log's INJ_OWN_EXIT= line (written by the caller).
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
FIX = next((ROOT / "db/fixtures").glob("275-*.sql")).read_text()


def mirror_fn(name: str) -> str:
    return (ROOT / f"db/functions/{name}.sql").read_text()


def edit(name: str, old: str, new: str) -> str:
    src = mirror_fn(name)
    if src.count(old) != 1:
        raise SystemExit(f"INJECTION NOT APPLIED: {name}: the text to replace occurs {src.count(old)} time(s): {old[:80]!r}")
    return src.replace(old, new)


def view_edit(name: str, old: str, new: str) -> str:
    src = (ROOT / f"db/views/{name}.sql").read_text()
    if src.count(old) != 1:
        raise SystemExit(f"INJECTION NOT APPLIED: view {name}: {src.count(old)} occurrence(s) of {old[:80]!r}")
    src = src.replace(old, new)
    start = src.index(f"CREATE VIEW public.{name} ")
    stmt = src[start:src.index(";\n", start) + 2]
    return stmt.replace(f"CREATE VIEW public.{name} ", f"CREATE OR REPLACE VIEW public.{name} ")


CELLS = [
    ("CODE: declared view code changed",
     "UPDATE permissions SET requires_view_any = ARRAY['module.purchasing.view'] WHERE code = 'action.manage_portal_users';", "CODE:"),
    ("LINK: the code check removed",
     edit("portal_user_create_link", "    PERFORM require_permission('action.manage_portal_users');\n", ""), "LINK: a suppliers viewer created"),
    ("LINK: contact-of-supplier check removed",
     edit("portal_user_create_link", "WHERE c.id = p_contact_id AND c.supplier_id = p_supplier_id AND", "WHERE c.id = p_contact_id AND"),
     "LINK: another supplier's contact was accepted"),
    ("LINK: email check removed",
     edit("portal_user_create_link", "AND lower(u.email) = lower(btrim(v_email))", ""), "LINK: an account whose email is not the contact's"),
    ("SEP: role trigger dropped", "DROP TRIGGER trg_user_roles_not_portal_account ON public.user_roles;", "SEP: a portal account was granted a role"),
    ("SEP: employee trigger dropped", "DROP TRIGGER trg_employees_not_portal_account ON public.employees;", "SEP: a portal account was linked to an employee"),
    ("SEP: additional-account trigger dropped", "DROP TRIGGER trg_employee_accounts_not_portal_account ON public.employee_accounts;",
     "SEP: a portal account became an additional account"),
    ("SEP: reverse (link side) trigger dropped", "DROP TRIGGER trg_supplier_portal_users_separation ON public.supplier_portal_users;",
     "SEP: an account holding a role got a portal link"),
    ("HOOK: staff claims touched",
     edit("portal_access_token_hook", "    RETURN event;\nEND;", "    RETURN jsonb_set(event, '{claims,portal}', 'false');\nEND;"),
     "HOOK: the claims of a"),
    ("HOOK: the fallback removed (an internal failure raises)",
     edit("portal_access_token_hook", "    EXCEPTION WHEN OTHERS THEN\n        RETURN event;\n", ""), "HOOK: the hook raised"),
    ("HOOK: supabase_auth_admin cannot read the link", "REVOKE SELECT ON public.supplier_portal_users FROM supabase_auth_admin;",
     "HOOK: supabase_auth_admin cannot read the portal link"),
    ("EVERY: one more function granted to supplier_portal",
     "GRANT EXECUTE ON FUNCTION public.portal_actor_labels(uuid[]) TO supplier_portal;", "has no two-supplier case"),
    ("EVERY: portal_me answers about the first link, not the caller's",
     edit("portal_me", "     WHERE p.id = v_link;", "     WHERE p.id = (SELECT id FROM supplier_portal_users ORDER BY created_at, id LIMIT 1) AND v_link IS NOT NULL;"),
     "EVERY: portal_me() as"),
    ("EVERY: portal_me granted to authenticated", "GRANT EXECUTE ON FUNCTION public.portal_me() TO authenticated;", "as authenticated"),
    ("EVERY: role check removed",
     edit("portal_require_link", "    IF COALESCE(current_setting('role', true), '') <> 'supplier_portal'\n       OR COALESCE(auth.jwt() ->> 'role', '') <> 'supplier_portal' THEN",
          "    IF false THEN"), "with a non-portal claim"),
    ("EVERY: session check removed",
     edit("portal_require_link", "    IF v_sid IS NULL OR NOT EXISTS (SELECT 1 FROM auth.sessions s WHERE s.id = v_sid AND s.user_id = v_uid) THEN",
          "    IF false THEN"), "with an ended session"),
    ("EVERY: ban check removed",
     edit("portal_require_link", "    IF v_rev IS NOT NULL\n       OR EXISTS (SELECT 1 FROM auth.users u WHERE u.id = v_uid AND u.banned_until IS NOT NULL AND u.banned_until > now()) THEN",
          "    IF v_rev IS NOT NULL THEN"), "as a banned account"),
    ("EXPORT: staff notes leak into the export",
     edit("portal_export_my_data", "'phone', c.phone,", "'phone', c.phone, 'notes', c.notes,"), "EXPORT:"),
    ("REVOKE: sessions not ended",
     edit("portal_user_revoke", "    DELETE FROM auth.sessions s WHERE s.user_id = v_user;\n", ""), "REVOKE: the revoke did not end"),
    ("REVOKE: reason not required",
     edit("portal_user_revoke", "    IF NULLIF(btrim(p_reason), '') IS NULL THEN\n        RAISE EXCEPTION 'PORTAL_REVOKE_REASON_REQUIRED';\n    END IF;\n", ""),
     "REVOKE: a revoke without a reason"),
    ("REVOKE: the revoked check removed from the session check",
     edit("portal_require_link", "    IF v_rev IS NOT NULL\n       OR EXISTS", "    IF EXISTS"), "REVOKE: A's next call after revoke"),
    ("ANON: change-log images not redacted",
     edit("portal_contact_anonymise", "       AND c.table_name = 'counterparty_contacts' AND c.row_key ->> 'id' = l.contact_id::text;",
          "       AND false;"), "ANON: the change log still holds"),
    ("ANON: anonymising a live account allowed",
     edit("portal_contact_anonymise", "    IF l.revoked_at IS NULL THEN\n        RAISE EXCEPTION 'PORTAL_ANONYMISE_NEEDS_REVOKE';\n    END IF;\n", ""),
     "ANON: anonymised a live account"),
    ("TRAIL: trail_actor without the portal branch",
     edit("trail_actor", "        IF v_emp IS NOT NULL THEN\n            RETURN v_emp;\n        END IF;", "        v_emp := NULL;"),
     "TRAIL: trail_actor for a portal account"),
    ("TRAIL: supplier trail without the portal links",
     edit("trail_subject_members", "        ('supplier',            7, 'supplier_portal_users',", "        ('supplier_x',          7, 'supplier_portal_users',"),
     "TRAIL: the supplier's trail does not show"),
    ("VIEW: user_directory lists portal accounts again",
     view_edit("user_directory", " AND NOT (EXISTS ( SELECT 1\n           FROM supplier_portal_users p\n          WHERE p.user_id = u.id))", ""),
     "VIEW: user_directory lists"),
    ("VIEW: the portal accounts view loses its predicate",
     view_edit("supplier_portal_accounts", "  WHERE has_permission('module.suppliers.view'::text);", ";"),
     "VIEW: a reader without module.suppliers.view"),
    ("LOG: the link table unbound from the change log", "DROP TRIGGER zzz_change_log ON public.supplier_portal_users;", "LOG:"),
    ("GRANTS: the hook granted to authenticated", "GRANT EXECUTE ON FUNCTION public.portal_access_token_hook(jsonb) TO authenticated;", "GRANTS: the hook"),
    ("GRANTS: supplier_portal made a member of authenticated", "GRANT authenticated TO supplier_portal;", "GRANTS: supplier_portal must not be a member"),
]


def run(dsn: str, sql: str) -> str:
    p = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1"], input=sql, capture_output=True, text=True)
    return (p.stdout or "") + (p.stderr or "")


def first_fixture_line(out: str) -> str:
    m = re.search(r"(FIXTURE 275[^\n]*)", out)
    return m.group(1)[:200] if m else ""


def main() -> int:
    work = tempfile.mkdtemp(prefix="inj9a", dir="/tmp")
    data, sock = os.path.join(work, "pg"), os.path.join(work, "s")
    os.makedirs(sock)
    port = "55439"
    passed = failed = 0
    try:
        subprocess.run(["initdb", "-D", data, "-U", "postgres", "--no-locale", "--encoding=UTF8"], capture_output=True, check=True)
        subprocess.run(["pg_ctl", "-D", data, "-o", f"-p {port} -k {sock} -c listen_addresses=''", "-l", os.path.join(work, "pg.log"), "start"],
                       capture_output=True, check=True)
        subprocess.run(["createdb", "-h", sock, "-p", port, "-U", "postgres", "inj"], capture_output=True, check=True)
        dsn = f"host={sock} port={port} user=postgres dbname=inj"
        vr = subprocess.run([sys.executable, str(ROOT / "db/verify_rebuild.py"), "--target", dsn, "--skip-diff"], capture_output=True, text=True)
        if vr.returncode not in (0,):
            print(vr.stdout[-2000:], vr.stderr[-2000:])
            print(f"✗ the rebuild did not build (exit {vr.returncode})")
            return 2
        si = subprocess.run(["psql", dsn, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(ROOT / "db/storage/platform-storage-stub.sql"),
                             "-f", str(ROOT / "db/storage/buckets-and-policies.sql")], capture_output=True, text=True)
        if si.returncode != 0:
            print("✗ storage stub did not install:", si.stderr[-500:])
            return 2
        print("== a fresh local rebuild (db/verify_rebuild.py --skip-diff) + storage stub")
        for name, inj, expect in CELLS:
            out = run(dsn, "BEGIN;\n" + inj + "\n" + FIX)
            line = first_fixture_line(out)
            if expect in line and "全部通过" not in line:
                print(f"✓ {name} → {line}")
                passed += 1
            else:
                err = next((l for l in out.splitlines() if "ERROR" in l), "")
                print(f"✗ {name} → {line or err or '<no fixture line>'} (expected: {expect})")
                failed += 1
        out = run(dsn, FIX)
        line = first_fixture_line(out)
        if "全部通过" in line:
            print(f"✓ baseline (no injection) → {line}")
            passed += 1
        else:
            print(f"✗ baseline → {line or out[-300:]}")
            failed += 1
        # ── verdict 8 on the same rebuild, both ways ──
        cp = [sys.executable, str(ROOT / "db/check_portal.py"), "--rebuild", dsn, "--offline"]
        run(dsn, "GRANT SELECT ON public.suppliers TO supplier_portal;")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, "REVOKE SELECT ON public.suppliers FROM supplier_portal;")
        ok = "reaches what the baseline does not name: relation public.suppliers SELECT" in v
        print(("✓" if ok else "✗") + " verdict 8: an extra grant (suppliers → supplier_portal) is named" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        run(dsn, "REVOKE EXECUTE ON FUNCTION public.portal_me() FROM supplier_portal;")
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        run(dsn, "GRANT EXECUTE ON FUNCTION public.portal_me() TO supplier_portal;")
        ok = "the baseline names what supplier_portal does not reach: function public.portal_me() EXECUTE" in v
        print(("✓" if ok else "✗") + " verdict 8: a missing grant (portal_me revoked) is named" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        bl = Path(work) / "bl.tsv"
        bl.write_text("".join(l for l in (ROOT / "db/portal-grants-baseline.tsv").read_text().splitlines(True)
                              if not l.startswith("function\tpublic.portal_export_my_data()")))
        v = subprocess.run(cp + ["--baseline", str(bl)], capture_output=True, text=True).stdout
        ok = "reaches what the baseline does not name: function public.portal_export_my_data() EXECUTE" in v
        print(("✓" if ok else "✗") + " verdict 8: a deleted baseline line is named" + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        v = subprocess.run(cp + ["--baseline", "/nonexistent/portal-baseline.tsv"], capture_output=True, text=True).stdout
        ok = "baseline unreadable" in v
        print(("✓" if ok else "✗") + " verdict 8: an unreadable baseline is red" + ("" if ok else f": {v[-300:]}"))
        passed, failed = passed + ok, failed + (not ok)
        v = subprocess.run(cp, capture_output=True, text=True).stdout
        ok = "all bit" in v and "判词【门户面】:✓" in v
        print(("✓" if ok else "✗") + " verdict 8 clean; always-on cells (unreadable baseline · blinded query · probe grant · removed line) bit"
              + ("" if ok else f": {v[-400:]}"))
        passed, failed = passed + ok, failed + (not ok)
        print(f"INJECTIONS pass={passed} fail={failed}")
        return 0 if failed == 0 else 1
    finally:
        subprocess.run(["pg_ctl", "-D", data, "stop", "-m", "immediate"], capture_output=True)
        shutil.rmtree(work, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
