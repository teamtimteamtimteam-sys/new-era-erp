#!/usr/bin/env python3
"""ESG-2 · live dry run (COMMIT -> ROLLBACK). Builds one psql script: lock_timeout 10s · BEGIN · BEFORE readings ·
the migration body (exactly the lines between its BEGIN; and COMMIT; lines — never cut at a semicolon) · the function-grant replay
(db/views/zzz_function_grants.sql, as apply_migration.sh does inside the same transaction) · AFTER readings · ROLLBACK.
Readings, read-only inside the rolled-back transaction:
  as postgres (rolbypassrls, base tables): who holds the three new codes; md5 of user_roles; change_log count; cod_issues md5; the new tables present;
    the two settings empty; anon relation count; incidents / training_records counts.
  as the real cfo (tim@): esg_safety_rates(this year) answers with injury_visible true; whistleblowing_report_readable(true) true, (false) false;
    whistleblowing_report_rows 0 rows; esg_scope2_bills 0 rows; my_concerns 0 rows.
  as the real cco: whistleblowing_report_readable(false) true, (true) false.
  as the real admin: neither whistleblowing code (both readable() false); esg_set_standard_hours refused by value (25 → ESG_STANDARD_HOURS_INVALID), so the gate passed.
  as the real warehouse holder: esg_set_grid_factor refused by name (no action.manage_esg); esg_safety_rates answers with injury_visible false.
Nothing is pressed and nothing is written besides the migration body, which is rolled back with everything else.
usage: python3 db/scripts/2026-10-31-esg-2-dry-run.py > dry-run.sql ; psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f dry-run.sql"""
import os
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
mig = open(os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'db/migrations/2026-10-31-esg-2.sql')).read().split('\n')
b = mig.index('BEGIN;'); c = len(mig) - 1 - mig[::-1].index('COMMIT;')
body = '\n'.join(mig[b + 1:c])
grants = open(os.path.join(ROOT, 'db/views/zzz_function_grants.sql')).read()
CFO = '634c00f9-c3a9-4444-9eed-b624cb6a2a93'
WAREHOUSE = 'c8116e6c-80db-4a16-be12-24fb6ce6859d'
NEW = "'esg_settings','grid_emission_factors','required_trainings','company_policies','whistleblowing_reports','whistleblowing_updates','incident_days_lost_corrections'"


def as_user(sub_sql, tag, who, lines):
    # ★ run 1 的教训:持有人那一句子查询必须在切成 authenticated【之前】、以 postgres 求值 —— 切过去之后它带着上一位读者的声明读 user_roles,
    #   读不到别人的那一行,于是 sub 是空的(admin 那几句读数在 run 1 里因此作废)。
    out = ["RESET ROLE;",
           f"""SELECT set_config('request.jwt.claims', json_build_object('sub', ({sub_sql}), 'role', 'authenticated')::text, true) \\g /dev/null""",
           f"""SELECT 'PROOF|{tag}|{who}|session uid ' || COALESCE(auth.uid()::text, 'NULL');""",
           "SET LOCAL ROLE authenticated;"]
    out += [l.replace('{T}', tag).replace('{W}', who) for l in lines]
    out.append("RESET ROLE;")
    return '\n'.join(out)


def holder(role):
    return f"(SELECT ur.user_id::text FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id WHERE r.code = '{role}' AND ur.revoked_at IS NULL ORDER BY ur.user_id LIMIT 1)"


def readings(tag):
    out = [f"""SELECT 'PROOF|{tag}|postgres|' || json_build_object(
  'new_code_holders', (SELECT COALESCE(string_agg(r.code || ':' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code), 'none')
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
                    WHERE rp.permission_code IN ('action.manage_esg','data.view_whistleblowing','data.view_whistleblowing_escalated')),
  'grants_total', (SELECT count(*) FROM public.role_permissions),
  'user_roles', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.user_roles t),
  'change_log', (SELECT count(*) || ' max ' || max(seq) FROM public.change_log),
  'cod_issues', (SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.id), '')) FROM public.cod_issues t),
  'new_tables', (SELECT COALESCE(string_agg(relname, ',' ORDER BY relname), 'none') FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ({NEW})),
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'incidents', (SELECT count(*) FROM public.incidents), 'training_records', (SELECT count(*) FROM public.training_records),
  'approvals', (SELECT approvals_enabled FROM public.finance_settings),
  'req_cal', (SELECT COALESCE(require_calibrated_since::text, 'NULL') FROM public.ingest_settings))::text;"""]
    if tag == 'B':
        out.append("""SELECT 'PROOF|B|postgres|settings ' || (SELECT count(*) FROM public.esg_settings) || ' row, hours=' || COALESCE((SELECT standard_hours_per_day::text FROM public.esg_settings), 'NULL')
  || ' · factors=' || (SELECT count(*) FROM public.grid_emission_factors) || ' · exclusions=' || (SELECT count(*) FROM public.change_log_exclusions())
  || ' · coverage_gaps=' || jsonb_array_length(public.change_log_coverage_gaps() -> 'gaps');""")
        out.append(as_user(f"'{CFO}'", 'B', 'cfo', [
            "SELECT 'PROOF|{T}|{W}|rates ' || (SELECT count(*) FROM public.esg_safety_rates(EXTRACT(year FROM now())::int)) || ' rows · injury_visible=' || COALESCE((SELECT bool_and(injury_visible)::text FROM public.esg_safety_rates(EXTRACT(year FROM now())::int)), 'none') || ' · ytd_state=' || (SELECT hours_state FROM public.esg_safety_rates(EXTRACT(year FROM now())::int) WHERE month IS NULL);",
            "SELECT 'PROOF|{T}|{W}|readable(escalated)=' || public.whistleblowing_report_readable(true) || ' readable(plain)=' || public.whistleblowing_report_readable(false);",
            "SELECT 'PROOF|{T}|{W}|report_rows=' || (SELECT count(*) FROM public.whistleblowing_report_rows) || ' scope2_bills=' || (SELECT count(*) FROM public.esg_scope2_bills()) || ' my_concerns=' || (SELECT count(*) FROM public.my_concerns()) || ' policies=' || (SELECT count(*) FROM public.company_policy_rows);",
        ]))
        out.append(as_user(holder('cco'), 'B', 'cco', [
            "SELECT 'PROOF|{T}|{W}|readable(escalated)=' || public.whistleblowing_report_readable(true) || ' readable(plain)=' || public.whistleblowing_report_readable(false);",
        ]))
        out.append(as_user(holder('admin'), 'B', 'admin', [
            "SELECT 'PROOF|{T}|{W}|readable(escalated)=' || public.whistleblowing_report_readable(true) || ' readable(plain)=' || public.whistleblowing_report_readable(false);",
            """DO $a$ BEGIN PERFORM public.esg_set_standard_hours(25); RAISE NOTICE 'PROOF|B|admin|set_standard_hours(25) returned (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|admin|set_standard_hours(25) refused %', SQLERRM; END $a$;""",
        ]))
        out.append(as_user(f"'{WAREHOUSE}'", 'B', 'warehouse', [
            """DO $w$ BEGIN PERFORM public.esg_set_grid_factor(2024, 0.4, 'x'); RAISE NOTICE 'PROOF|B|warehouse|set_grid_factor returned (should have refused)';
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'PROOF|B|warehouse|set_grid_factor refused %', SQLERRM; END $w$;""",
            "SELECT 'PROOF|{T}|{W}|rates injury_visible=' || COALESCE((SELECT bool_or(injury_visible)::text FROM public.esg_safety_rates(EXTRACT(year FROM now())::int)), 'none') || ' · report_rows=' || (SELECT count(*) FROM public.whistleblowing_report_rows);",
        ]))
    return '\n'.join(out)


print("\\set ON_ERROR_STOP 1")
print("SET lock_timeout = '10s';")
print("\\timing on")
print("BEGIN;")
print(readings('A'))
print("-- ── migration body ──")
print(body)
print("-- ── function-grant replay (apply_migration.sh does this inside the same transaction) ──")
print(grants)
print(readings('B'))
print("ROLLBACK;")
print(f"SELECT 'PROOF|C|after rollback|new_tables=' || COALESCE((SELECT string_agg(relname, ',') FROM pg_class WHERE relnamespace = 'public'::regnamespace AND relname IN ({NEW})), 'none') || ' new_codes=' || (SELECT count(*) FROM public.permissions WHERE code IN ('action.manage_esg','data.view_whistleblowing','data.view_whistleblowing_escalated'));")
