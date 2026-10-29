#!/usr/bin/env python3
"""GOLIVE-1 · live dry run (COMMIT -> ROLLBACK). Builds one psql script: lock_timeout 10s · BEGIN · BEFORE readings ·
the migration body (exactly the lines between its BEGIN; and COMMIT; lines — never cut at a semicolon) · AFTER readings ·
the row-4 proof Tim asked for (Q7: one supplier's return to pending_review, inside this same rolled-back transaction) · ROLLBACK.
Readings, read-only inside the rolled-back transaction:
  as postgres (rolbypassrls, base tables): roles with their holder and code counts; holders of hr / procurement / sales (incl. revoked);
    md5 of the seven real roles' grants, of suppliers, employees, contracts, the five row-12 tables, cod_issues and certificates_of_destruction
    (before and after must match — the migration changes who reads, never what is there; the seven real roles' codes do not change);
    the anon relation count; policy expressions; container_overview's predicate; the column grants on the five row-12 tables.
  as real role holders (cfo · cco · warehouse · finance) and a session with no role: rows readable in metal_prices / index_market_calendar /
    pricing_settings / container_overview and in the five row-12 relations (base or masked).
Nothing is pressed: the only write besides the migration body is the supplier rename of the Q7 proof, and it is rolled back with everything else.
usage: python3 db/scripts/2026-10-29-golive-1-dry-run.py > dry-run.sql ; psql "$DSN" -X -At -v ON_ERROR_STOP=1 -f dry-run.sql"""
import os, sys
ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
mig = open(os.path.join(ROOT, sys.argv[1] if len(sys.argv) > 1 else 'db/migrations/2026-10-29-golive-1.sql')).read().split('\n')
b = mig.index('BEGIN;'); c = len(mig) - 1 - mig[::-1].index('COMMIT;')
body = '\n'.join(mig[b + 1:c])
READERS = {'cfo': '634c00f9-c3a9-4444-9eed-b624cb6a2a93', 'cco': '01ae00e4-306f-4527-8537-10291e4750c7',
           'warehouse': 'c8116e6c-80db-4a16-be12-24fb6ce6859d', 'finance': '476bf8c8-c248-4352-9a75-945bf52ca390',
           'no-role': '00000000-0000-4000-8000-00000000601e'}
SEVEN = "'admin','cco','cfo','cto','finance','gm','warehouse'"


def md5(rel, order='id'):
    return f"(SELECT count(*) || ' ' || md5(coalesce(string_agg(to_jsonb(t)::text, '' ORDER BY t.{order}), '')) FROM public.{rel} t)"


def readings(tag):
    out = [f"""SELECT 'PROOF|{tag}|postgres|' || json_build_object(
  'roles', (SELECT string_agg(r.code || ':' || (SELECT count(*) FROM public.user_roles ur WHERE ur.role_id = r.id AND ur.revoked_at IS NULL) || 'h/'
                              || (SELECT count(*) FROM public.role_permissions rp WHERE rp.role_id = r.id) || 'c', ' ' ORDER BY r.code) FROM public.roles r),
  'held_hr_proc_sales_incl_revoked', (SELECT count(*) FROM public.user_roles ur JOIN public.roles r ON r.id = ur.role_id WHERE r.code IN ('hr','procurement','sales')),
  'seven_grants', (SELECT count(*) || ' ' || md5(string_agg(r.code || '/' || rp.permission_code, ',' ORDER BY r.code, rp.permission_code))
                     FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code IN ({SEVEN})),
  'user_roles', {md5('user_roles')},
  'suppliers', {md5('suppliers')}, 'employees', {md5('employees')}, 'contracts', {md5('contracts')},
  'sales_settlements', {md5('sales_settlements')}, 'contract_pricing_terms', {md5('contract_pricing_terms')},
  'contract_refining_charges', {md5('contract_refining_charges')}, 'contract_penalty_elements', {md5('contract_penalty_elements')},
  'contract_insurance_obligations', {md5('contract_insurance_obligations')},
  'cod_issues', {md5('cod_issues')}, 'cods', {md5('certificates_of_destruction')},
  'anon_relations', (SELECT count(*) FROM pg_class c WHERE c.relnamespace = 'public'::regnamespace AND c.relkind IN ('r','v','m','p','f')
                       AND has_table_privilege('anon', c.oid, 'SELECT')),
  'anon_functions', (SELECT string_agg(p.proname, ',' ORDER BY p.proname) FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace AND has_function_privilege('anon', p.oid, 'EXECUTE')),
  'auditor', (SELECT string_agg(rp.permission_code, ',' ORDER BY rp.permission_code) FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id WHERE r.code = 'auditor'),
  'employee_desc', (SELECT left(description_en, 60) FROM public.roles WHERE code = 'employee'),
  'policies', (SELECT json_object_agg(tablename || ' / ' || policyname, qual ORDER BY tablename, policyname) FROM pg_policies
                WHERE schemaname = 'public' AND cmd = 'SELECT' AND tablename IN ('metal_prices', 'index_market_calendar', 'pricing_settings')),
  'container_overview_where', (SELECT substring(pg_get_viewdef('public.container_overview'::regclass) FROM 'WHERE .*$')),
  'price_columns_granted', (SELECT count(*) FROM (VALUES ('sales_settlements','amount_usd'), ('contract_refining_charges','usd_per_tonne_of_metal'),
                              ('contract_penalty_elements','usd_per_tonne_per_pct_over'), ('contract_insurance_obligations','min_amount'),
                              ('contract_pricing_terms','payable_pct')) x(t, col) WHERE has_column_privilege('authenticated', 'public.' || x.t, x.col, 'SELECT')),
  'status_history_trigger', (SELECT pg_get_triggerdef(oid) FROM pg_trigger WHERE tgrelid = 'public.suppliers'::regclass AND tgname = 'trg_suppliers_status_history'))::text;"""]
    masked = tag == 'A'
    for role, uid in READERS.items():
        out.append("SET LOCAL ROLE authenticated;")
        out.append(f"""SELECT set_config('request.jwt.claims', '{{"sub":"{uid}","role":"authenticated"}}', true) \\g /dev/null""")
        rel = (lambda t: t + '_masked') if masked else (lambda t: t)
        out.append(f"""SELECT 'PROOF|{tag}|{role}|reads|' || json_build_object(
  'metal_prices', (SELECT count(*) FROM public.metal_prices), 'calendar', (SELECT count(*) FROM public.index_market_calendar),
  'pricing_settings', (SELECT count(*) FROM public.pricing_settings), 'container_overview', (SELECT count(*) FROM public.container_overview),
  'settlements', (SELECT count(*) FROM public.{rel('sales_settlements')}), 'pricing_terms', (SELECT count(*) FROM public.{rel('contract_pricing_terms')}),
  'refining', (SELECT count(*) FROM public.{rel('contract_refining_charges')}), 'penalty', (SELECT count(*) FROM public.{rel('contract_penalty_elements')}),
  'insurance', (SELECT count(*) FROM public.{rel('contract_insurance_obligations')}))::text;""")
        out.append("RESET ROLE;")
    return '\n'.join(out)


# Q7 · 一家已批准的供应商改名 → 回到待审(在同一笔要回滚的事务里;以真的 warehouse 账号 —— 它持 module.suppliers.edit —— 走直连写那条路)
PROOF_Q7 = f"""SELECT 'PROOF|Q7|before|' || (SELECT json_build_object('code', code, 'status', status, 'approved_at', approved_at, 'legal_name', legal_name)::text
                                         FROM public.suppliers WHERE code = 'SUP-2026-0003');
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claims', '{{"sub":"{READERS['warehouse']}","role":"authenticated"}}', true) \\g /dev/null
UPDATE public.suppliers SET legal_name = legal_name || ' (GOLIVE-1 dry run)' WHERE code = 'SUP-2026-0003';
RESET ROLE;
SELECT 'PROOF|Q7|after|' || (SELECT json_build_object('code', code, 'status', status, 'approved_by', approved_by, 'approved_at', approved_at, 'legal_name', legal_name)::text
                                        FROM public.suppliers WHERE code = 'SUP-2026-0003')
       || ' · history ' || (SELECT count(*) FROM public.supplier_status_history h JOIN public.suppliers s ON s.id = h.supplier_id
                              WHERE s.code = 'SUP-2026-0003' AND h.from_status = 'approved' AND h.to_status = 'pending_review' AND h.changed_at = now());"""

print(f"""\\set ON_ERROR_STOP 1
SET lock_timeout = '10s';
\\timing on
BEGIN;
SELECT 'PROOF|clock before|' || clock_timestamp();
{readings('B')}
SELECT 'PROOF|clock migration start|' || clock_timestamp();
{body}
SELECT 'PROOF|clock migration end|' || clock_timestamp();
{readings('A')}
{PROOF_Q7}
SELECT 'PROOF|clock rollback|' || clock_timestamp();
ROLLBACK;
""")
