#!/usr/bin/env python3
"""ESG-2 · builds db/migrations/2026-10-31-esg-2.sql from the mirrors (edit the mirrors, then re-run; never hand-edit the output).

Order matters on live, where check_function_bodies is ON (a SQL body resolves at CREATE time; the rebuild has it off):
  three codes + their five grants → the two predicates the new read policies call → the seven tables (and the new column on training_records)
  → the functions that read them → the three views (incident_rows is replaced, columns appended at the end) → change-log bindings and the
  exclusion list → a self-check.
usage: python3 db/scripts/build_esg2_migration.py
"""
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
OUT = os.path.join(ROOT, 'db/migrations/2026-10-31-esg-2.sql')
NEW_CODES = ['data.view_whistleblowing', 'data.view_whistleblowing_escalated', 'action.manage_esg']
NEW_TABLES = ['esg_settings', 'grid_emission_factors', 'required_trainings', 'company_policies',
              'whistleblowing_reports', 'whistleblowing_updates', 'incident_days_lost_corrections']
BOUND = ['company_policies', 'esg_settings', 'grid_emission_factors', 'incident_days_lost_corrections', 'required_trainings']
EARLY_FUNCTIONS = ['whistleblowing_report_readable', 'incident_injured_is_caller']
LATE_FUNCTIONS = ['esg_set_grid_factor', 'grid_emission_factor_for', 'esg_scope2_bills', 'esg_scope2_monthly', 'esg_set_standard_hours',
                  'esg_safety_rates', 'record_incident_days_lost_correction', 'required_training_save', 'required_training_retire',
                  'esg_training_status', 'esg_training_coverage', 'company_policy_record', 'whistleblowing_report_file',
                  'whistleblowing_report_record_outside', 'whistleblowing_report_update', 'my_concerns']
VIEWS = ['company_policy_rows', 'whistleblowing_report_rows', 'incident_rows']
GRANTS = [('admin', 'action.manage_esg'), ('cco', 'action.manage_esg'), ('cco', 'data.view_whistleblowing'),
          ('cfo', 'action.manage_esg'), ('cfo', 'data.view_whistleblowing_escalated')]


def read(rel):
    return open(os.path.join(ROOT, rel)).read().rstrip('\n') + '\n'


def section(title, rel, text=None):
    return f'\n-- ── {title}(镜像原样:{rel})──\n' + (text if text is not None else read(rel))


perm_sql = read('db/tables/permissions.sql')
perm_rows = []
for c in NEW_CODES:
    m = re.search(r"\n    (\('" + re.escape(c) + r"', '(?:data|action)'.*?, \d+\)),?\n", perm_sql, re.S)
    assert m, c
    perm_rows.append(m.group(1))
views_row = re.search(r"\('action\.manage_esg',\s+(ARRAY\[[^\]]*\])\)", perm_sql).group(1)

# training_records:镜像里是 CREATE TABLE 的最后一列;线上是 ADD COLUMN
tr = read('db/tables/training_records.sql')
assert 'required_training_id uuid REFERENCES public.required_trainings (id)' in tr
assert 'CREATE INDEX idx_training_records_required ON public.training_records (required_training_id) WHERE deleted_at IS NULL;' in tr

bindings = read('db/views/zzz_change_log_triggers.sql')
bind_rows = ''.join(re.findall(
    r"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.(?:" + '|'.join(BOUND) + r")\n.*?\n"
    r"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.\w+\n.*?\n", bindings))
assert bind_rows.count('CREATE TRIGGER') == 2 * len(BOUND), bind_rows


def view_sql(name):
    s = read(f'db/views/{name}.sql')
    assert s.count(f'CREATE VIEW public.{name} ') == 1, name
    return s.replace(f'CREATE VIEW public.{name} ', f'CREATE OR REPLACE VIEW public.{name} ')


out = []
out.append("""-- db/migrations/2026-10-31-esg-2.sql
-- ESG-2(v1.4.86)—— Scope 2 与电网排放因子、误工事故频率、培训合规、公司制度登记簿与举报登记簿。Tim 2026-10-30(SYSTEM-MAP-4 Q1)与 2026-10-31 Q1–Q15。
--   由 db/scripts/build_esg2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】
--   ① 三个新码:action.manage_esg(admin · cco · cfo,Q9)· data.view_whistleblowing(cco)· data.view_whistleblowing_escalated(cfo,Q13)。
--      两个举报码都不授 admin(Q13 的例外,docs/role-matrix.md §13)。别的角色、任何账号的角色一个都不动。
--   ② 七张新表:esg_settings(标准日工时,单行,空)· grid_emission_factors(一年一个、带历史,空 —— Q1)· required_trainings ·
--      company_policies · whistleblowing_reports · whistleblowing_updates · incident_days_lost_corrections;training_records 加一列 required_training_id。
--   ③ 十八支函数(两支判据 + 十六支读 / 写)与三张视图(company_policy_rows · whistleblowing_report_rows 新建;incident_rows 换掉 days_lost 的算法、
--      末尾加两列)。
--   ④ 五张新表进变更记录;两张举报表登记为豁免(带理由,change_log_exclusions 换一版)。
-- 【不做什么】不碰审批开关、hook、任何存储桶与存储策略、任何账号;不改任何既有表的行;require_calibrated_since 保持空;不设任何值(因子与工时都留空,Q1 · Q4)。
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):没有 —— 新对象旧应用不读;incident_rows 只在末尾加列、days_lost 在没有更正时与原来同值;
--   training_records 多一列,旧应用的插入不写它(可空)。
-- 镜像(同一个提交):db/tables/{七张新表,training_records,permissions,role_permissions}.sql · db/functions/ 上面那十八支与 change_log_exclusions ·
--   db/views/{company_policy_rows,whistleblowing_report_rows,incident_rows,zzz_change_log_triggers}.sql · db/seeds/{eleven,seven}-roles-2026-10-31.sql。
-- 运行期配置的表:esg_settings(新建,引导一行、值为空 —— 引导默认值是对的:不猜一个 8)。
BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ESG2_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = 'public'
                WHERE c.relname IN (""" + ', '.join(f"'{t}'" for t in NEW_TABLES + ['company_policy_rows', 'whistleblowing_report_rows']) + """))
       OR EXISTS (SELECT 1 FROM permissions WHERE code IN (""" + ', '.join(f"'{c}'" for c in NEW_CODES) + """))
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'training_records' AND column_name = 'required_training_id') THEN
        RAISE EXCEPTION 'ESG2_PRE|an ESG-2 table, view, column or code already exists';
    END IF;
    IF (SELECT count(*) FROM roles) <> 11 OR (SELECT count(*) FROM roles WHERE code IN ('admin', 'cco', 'cfo')) <> 3 THEN
        RAISE EXCEPTION 'ESG2_PRE|expected the 11 roles including admin, cco and cfo';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'ESG2_PRE|require_calibrated_since must be empty and the two CODs in place';
    END IF;
END;
$pre$;
CREATE TEMP TABLE esg2_grants_before ON COMMIT DROP AS
SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE esg2_user_roles_before ON COMMIT DROP AS
SELECT user_id, role_id, revoked_at FROM user_roles;
CREATE TEMP TABLE esg2_incident_rows_before ON COMMIT DROP AS
SELECT id, days_lost FROM incident_rows;

-- ── 1 · 三个新码(与 db/tables/permissions.sql 同几行)与它们的五处授予(与 db/tables/role_permissions.sql 同)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
""" + ',\n'.join('    ' + r for r in perm_rows) + """;
UPDATE public.permissions SET requires_view_any = """ + views_row + """ WHERE code = 'action.manage_esg';
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, g.code FROM (VALUES """ + ', '.join(f"('{r}', '{c}')" for r, c in GRANTS) + """) AS g(role, code)
  JOIN public.roles r ON r.code = g.role
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")
out.append('\n-- ── 2 · 新的读策略要调的两支判据(镜像原样)──\n')
for f in EARLY_FUNCTIONS:
    out.append(read(f'db/functions/{f}.sql'))
for t in ['esg_settings', 'grid_emission_factors', 'required_trainings']:
    out.append(section(f'3 · {t}', f'db/tables/{t}.sql'))
out.append("""
-- ── 3 · training_records 加一列(镜像 db/tables/training_records.sql 里它是 CREATE TABLE 的最后一列)──
ALTER TABLE public.training_records ADD COLUMN required_training_id uuid REFERENCES public.required_trainings (id);
CREATE INDEX idx_training_records_required ON public.training_records (required_training_id) WHERE deleted_at IS NULL;
""")
for t in ['company_policies', 'whistleblowing_reports', 'whistleblowing_updates', 'incident_days_lost_corrections']:
    out.append(section(f'3 · {t}', f'db/tables/{t}.sql'))
out.append('\n-- ── 4 · 读新表的函数(镜像原样)──\n')
for f in LATE_FUNCTIONS:
    out.append(read(f'db/functions/{f}.sql'))
out.append(section('4 · 变更记录的豁免名单换一版(两张举报表)', 'db/functions/change_log_exclusions.sql'))
for v in VIEWS:
    out.append(section(f'5 · 视图 {v}(CREATE → CREATE OR REPLACE)', f'db/views/{v}.sql', view_sql(v)))
out.append('\n-- ── 6 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 同一串字)──\n' + bind_rows)
out.append("""
-- ── 7 · 自证 ──
DO $proof$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'ESG2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT user_id, role_id, revoked_at FROM user_roles EXCEPT SELECT * FROM esg2_user_roles_before)
               UNION ALL (SELECT * FROM esg2_user_roles_before EXCEPT SELECT user_id, role_id, revoked_at FROM user_roles)) THEN
        RAISE EXCEPTION 'ESG2_PROOF|a role grant to an account changed';
    END IF;
    IF EXISTS ((SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id EXCEPT SELECT * FROM esg2_grants_before)
               EXCEPT SELECT * FROM (VALUES """ + ', '.join(f"('{r}', '{c}')" for r, c in GRANTS) + """) g(code, permission_code))
       OR EXISTS (SELECT * FROM esg2_grants_before EXCEPT SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)
       OR (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
            WHERE (r.code, rp.permission_code) IN (""" + ', '.join(f"('{r}', '{c}')" for r, c in GRANTS) + """)) <> """ + str(len(GRANTS)) + """ THEN
        RAISE EXCEPTION 'ESG2_PROOF|role codes: expected exactly the five new grants';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE rp.permission_code IN ('data.view_whistleblowing', 'data.view_whistleblowing_escalated') AND r.code NOT IN ('cco', 'cfo')) THEN
        RAISE EXCEPTION 'ESG2_PROOF|a whistleblowing read code reached a role other than its one reader';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(ARRAY[""" + ', '.join(f"'{t}'" for t in NEW_TABLES) + """]) t
                WHERE NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass)
                   OR has_table_privilege('anon', 'public.' || t, 'SELECT')
                   OR has_table_privilege('authenticated', 'public.' || t, 'INSERT')
                   OR has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
                   OR has_table_privilege('authenticated', 'public.' || t, 'DELETE')
                   OR NOT has_table_privilege('authenticated', 'public.' || t, 'SELECT')) THEN
        RAISE EXCEPTION 'ESG2_PROOF|a new table is not read-only-under-RLS for authenticated and closed to anon';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['company_policy_rows', 'whistleblowing_report_rows', 'incident_rows']) v
                WHERE has_table_privilege('authenticated', 'public.' || v, 'INSERT') OR has_table_privilege('authenticated', 'public.' || v, 'UPDATE')
                   OR has_table_privilege('authenticated', 'public.' || v, 'DELETE') OR has_table_privilege('anon', 'public.' || v, 'SELECT')) THEN
        RAISE EXCEPTION 'ESG2_PROOF|a view is writable by authenticated or readable by anon';
    END IF;
    IF jsonb_array_length(change_log_coverage_gaps() -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'ESG2_PROOF|change-log coverage: %', change_log_coverage_gaps();
    END IF;
    IF (SELECT count(*) FROM esg_settings) <> 1 OR (SELECT standard_hours_per_day FROM esg_settings) IS NOT NULL
       OR EXISTS (SELECT 1 FROM grid_emission_factors) THEN
        RAISE EXCEPTION 'ESG2_PROOF|the two settings must ship unset (Q1 · Q4)';
    END IF;
    IF EXISTS ((SELECT id, days_lost FROM incident_rows EXCEPT SELECT * FROM esg2_incident_rows_before)
               UNION ALL (SELECT * FROM esg2_incident_rows_before EXCEPT SELECT id, days_lost FROM incident_rows)) THEN
        RAISE EXCEPTION 'ESG2_PROOF|incident_rows.days_lost changed for an incident with no correction';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'ESG2_PROOF|require_calibrated_since was set or a COD changed';
    END IF;
END;
$proof$;

NOTIFY pgrst, 'reload schema';

COMMIT;
""")
open(OUT, 'w').write(''.join(out))
print(OUT, sum(1 for _ in open(OUT)), 'lines')
