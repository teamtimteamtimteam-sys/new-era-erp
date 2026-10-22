#!/usr/bin/env python3
"""PAYROLL-PAY-REVERSAL-1(v1.4.66):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新函数、换掉的函数(同签名)、
payroll_requests 的新种类与新列、它的遮蔽视图、leave_types 的四列与它们的值,原样从 db/tables · db/functions · db/views 抽出。
照抄 build_claim_receipts1_migration.py 的形状(前提 → 之前的读数 → 改动 → 同一笔事务里的自证)。
跑法:python3 db/scripts/build_payroll_pay_reversal1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-22-payroll-pay-reversal-1.sql"

NEW_SIGS = {
    "assert_entry_not_bank_matched": "public.assert_entry_not_bank_matched(uuid)",
    "payroll_payment_entry_kind": "public.payroll_payment_entry_kind(uuid)",
    "reverse_payroll_payment_internal": "public.reverse_payroll_payment_internal(uuid, date, text)",
    "submit_payroll_payment_reversal_request": "public.submit_payroll_payment_reversal_request(uuid, text)",
    "reverse_payroll_payment": "public.reverse_payroll_payment(uuid, date)",
    "payroll_payment_entries": "public.payroll_payment_entries(uuid[])",
    "leave_service_entitlement": "public.leave_service_entitlement(text, date, date)",
    "leave_balances": "public.leave_balances(uuid, date)",
}
INTERNAL = ["reverse_payroll_payment_internal", "assert_entry_not_bank_matched", "payroll_payment_entry_kind",
            "leave_service_entitlement"]
REPLACED_FUNCS = [
    "payroll_request_dry_run",           # Q1:第三种申请试跑工资付款冲销的引擎
    "journal_entry_reversal_route",      # Q8:第五个答案 'payroll_payment'
    "reverse_journal_entry",             # Q8:按名拒 JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL
    "journal_request_submit_internal",   # Q8:同上(冲销申请的提交)
    "journal_request_post_internal",     # Q8:同上(冲销申请的过账)
    "reverse_payment_internal",          # Q6:银行行已配对就不冲
    "reverse_bank_transfer_internal",    # Q6:同上
    "reverse_wht_remittance_internal",   # Q6:同上
    "leave_balance_internal",            # B1:按服务期给额度
]
REAL_ACCOUNTS = ["admin@swm-os.test", "chooer@evoltrya.test", "fusheng@evoltrya.test", "phua@evolytra.test",
                 "sandra@evoltrya.test", "tim@evoltrya.test", "vince@evoltrya.test"]
TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"          # tim@evoltrya.test(cfo)—— 只拿来【读】勾稽

# 表 → (where, 之前要剥掉的键, 之后要剥掉的键)。payroll_requests 之后多一列 target_entry_id;leave_types 之后多四列。
DIGEST_TABLES = {
    "payroll_requests": ("", [], ["target_entry_id"]),
    "leave_types": ("", ["updated_at"], ["updated_at", "qualifying_service_months", "service_rule", "service_steps", "prorate_minimum_days"]),
    "payroll_periods": ("", [], []), "payroll_lines": ("", [], []),
    "journal_entries": ("", [], []), "journal_lines": ("", [], []), "payments": ("", [], []),
    "payment_requests": ("", [], []), "bank_transfers": ("", [], []), "wht_remittances": ("", [], []),
    "bank_statements": ("", [], []), "bank_statement_lines": ("", [], []), "bank_line_matches": ("", [], []),
    "journal_requests": ("", [], []), "leave_requests": ("", [], []), "leave_grants": ("", [], []),
    "employees": ("", [], []), "accounts": ("", [], []), "approval_log": ("", [], []),
    "permissions": ("", [], []), "role_permissions": ("", [], []), "roles": ("", [], []), "user_roles": ("", [], []),
    "finance_settings": ("", [], []), "ingest_settings": ("", [], []), "account_settings": ("", [], []),
    "cod_issues": ("", [], []),
}


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    assert body.count("CREATE OR REPLACE FUNCTION") == 1, name
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def digest(t, where, drop):
    j = "to_jsonb(t)" + "".join(f" - '{k}'" for k in drop)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t {where})"


def grab(text, pattern, what):
    m = re.search(pattern, text, re.S)
    assert m, what
    return m.group(0)


for f in list(NEW_SIGS) + REPLACED_FUNCS:
    assert (ROOT / f"db/functions/{f}.sql").exists(), f

pr = mirror("db/tables/payroll_requests.sql")
KIND_CHECK = grab(pr, r"CHECK \(kind IN \('post', 'reversal', 'payment_reversal'\)\)", "kind check")
REASON_CHECK = grab(pr, r"CHECK \(\n        kind NOT IN \('reversal', 'payment_reversal'\) OR btrim\(COALESCE\(notes, ''\)\) <> ''\)", "reason check")
TARGET_CHECK = grab(pr, r"CHECK \(\(kind = 'payment_reversal'\) = \(target_entry_id IS NOT NULL\)\)", "target check")
TARGET_COMMENT = grab(pr, r"COMMENT ON COLUMN public\.payroll_requests\.target_entry_id IS\n.*?;\n", "target comment")
TARGET_INDEX = grab(pr, r"CREATE INDEX payroll_requests_target_entry_id_rel ON public\.payroll_requests \(target_entry_id\);\n", "target index")
GRANT = grab(pr, r"GRANT SELECT \(id, payroll_period_id.*?TO authenticated;\n", "column grant")
assert "target_entry_id)" in GRANT
VIEW_DDL = mirror("db/views/payroll_requests_masked.sql")
VIEW_BODY = grab(VIEW_DDL, r"CREATE VIEW public\.payroll_requests_masked WITH \(security_invoker = off\) AS\n.*?;\n", "masked view")
VIEW_BODY = VIEW_BODY.replace("CREATE VIEW", "CREATE OR REPLACE VIEW", 1)
assert "target_entry_id\n   FROM payroll_requests" in VIEW_BODY

lt = mirror("db/tables/leave_types.sql")
LT_COLS = {
    "qualifying_service_months": grab(lt, r"qualifying_service_months      smallint NOT NULL DEFAULT 0 CHECK \(qualifying_service_months >= 0\)", "q col"),
    "service_rule": grab(lt, r"service_rule                   text NOT NULL DEFAULT 'full' CHECK \(service_rule IN \('full', 'steps', 'prorate_first_year'\)\)", "rule col"),
    "service_steps": grab(lt, r"service_steps                  jsonb", "steps col"),
    "prorate_minimum_days": grab(lt, r"prorate_minimum_days           numeric CHECK \(prorate_minimum_days IS NULL OR prorate_minimum_days >= 0\)", "min col"),
}
LT_SHAPE = grab(lt, r"CHECK \(\(service_rule = 'steps'\) = \(service_steps IS NOT NULL\)\)", "steps shape")
LT_UPDATES = re.findall(r"^UPDATE public\.leave_types SET .*?;$", lt, re.M)
assert len(LT_UPDATES) == 5, LT_UPDATES

HEADER = """-- db/migrations/2026-10-22-payroll-pay-reversal-1.sql
-- PAYROLL-PAY-REVERSAL-1 —— 工资 / CPF / 扣款付款的冲销路;四条冲销路都不冲已配对的银行行;新入职的人按服务期给假;/me 列出每一种假的余额。
--   (v1.4.66;发布那一行在 docs/handbacks/PAYROLL-PAY-REVERSAL-1.md 的抬头。)
--   由 db/scripts/build_payroll_pay_reversal1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-22 的裁定:Step 0 Q1–Q13)
--   ① payroll_requests 第三种 payment_reversal(target_entry_id = 那一张付款分录):财务提(submit_payroll_payment_reversal_request)·
--      CFO 批(decide_payroll_request,不改)· 财务执行(reverse_payroll_payment,冲销日由人给、必填)。整张冲(Q2);期间仍 posted,
--      清掉那张分录付过的行的戳(含净额为零的行)或那一期 CPF / 扣款的日期与链接(Q5);工资 / CPF / 扣款同一种申请(Q7)。
--   ② 通用日记账冲销(reverse_journal_entry · 冲销申请的提交与过账)对工资付款分录与它们的冲销按名拒
--      JE_REVERSE_USE_PAYROLL_PAYMENT_REVERSAL(journal_entry_reversal_route 的第五个答案 'payroll_payment',Q8)。
--   ③ 银行行已经配上对账单行的分录,四条冲销路(工资付款 · 付款 · 行内转账 · 代扣税缴纳)在提、批、执行三处都按名拒
--      REVERSAL_BANK_MATCHED(assert_entry_not_bank_matched,Q6)。不自动取消配对。
--   ④ leave_types 四列(资格期 · 规矩 · 台阶 · 折算下限)与它们的值;leave_balance_internal 按服务期给额度(B1,Q10 · Q11)。
--   ⑤ leave_balances:一个人每一种有额度的假别的余额,一次调用(B2,Q12)。payroll_payment_entries:付薪页上每一次付款一行。
--
-- 【不做什么】不碰审批开关、hook、存储、任何账号与角色;不建任何单据;不改任何分录;require_calibrated_since 保持空。
--   既有的行一行没动,只有 leave_types 八行被写上新的四列(这是本刀的意图;那八行原有各列逐字未变)。
--
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):旧的凭证页对工资付款分录仍画「提冲销申请」—— 按下去库按名拒(新码,旧应用不认得,
--   印原文);旧的 /me 只读年假(leave_balance 签名未变)—— 病假余额按服务期变成 0(线上 6 个人都不满 3 个月;线上 0 张非年假请假)。
--   其余都是收紧或新增,旧应用一条都碰不到。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变;既有的行逐字未变;
--   本事务写的变更记录只有 leave_types 那八行;清单 ↔ 总账两边未解释仍是 0.00、与迁移之前逐字相同;两张 COD 原样;328 张表;
--   变更记录覆盖零缺口、豁免 9;匿名面与门户面不变;没有一张视图对 anon / authenticated 带写授权;在途单据一张不少、每一张仍有一个决定人。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

VIEW_WRITE_SQL = """(SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace CROSS JOIN (VALUES ('anon'), ('authenticated')) g(r)
      WHERE n.nspname = 'public' AND c.relkind = 'v'
        AND (has_table_privilege(g.r, c.oid, 'INSERT') OR has_table_privilege(g.r, c.oid, 'UPDATE')
             OR has_table_privilege(g.r, c.oid, 'DELETE') OR has_table_privilege(g.r, c.oid, 'TRUNCATE')))"""

acct_list = ", ".join(f"'{a}'" for a in REAL_ACCOUNTS)
RECON_READ = f"""PERFORM set_config('request.jwt.claims', '{{"sub":"{TIM}","role":"authenticated"}}', true);
    v_recon := list_ledger_reconciliation();
    PERFORM set_config('request.jwt.claims', '', true);"""

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────
CREATE TEMP TABLE ppr1_recon_before (j jsonb) ON COMMIT DROP;
DO $pre$
DECLARE
    v_recon jsonb;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'PPR1_PRE|approvals are expected ON';
    END IF;
    IF to_regprocedure('{NEW_SIGS["reverse_payroll_payment"]}') IS NOT NULL
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'payroll_requests' AND column_name = 'target_entry_id')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'leave_types' AND column_name = 'service_rule') THEN
        RAISE EXCEPTION 'PPR1_PRE|this migration has already run';
    END IF;
    IF EXISTS (SELECT 1 FROM payroll_requests WHERE kind NOT IN ('post', 'reversal')) THEN
        RAISE EXCEPTION 'PPR1_PRE|unexpected payroll request kinds';
    END IF;
    IF EXISTS (SELECT 1 FROM journal_requests jr JOIN journal_entries je ON je.id = jr.target_entry_id
                WHERE je.source_type = 'payroll' AND jr.status IN ('submitted', 'approved')) THEN
        RAISE EXCEPTION 'PPR1_PRE|an open journal request targets a payroll entry (Step 0 measured 0) — it would be stranded by Q8';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ({acct_list})) <> 7
       OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '{TIM}' AND email = 'tim@evoltrya.test') THEN
        RAISE EXCEPTION 'PPR1_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 328 THEN
        RAISE EXCEPTION 'PPR1_PRE|expected 328 public tables';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'PPR1_PRE|expected 9 change-log exclusions';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'PPR1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'PPR1_PRE|expected the two recorded COD byte strings';
    END IF;
    IF (SELECT count(*) FROM leave_types WHERE code IN ('sick', 'hospitalisation', 'childcare', 'extended_childcare', 'maternity',
            'paternity', 'shared_parental', 'infant_care', 'marriage', 'compassionate', 'examination')
            AND default_days_per_year IS NOT NULL AND NOT is_accrued) <> 11 THEN
        RAISE EXCEPTION 'PPR1_PRE|expected the 11 non-annual quota leave types';
    END IF;
    -- 清单 ↔ 总账此刻两边未解释都是 0.00 —— 以 tim@(cfo)身份【读】,读完即清
    {RECON_READ}
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'PPR1_PRE|the list-vs-ledger reconciliation is expected at 0.00 unexplained: %', v_recon;
    END IF;
    INSERT INTO ppr1_recon_before (j) VALUES (v_recon - 'base_currency');
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d, _) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE ppr1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE ppr1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE ppr1_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE ppr1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
CREATE TEMP TABLE ppr1_storage_before ON COMMIT DROP AS
SELECT (SELECT count(*) FROM storage.objects) AS objects, (SELECT count(*) FROM storage.buckets) AS buckets,
       (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage') AS policies;
""")

parts.append(f"""
-- ── 1 · payroll_requests:第三种 payment_reversal 与它冲的那一张分录(镜像:db/tables/payroll_requests.sql)──
ALTER TABLE public.payroll_requests DROP CONSTRAINT payroll_requests_kind_check;
ALTER TABLE public.payroll_requests ADD CONSTRAINT payroll_requests_kind_check {KIND_CHECK};
ALTER TABLE public.payroll_requests ADD COLUMN target_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT;
ALTER TABLE public.payroll_requests DROP CONSTRAINT payroll_requests_reversal_reason;
ALTER TABLE public.payroll_requests ADD CONSTRAINT payroll_requests_reversal_reason {REASON_CHECK};
ALTER TABLE public.payroll_requests ADD CONSTRAINT payroll_requests_payment_reversal_target {TARGET_CHECK};
{TARGET_INDEX}{TARGET_COMMENT}
-- 列授权不随 ADD COLUMN 延伸(AGENTS.md「Adding a column to a masked table」):同一支迁移里补进列授权与遮蔽视图
{GRANT}
{VIEW_BODY}
-- ── 2 · leave_types:按服务期给额度的四列与它们的值(镜像:db/tables/leave_types.sql)──
ALTER TABLE public.leave_types ADD COLUMN {LT_COLS["qualifying_service_months"]};
ALTER TABLE public.leave_types ADD COLUMN {LT_COLS["service_rule"]};
ALTER TABLE public.leave_types ADD COLUMN {LT_COLS["service_steps"]};
ALTER TABLE public.leave_types ADD COLUMN {LT_COLS["prorate_minimum_days"]};
ALTER TABLE public.leave_types ADD CONSTRAINT leave_types_service_steps_shape {LT_SHAPE};
""" + "\n".join(LT_UPDATES) + "\n")

parts.append("\n-- ── 3 · 新函数(镜像原样)──\n")
for f in NEW_SIGS:
    parts.append(fn(f))
parts.append("\n-- ── 4 · 换掉的函数(镜像原样,同签名)──\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

grants = "".join(
    f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\nGRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n"
    for sig in NEW_SIGS.values())
grants += "".join(f"REVOKE EXECUTE ON FUNCTION {NEW_SIGS[f]} FROM authenticated;\n" for f in INTERNAL)
parts.append(f"""
-- ── 5 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
{grants}REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.payroll_requests_masked FROM anon, authenticated, PUBLIC;
""")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "ppr1_pending_decider_check")
assert dec.count("'decide_expense_claim'") == 1
dec = dec.replace("'decide_expense_claim'", "'decide_expense_claim_items'")   # 名册登记的是真正把关的那一支(CLAIM-RECEIPTS-1 同改)
parts.append("\n-- ── 6 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

digest_checks = "\n       OR ".join(
    f"{digest(t, w, da)} IS DISTINCT FROM (SELECT {t} FROM ppr1_rows_before)" for t, (w, _, da) in DIGEST_TABLES.items())
internal_exec = "\n       OR ".join(f"has_function_privilege('authenticated', '{NEW_SIGS[f]}', 'EXECUTE')" for f in INTERNAL)
door_exec = "\n       OR ".join(f"NOT has_function_privilege('authenticated', '{NEW_SIGS[f]}', 'EXECUTE')"
                                for f in NEW_SIGS if f not in INTERNAL)
anon_exec = "\n       OR ".join(f"has_function_privilege('anon', '{sig}', 'EXECUTE')" for sig in NEW_SIGS.values())

parts.append(f"""
CREATE TEMP TABLE ppr1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    v_recon jsonb;
    k       text;
BEGIN
    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'PPR1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM ppr1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM ppr1_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'PPR1_PROOF|an account or its roles changed';
    END IF;

    -- ② 在途单据一张不少、一张不多;既有的行逐字未变(payroll_requests 比去掉新列之后的,leave_types 比去掉四列与 updated_at 之后的);
    --   本事务写的变更记录只有 leave_types 那八行
    IF EXISTS ((SELECT b.k, b.id FROM ppr1_pending_before b EXCEPT SELECT a2.k, a2.id FROM ppr1_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM ppr1_pending_after a2 EXCEPT SELECT b.k, b.id FROM ppr1_pending_before b)) THEN
        RAISE EXCEPTION 'PPR1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'PPR1_PROOF|a pre-existing row changed';
    END IF;
    SELECT count(*), COALESCE(string_agg(DISTINCT c.table_name, ','), '') INTO v_n, v_bad
      FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM ppr1_log_before), 0) AND c.txid = txid_current();
    IF v_n <> 8 OR v_bad <> 'leave_types' THEN
        RAISE EXCEPTION 'PPR1_PROOF|expected exactly the 8 leave_types change-log rows, got % on %', v_n, v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'PPR1_PROOF|require_calibrated_since was set or a COD changed';
    END IF;
    IF (SELECT row(objects, buckets, policies) FROM ppr1_storage_before) IS DISTINCT FROM
       row((SELECT count(*) FROM storage.objects), (SELECT count(*) FROM storage.buckets), (SELECT count(*) FROM pg_policies WHERE schemaname = 'storage')) THEN
        RAISE EXCEPTION 'PPR1_PROOF|storage changed';
    END IF;

    -- ③ 清单 ↔ 总账:两边未解释仍是 0.00,而且与迁移之前逐字相同
    {RECON_READ}
    IF (v_recon - 'base_currency') IS DISTINCT FROM (SELECT j FROM ppr1_recon_before)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                   WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'PPR1_PROOF|the list-vs-ledger reconciliation moved: %', v_recon;
    END IF;

    -- ④ 结构:新函数都在;四支内层 authenticated 调不到,五支外门调得到,anon 一支都调不到;线上三张工资付款分录的路由是 payroll_payment;
    --   leave_types 的值就是裁定
    IF {" OR ".join(f"to_regprocedure('{sig}') IS NULL" for sig in NEW_SIGS.values())} THEN
        RAISE EXCEPTION 'PPR1_PROOF|a new function is missing';
    END IF;
    IF {internal_exec} THEN
        RAISE EXCEPTION 'PPR1_PROOF|an internal function is executable by authenticated';
    END IF;
    IF {door_exec} THEN
        RAISE EXCEPTION 'PPR1_PROOF|a door is not executable by authenticated';
    END IF;
    IF {anon_exec} THEN
        RAISE EXCEPTION 'PPR1_PROOF|anon executes a new function';
    END IF;
    IF EXISTS (SELECT 1 FROM journal_entries je WHERE je.source_type = 'payroll' AND je.status = 'posted'
                AND payroll_payment_entry_kind(je.id) IS NOT NULL AND journal_entry_reversal_route(je.id) <> 'payroll_payment')
       OR EXISTS (SELECT 1 FROM payroll_periods pp WHERE pp.journal_entry_id IS NOT NULL
                   AND journal_entry_reversal_route(pp.journal_entry_id) NOT IN ('source_path', 'reversed')) THEN
        RAISE EXCEPTION 'PPR1_PROOF|a payroll payment entry does not route to payroll_payment, or a posting entry moved';
    END IF;
    SELECT string_agg(code || ':' || qualifying_service_months || ':' || service_rule || ':' || COALESCE(service_steps::text, '-')
                      || ':' || COALESCE(prorate_minimum_days::text, '-'), ' ' ORDER BY code) INTO v_bad
      FROM leave_types WHERE default_days_per_year IS NOT NULL;
    IF v_bad <> 'childcare:3:prorate_first_year:-:2 compassionate:0:full:-:- examination:0:full:-:- extended_childcare:3:prorate_first_year:-:- '
                || 'hospitalisation:3:steps:{{"3": 15, "4": 30, "5": 45}}:- infant_care:3:full:-:- marriage:0:full:-:- maternity:3:full:-:- '
                || 'paternity:3:full:-:- shared_parental:3:full:-:- sick:3:steps:{{"3": 5, "4": 8, "5": 11}}:-' THEN
        RAISE EXCEPTION 'PPR1_PROOF|leave_types service rules are not the ruling: %', v_bad;
    END IF;

    -- ⑤ 328 张表;变更记录覆盖零缺口、豁免 9;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 328 THEN
        RAISE EXCEPTION 'PPR1_PROOF|expected 328 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'PPR1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'PPR1_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'PPR1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑥ 匿名面与门户面不变
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'PPR1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'PPR1_PROOF|supplier_portal executes: %', v_bad;
    END IF;

    -- ⑦ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.ppr1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'PPR1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.ppr1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'PPR1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.ppr1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
