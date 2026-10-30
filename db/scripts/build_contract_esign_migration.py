#!/usr/bin/env python3
"""CONTRACT-ESIGN · builds db/migrations/2026-10-30-contract-esign.sql from the mirrors (edit the mirrors, then re-run; never hand-edit the output).

Order matters on live, where check_function_bodies is ON (a SQL body and a PL/pgSQL %ROWTYPE resolve at CREATE time; the rebuild has it off):
  permission code + admin grant → helpers that read only existing tables → the four tables (each table's own triggers / policies need only what
  came before it) → the functions that read the new tables → change-log bindings → buckets and storage policies → a self-check.
usage: python3 db/scripts/build_contract_esign_migration.py
"""
import os
import re

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..')
OUT = os.path.join(ROOT, 'db/migrations/2026-10-30-contract-esign.sql')


def read(rel):
    return open(os.path.join(ROOT, rel)).read().rstrip('\n') + '\n'


def section(title, rel):
    return f'\n-- ── {title}(镜像原样:{rel})──\n' + read(rel)


perm_sql = read('db/tables/permissions.sql')
perm_row = re.search(r"\n(    \('action\.manage_signatories', 'action'.*?1011\)),", perm_sql, re.S).group(1)
views_row = re.search(r"\('action\.manage_signatories',\s+(ARRAY\[[^\]]*\])\)", perm_sql).group(1)

storage = read('db/storage/buckets-and-policies.sql')
bucket_rows = ''.join(re.findall(r"INSERT INTO storage\.buckets \(id, name, public, file_size_limit, allowed_mime_types\)\nVALUES \('(?:contract-files|signing-assets)'.*?;\n", storage, re.S))
policy_block = storage[storage.index('-- ── 合同的电子文件与签字用的图'):]

bindings = read('db/views/zzz_change_log_triggers.sql')
bind_rows = ''.join(re.findall(
    r"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.(?:company_stamps|contract_files|contract_signatories|signature_specimens)\n.*?\n"
    r"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.\w+\n.*?\n", bindings))
assert bind_rows.count('CREATE TRIGGER') == 8, bind_rows

LATE_FUNCTIONS = ['contract_signatory_add', 'contract_signatory_remove', 'signing_asset_can_upload', 'signing_asset_can_read',
                  'signature_specimen_record', 'company_stamp_record', 'contract_file_begin', 'contract_file_finish', 'contract_file_abandon',
                  'contract_sign_begin', 'contract_file_void', 'contract_file_can_upload', 'contract_file_can_read']

out = []
out.append("""-- db/migrations/2026-10-30-contract-esign.sql
-- CONTRACT-ESIGN(v1.4.85)—— 合同的电子文件、具名签署人、公司印章、在系统里签字。Tim 2026-10-29 的裁定(第 2 条)与 2026-10-30 Step 0 的 Q1–Q12。
--   由 db/scripts/build_contract_esign_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】
--   ① 新码 action.manage_signatories(签署人名单与公司印章,Q3),只授 admin;查看码声明 action.manage_signatories · module.suppliers.view。
--   ② 四张新表:contract_signatories(名单,具名的人)· signature_specimens(签署人本人画的签名,Q4)· company_stamps(公司印章)·
--      contract_files(合同文件的每一个版本:original → signed → countersigned;sha256 每一个版本都有;作废要理由,Q7)。只经函数写。
--   ③ 函数:contract_signatory_add / _remove · signature_specimen_record · company_stamp_record · contract_file_begin / _finish / _abandon ·
--      contract_sign_begin(只在生效中的合同上、只给名单上的人、要 5 分钟内重新输入过密码 —— 令牌 amr 里的 password 项,Q1 · Q3 · Q5)·
--      contract_file_void · 四条存储判据(contract_file_can_upload / _can_read · signing_asset_can_upload / _can_read)·
--      contract_file_readable(那一侧的读码 + 价格码,Q8)· contract_signatory_active · signing_password_verified_at · 两支守卫。
--   ④ 两个私有桶:contract-files(25 MB · 只收 PDF,Q12)与 signing-assets(1 MB · 只收 PNG);四条存储策略(传 / 读各两条),没有 UPDATE、没有 DELETE。
--   ⑤ 四张表进变更记录(名单的每一次增减都记下 —— Tim 2026-10-29)。
-- 【不做什么】不碰审批开关、hook、portal-uploads 与 claim-receipts 两个桶与它们的策略、任何账号与角色的授予(admin 角色多一个码是本刀唯一的授权改动);
--   不改任何既有的表、函数或策略;require_calibrated_since 保持空。
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):没有 —— 本迁移只新增对象,旧应用一个都不读;admin 多出的码旧应用不认识也不用。
-- 镜像(同一个提交):db/tables/{contract_signatories,signature_specimens,company_stamps,contract_files,permissions,role_permissions}.sql ·
--   db/functions/ 上面那十九支 · db/views/zzz_change_log_triggers.sql · db/storage/buckets-and-policies.sql · db/seeds/{eleven,seven}-roles-2026-10-30.sql。
-- 运行期配置的表:本刀一张都没碰。
BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'CES_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.contract_files') IS NOT NULL OR to_regclass('public.contract_signatories') IS NOT NULL
       OR to_regclass('public.signature_specimens') IS NOT NULL OR to_regclass('public.company_stamps') IS NOT NULL
       OR EXISTS (SELECT 1 FROM storage.buckets WHERE id IN ('contract-files', 'signing-assets'))
       OR EXISTS (SELECT 1 FROM permissions WHERE code = 'action.manage_signatories') THEN
        RAISE EXCEPTION 'CES_PRE|the e-sign tables, buckets or code already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 58 OR (SELECT count(*) FROM storage.buckets) <> 21 THEN
        RAISE EXCEPTION 'CES_PRE|expected 58 storage policies and 21 buckets';
    END IF;
    IF (SELECT count(*) FROM roles) <> 11 OR NOT EXISTS (SELECT 1 FROM roles WHERE code = 'admin') THEN
        RAISE EXCEPTION 'CES_PRE|expected the 11 roles including admin';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'CES_PRE|require_calibrated_since must be empty and the two COD byte strings recorded';
    END IF;
END;
$pre$;
CREATE TEMP TABLE ces_policies_before ON COMMIT DROP AS
SELECT policyname, cmd, roles::text AS roles, COALESCE(qual, '') AS qual, COALESCE(with_check, '') AS with_check FROM pg_policies WHERE schemaname = 'storage';
CREATE TEMP TABLE ces_buckets_before ON COMMIT DROP AS
SELECT id, name, public, file_size_limit, allowed_mime_types::text AS mimes FROM storage.buckets;
CREATE TEMP TABLE ces_grants_before ON COMMIT DROP AS
SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE ces_user_roles_before ON COMMIT DROP AS
SELECT user_id, role_id, revoked_at FROM user_roles;

-- ── 1 · 新码(与 db/tables/permissions.sql 同一行)+ admin 持它(admin 持目录里的每一个码 —— db/tables/role_permissions.sql)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
""" + perm_row + """;
UPDATE public.permissions SET requires_view_any = """ + views_row + """ WHERE code = 'action.manage_signatories';
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.manage_signatories' FROM public.roles r WHERE r.code = 'admin'
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")
out.append(section('2 · 只读既有表的判据与守卫', 'db/functions/contract_file_readable.sql'))
out.append(read('db/functions/signing_password_verified_at.sql'))
out.append(read('db/functions/guard_signing_asset_write.sql'))
out.append(read('db/functions/guard_contract_file_write.sql'))
out.append(section('3 · 名单', 'db/tables/contract_signatories.sql'))
out.append(section('4 · 「我在不在名单上」(读名单那张表)', 'db/functions/contract_signatory_active.sql'))
out.append(section('5 · 签字样本', 'db/tables/signature_specimens.sql'))
out.append(section('6 · 公司印章', 'db/tables/company_stamps.sql'))
out.append(section('7 · 合同文件', 'db/tables/contract_files.sql'))
out.append('\n-- ── 8 · 读新表的函数(镜像原样)──\n')
for f in LATE_FUNCTIONS:
    out.append(read(f'db/functions/{f}.sql'))
out.append('\n-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 同一串字)──\n' + bind_rows)
out.append('\n-- ── 10 · 存储(与 db/storage/buckets-and-policies.sql 逐字同一份):两个桶 · 四条策略 ──\n' + bucket_rows + '\n' + policy_block)
out.append("""
-- ── 11 · 自证 ──
DO $proof$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'CES_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT user_id, role_id, revoked_at FROM user_roles EXCEPT SELECT * FROM ces_user_roles_before)
               UNION ALL (SELECT * FROM ces_user_roles_before EXCEPT SELECT user_id, role_id, revoked_at FROM user_roles)) THEN
        RAISE EXCEPTION 'CES_PROOF|a role grant to an account changed';
    END IF;
    IF EXISTS ((SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id EXCEPT SELECT * FROM ces_grants_before)
               EXCEPT SELECT 'admin', 'action.manage_signatories')
       OR EXISTS (SELECT * FROM ces_grants_before EXCEPT SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)
       OR NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin' AND rp.permission_code = 'action.manage_signatories') THEN
        RAISE EXCEPTION 'CES_PROOF|role codes: expected exactly one new grant (admin · action.manage_signatories)';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') <> 62
       OR EXISTS (SELECT policyname, cmd, roles, qual, with_check FROM ces_policies_before
                  EXCEPT SELECT policyname, cmd, roles::text, COALESCE(qual, ''), COALESCE(with_check, '') FROM pg_policies WHERE schemaname = 'storage')
       OR EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'storage' AND cmd IN ('UPDATE', 'DELETE', 'ALL')
                   AND COALESCE(qual, '') || COALESCE(with_check, '') ~ '(contract-files|signing-assets)') THEN
        RAISE EXCEPTION 'CES_PROOF|storage policies: expected the 58 unchanged plus four, and no update / delete on the two new buckets';
    END IF;
    IF (SELECT count(*) FROM storage.buckets) <> 23
       OR EXISTS (SELECT id, name, public, file_size_limit, mimes FROM ces_buckets_before
                  EXCEPT SELECT id, name, public, file_size_limit, allowed_mime_types::text FROM storage.buckets)
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'contract-files' AND NOT public AND file_size_limit = 26214400 AND allowed_mime_types = ARRAY['application/pdf'])
       OR NOT EXISTS (SELECT 1 FROM storage.buckets WHERE id = 'signing-assets' AND NOT public AND file_size_limit = 1048576 AND allowed_mime_types = ARRAY['image/png']) THEN
        RAISE EXCEPTION 'CES_PROOF|buckets: expected the 21 unchanged plus contract-files (25 MB · PDF) and signing-assets (1 MB · PNG), both private';
    END IF;
    IF EXISTS (SELECT 1 FROM unnest(ARRAY['contract_signatories', 'signature_specimens', 'company_stamps', 'contract_files']) t
                WHERE NOT (SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || t)::regclass)
                   OR has_table_privilege('anon', 'public.' || t, 'SELECT')
                   OR has_table_privilege('authenticated', 'public.' || t, 'INSERT')
                   OR has_table_privilege('authenticated', 'public.' || t, 'UPDATE')
                   OR has_table_privilege('authenticated', 'public.' || t, 'DELETE')
                   OR NOT has_table_privilege('authenticated', 'public.' || t, 'SELECT')) THEN
        RAISE EXCEPTION 'CES_PROOF|a new table is not read-only-under-RLS for authenticated and closed to anon';
    END IF;
    IF jsonb_array_length(change_log_coverage_gaps() -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'CES_PROOF|change-log coverage: %', change_log_coverage_gaps();
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'CES_PROOF|require_calibrated_since was set or a COD changed';
    END IF;
END;
$proof$;

NOTIFY pgrst, 'reload schema';

COMMIT;
""")
open(OUT, 'w').write(''.join(out))
print(OUT, sum(1 for _ in open(OUT)), 'lines')
