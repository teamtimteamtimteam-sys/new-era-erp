#!/usr/bin/env python3
"""EXPENSE-MULTILINE-1(v1.4.64):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 换掉的函数与新函数原样从 db/functions 抽出,
两张新表的建表脚本原样从 db/tables 抽出,表头上的两条延迟约束触发器与它们的函数从表头镜像里抽出。照抄 build_fin_chain1_migration.py 的形状。
跑法:python3 db/scripts/build_expense_multiline1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-20-expense-multiline-1.sql"

REPLACED_FUNCS = [                                    # 同签名
    "record_expense",                 # Q11:单行包装
    "reverse_expense_internal",       # 镜像单带着原单的行
    "post_electricity_allocation", "relieve_processing_accruals",   # 系统写入者各写一行
    "apply_prepayment",               # 不再读表头的 tax_rate_pct
    "guard_gst_switch",               # 税码在行上
    "submit_expense_claim",           # Step 0b Q8:单笔包装
    "decide_expense_claim",           # Step 0b Q8:单笔包装
    "trail_subject_members",          # 两张新表进审计记录
    "approval_chain_gates",           # 名册登记真正把关的那一支(decide_expense_claim_items)
]
NEW_FUNCS = ["record_expense_document", "submit_expense_claim_items", "decide_expense_claim_items"]
NEW_SIGS = {
    "record_expense_document": "public.record_expense_document(date, text, jsonb, text, text, uuid, text, text, jsonb, uuid, uuid, text, numeric, text, uuid, boolean)",
    "submit_expense_claim_items": "public.submit_expense_claim_items(uuid, text, text, jsonb)",
    "decide_expense_claim_items": "public.decide_expense_claim_items(uuid, boolean, jsonb, date, text)",
}
TRIGGER_FUNCS = ["guard_expense_totals()", "guard_expense_claim_totals()", "guard_expense_line_mutation()",
                 "guard_expense_claim_item_mutation()"]
REAL_ACCOUNTS = ["admin@swm-os.test", "chooer@evoltrya.test", "fusheng@evoltrya.test", "phua@evolytra.test",
                 "sandra@evoltrya.test", "tim@evoltrya.test", "vince@evoltrya.test"]
TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"          # tim@evoltrya.test(cfo)—— 只拿来【读】勾稽
EXP_DROP = ["account_code", "tax_code", "tax_rate_pct"]
CLM_DROP = ["account_code", "tax_code", "no_receipt_reason"]

# 前后比对的表(既有的行逐字未变;expenses / expense_claims 比的是拿掉搬走的列之后剩下的那些)
DIGEST_TABLES = {
    "expenses": ("", EXP_DROP), "expense_claims": ("", CLM_DROP),
    "document_types": ("WHERE key <> 'expense_claim'", []),
    "accounts": ("", []), "journal_entries": ("", []), "journal_lines": ("", []), "payments": ("", []),
    "payment_allocations": ("", []), "payment_requests": ("", []), "prepayment_applications": ("", []),
    "fixed_assets": ("", []), "fixed_asset_cost_entries": ("", []), "fixed_asset_depreciation_anchors": ("", []),
    "equipment_maintenance": ("", []), "medical_claims": ("", []), "finance_attachments": ("", []),
    "processing_cost_entries": ("", []), "electricity_allocations": ("", []), "assay_disputes": ("", []),
    "approval_log": ("", []), "permissions": ("", []), "role_permissions": ("", []), "roles": ("", []),
    "user_roles": ("", []), "finance_settings": ("", []), "ingest_settings": ("", []), "cod_issues": ("", []),
    "tax_codes": ("", []), "suppliers": ("", []), "employees": ("", []),
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


# ── 镜像里那几段真的是这个样子 ──────────────────────────────────────────────────
exp = mirror("db/tables/expenses.sql")
GUARD_EXP_MUT = grab(exp, r"CREATE OR REPLACE FUNCTION public\.guard_expense_mutation\(\).*?\$function\$;\n", "guard_expense_mutation")
GUARD_EXP_TOT = grab(exp, r"CREATE OR REPLACE FUNCTION public\.guard_expense_totals\(\).*?\$function\$;\n", "guard_expense_totals")
TRG_EXP_TOT = grab(exp, r"CREATE CONSTRAINT TRIGGER trg_expenses_totals_match\n.*?;\n", "trg_expenses_totals_match")
assert "NEW.account_code " not in GUARD_EXP_MUT
assert "CONSTRAINT expenses_tax_shape CHECK (tax_base >= 0)" in exp
assert "ADD CONSTRAINT expenses_tax_ccy_shape CHECK (tax_ccy >= 0);" in exp
assert "trg_expenses_tax_code_registered\n" not in exp.replace("(trg_expenses_tax_code_registered)", "")
clm = mirror("db/tables/expense_claims.sql")
GUARD_CLM_TOT = grab(clm, r"CREATE OR REPLACE FUNCTION public\.guard_expense_claim_totals\(\).*?\$function\$;\n", "guard_expense_claim_totals")
TRG_CLM_TOT = grab(clm, r"CREATE CONSTRAINT TRIGGER trg_expense_claims_totals_match\n.*?;\n", "trg_expense_claims_totals_match")
LINES_DDL = mirror("db/tables/expense_lines.sql")
ITEMS_DDL = mirror("db/tables/expense_claim_items.sql")
VIEW_DDL = mirror("db/views/expense_claim_status.sql")
assert "item_count" in VIEW_DDL and "no_receipt_reason" not in VIEW_DDL.split("CREATE VIEW", 1)[1]
doc = mirror("db/tables/document_types.sql")
assert "ARRAY['description', 'decision_notes']::text[], ARRAY['module.finance.view']::text[])" in doc
zzz = mirror("db/views/zzz_change_log_triggers.sql")
CL_BIND = ""
for t in ["expense_lines", "expense_claim_items"]:
    CL_BIND += grab(zzz, rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?;\n", t + " row binding")
    CL_BIND += grab(zzz, rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?;\n", t + " truncate binding")
for f in REPLACED_FUNCS + NEW_FUNCS:
    assert (ROOT / f"db/functions/{f}.sql").exists(), f

HEADER = """-- db/migrations/2026-10-20-expense-multiline-1.sql
-- EXPENSE-MULTILINE-1 —— 费用单变成【表头 + 行】,报销单变成【表头 + 明细】。(v1.4.64;发布那一行在 docs/handbacks/EXPENSE-MULTILINE-1.md 的抬头。)
--   由 db/scripts/build_expense_multiline1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-20 的裁定:Step 0 Q1–Q16 · Step 0b Q1–Q10)
--   ① 新表 expense_lines:每一行自己的科目 · 税码 · 净额 · 税 · 备注;不可改、不可删;未注册时写不进税码(GST-2 那道闸随码搬来)。
--      表头 expenses 拿掉 account_code / tax_code / tax_rate_pct;四个合计(amount_ccy · amount_base · tax_ccy · tax_base)留在表头,
--      由 guard_expense_totals(延迟的约束触发器,两张表各一条)强制 = 各行之和、至少一行(Q10)。
--   ② record_expense_document:唯一的写入者,表头 + p_lines;一张分录、一笔应付;资本单恰好一行(Q1,EXPENSE_CAPITAL_SOLE_LINE);
--      代扣一张单一个性质与税率、按净额之和算(Q12);带代扣的单任何一行都不许带 GST(Q2)。record_expense 原签名是它的单行包装(Q11)。
--      冲销是整张单(Q4):镜像单带着原单的行。电费分摊与加工费结算各写一行。
--   ③ 新表 expense_claim_items:报销单的明细(日期 · 金额 · 说明 · 无收据理由;批准时财务逐笔给科目与税码,Step 0b Q1)。
--      表头 expense_claims 拿掉 account_code / tax_code / no_receipt_reason;spend_date = 最晚那一笔、amount_ccy = 明细之和,
--      由 guard_expense_claim_totals 强制。submit_expense_claim_items / decide_expense_claim_items 是新的两支;旧的两支是单笔包装(Q8)。
--      一张单一个币种(Q4);同一个日历月、外币同一天(Q5);驳回整张(Q3)。expense_claim_status 去掉搬走的三列、加 item_count。
--      搜索只读表头的用途(Q7):document_types 的 expense_claim 那一行去掉 no_receipt_reason。
--   ④ 既有的 10 张费用单与 4 张报销单【机械地】各转成一行 / 一笔(Q5 · Step 0b Q9:测试数据,全新重建时消失;
--      docs/known-wrong-until-cutover.md 记着)。分录、付款、资产、定金、附件一行不动 —— 它们指着的表头 id 没变。
--
-- 【不做什么】不碰审批开关、hook、任何账号与角色;不建任何单据;不改任何分录;require_calibrated_since 保持空;
--   按行资本化(停放)· 收据上传(CLAIM-RECEIPTS-1)· 加工费那扇 paid 侧门(只登记)都不在本刀。
--
-- 【破窗】旧应用 + 新库这一窗里坏的(推导):读表头 account_code 的费用清单页与费用详情页、读 expense_claim_status 里
--   no_receipt_reason / account_code / tax_code 的 /finance/claims 与 /me 的报销那一块、GST 首页那一个按 expenses.tax_code 数的格子
--   —— 它们的查询会撞 42703(列不存在)而报错。录入都还走得通:费用表单调 record_expense(签名未变)、/me 提交调
--   submit_expense_claim、批准调 decide_expense_claim(都是包装,签名未变)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变;每一张费用单恰好一行、
--   逐字等于它搬走之前的科目 / 净额 / 税;每一张报销单恰好一笔、逐字等于它的日期 / 金额 / 说明 / 理由 / 科目 / 税码;
--   拿掉搬走的列之后两张表头逐字未变;其余二十几张表逐字未变;本事务写进变更记录的只有两张新表(与 document_types 那一行);
--   清单 ↔ 总账两边未解释仍是 0.00、与迁移之前逐字相同;两张 COD 原样;327 张表;变更记录覆盖零缺口、豁免 9;
--   匿名面与门户面不变;没有一张视图对 anon / authenticated 带写授权;在途单据一张不少、每一张仍有一个决定人。
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
CREATE TEMP TABLE em1_recon_before (j jsonb) ON COMMIT DROP;
DO $pre$
DECLARE
    v_recon jsonb;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'EM1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.expense_lines') IS NOT NULL OR to_regclass('public.expense_claim_items') IS NOT NULL
       OR to_regprocedure('{NEW_SIGS["record_expense_document"]}') IS NOT NULL THEN
        RAISE EXCEPTION 'EM1_PRE|the line tables or the document writer already exist';
    END IF;
    IF (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expenses'
          AND column_name IN ('account_code', 'tax_code', 'tax_rate_pct')) <> 3
       OR (SELECT count(*) FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'expense_claims'
          AND column_name IN ('account_code', 'tax_code', 'no_receipt_reason')) <> 3 THEN
        RAISE EXCEPTION 'EM1_PRE|expected the single-line header columns';
    END IF;
    IF (SELECT count(*) FROM expenses) <> 10 OR (SELECT count(*) FROM expense_claims) <> 4 THEN
        RAISE EXCEPTION 'EM1_PRE|expected 10 expenses and 4 expense claims (Step 0 measurement)';
    END IF;
    IF NOT (SELECT gst_registered FROM finance_settings) AND EXISTS (SELECT 1 FROM expenses WHERE tax_code IS NOT NULL) THEN
        RAISE EXCEPTION 'EM1_PRE|GST is off while coded expenses exist —— the moved tax-code guard would refuse their lines';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ({acct_list})) <> 7
       OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '{TIM}' AND email = 'tim@evoltrya.test') THEN
        RAISE EXCEPTION 'EM1_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 325 THEN
        RAISE EXCEPTION 'EM1_PRE|expected 325 public tables';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'EM1_PRE|expected 9 change-log exclusions';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'EM1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'EM1_PRE|expected the two recorded COD byte strings';
    END IF;
    -- 清单 ↔ 总账此刻两边未解释都是 0.00 —— 以 tim@(cfo)身份【读】,读完即清
    {RECON_READ}
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'EM1_PRE|the list-vs-ledger reconciliation is expected at 0.00 unexplained: %', v_recon;
    END IF;
    INSERT INTO em1_recon_before (j) VALUES (v_recon - 'base_currency');
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE em1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE em1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE em1_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE em1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
-- 搬走之前的那几列,逐行记下 —— 转换之后每一行 / 每一笔都要逐字等于它
CREATE TEMP TABLE em1_expense_cols ON COMMIT DROP AS
SELECT id, account_code, amount_ccy, amount_base, tax_code, tax_rate_pct, tax_ccy, tax_base, created_at, created_by FROM expenses;
CREATE TEMP TABLE em1_claim_cols ON COMMIT DROP AS
SELECT id, spend_date, amount_ccy, description, no_receipt_reason, account_code, tax_code, created_at, created_by FROM expense_claims;
""")

parts.append("\n-- ── 1 · 两支合计守卫(镜像原样:db/tables/expenses.sql · db/tables/expense_claims.sql)──\n")
parts.append(GUARD_EXP_TOT + "\n" + GUARD_CLM_TOT)
parts.append("\n-- ── 2 · 两张新表(建表脚本原样:db/tables/expense_lines.sql · db/tables/expense_claim_items.sql)──\n")
parts.append(LINES_DDL + "\n" + ITEMS_DDL)
parts.append("\n-- 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 同一串字)\n" + CL_BIND)
parts.append("\n-- 表头那一侧的两条合计触发器(镜像原样)\n" + TRG_EXP_TOT + "\n" + TRG_CLM_TOT)

parts.append("""
-- ── 3 · 既有的单据机械地各转成一行 / 一笔(Tim Q5 · Step 0b Q9:测试数据,不为它们多做任何事)──
--   行与明细的合计守卫在提交时逐张核对表头 = 行之和(这一步本身就被它证明)。
INSERT INTO public.expense_lines (expense_id, line_no, account_code, amount_ccy, amount_base,
                                  tax_code, tax_rate_pct, tax_ccy, tax_base, notes, created_at, created_by)
SELECT e.id, 1, e.account_code, e.amount_ccy, e.amount_base, e.tax_code, e.tax_rate_pct, e.tax_ccy, e.tax_base,
       NULL, e.created_at, e.created_by
  FROM public.expenses e;
INSERT INTO public.expense_claim_items (claim_id, line_no, spend_date, amount_ccy, description, no_receipt_reason,
                                        account_code, tax_code, created_at, created_by)
SELECT c.id, 1, c.spend_date, c.amount_ccy, c.description, c.no_receipt_reason, c.account_code, c.tax_code,
       c.created_at, c.created_by
  FROM public.expense_claims c;

-- ── 4 · 表头拿掉搬走的列 ──────────────────────────────────────────────
DROP TRIGGER trg_expenses_tax_code_registered ON public.expenses;
ALTER TABLE public.expenses
    DROP CONSTRAINT expenses_tax_shape,
    DROP CONSTRAINT expenses_tax_ccy_shape,
    DROP COLUMN account_code,
    DROP COLUMN tax_code,
    DROP COLUMN tax_rate_pct;
ALTER TABLE public.expenses ADD CONSTRAINT expenses_tax_shape CHECK (tax_base >= 0);
ALTER TABLE public.expenses ADD CONSTRAINT expenses_tax_ccy_shape CHECK (tax_ccy >= 0);
COMMENT ON COLUMN public.expenses.tax_base IS
    'GST-2:本单的进项税,以【本位币】计。**amount_ccy 始终是不含税的净额** —— 供应商账单上的总额 = 净额 + 税。可抵的(TX/ZP)那一笔税借 1400 进项税;不可抵的(BL)【有税但要不回来】,那笔税借进费用科目本身、且【不带税码】,好让 box5 报的仍然是采购净额。★ EXPENSE-MULTILINE-1:这是【各行 tax_base 之和】(guard_expense_totals 强制),每一行的码与率在 expense_lines。';

DROP VIEW public.expense_claim_status;
ALTER TABLE public.expense_claims
    DROP COLUMN account_code,
    DROP COLUMN tax_code,
    DROP COLUMN no_receipt_reason;
""")
cm = grab(clm, r"COMMENT ON TABLE public\.expense_claims IS\n.*?';\n", "claims table comment")
parts.append(cm)

parts.append("\n-- ── 5 · 表头的不可改守卫(镜像原样:少了 account_code 那一句)──\n" + GUARD_EXP_MUT)
parts.append("\n-- ── 6 · 新函数(镜像原样)──\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 7 · 换掉的函数(镜像原样,同签名)──\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 8 · expense_claim_status 重建(镜像原样)——视图的写授权由 apply_migration.sh 随后重放 zzz_function_grants.sql 的 F16 那一段收回;\n--   本事务里的自证要先看到它收回,所以这里也收一次(同一句话)──\n")
parts.append(VIEW_DDL)
parts.append("REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.expense_claim_status FROM anon, authenticated, PUBLIC;\n")

parts.append("""
-- ── 9 · 搜索只读报销单表头的用途(Step 0b Q7;与 db/tables/document_types.sql 那一行同一个值)──
UPDATE public.document_types SET match_columns = ARRAY['description', 'decision_notes']::text[] WHERE key = 'expense_claim';
""")

grants = "".join(
    f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\nGRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n"
    for sig in NEW_SIGS.values())
grants += "".join(
    f"REVOKE EXECUTE ON FUNCTION public.{sig} FROM PUBLIC, anon;\nGRANT EXECUTE ON FUNCTION public.{sig} TO authenticated, service_role;\n"
    for sig in TRIGGER_FUNCS)
parts.append(f"""
-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
{grants}""")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "em1_pending_decider_check")
assert dec.count("'decide_expense_claim'") == 1
dec = dec.replace("'decide_expense_claim'", "'decide_expense_claim_items'")   # 名册登记的是真正把关的那一支
parts.append("\n-- ── 11 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM em1_rows_before)" for t, (w, d) in DIGEST_TABLES.items())

parts.append(f"""
CREATE TEMP TABLE em1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    v_recon jsonb;
    k       text;
BEGIN
    -- 合计守卫在提交前就跑一遍(它们是延迟的):每一张表头 = 它的行 / 明细之和
    SET CONSTRAINTS ALL IMMEDIATE;
    SET CONSTRAINTS ALL DEFERRED;

    -- ① 审批开关没被碰;七个账号一个都没被停、没有新账号、角色一个没变
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'EM1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM em1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM em1_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'EM1_PROOF|an account or its roles changed';
    END IF;

    -- ② 每一张费用单恰好一行,逐字等于搬走之前;每一张报销单恰好一笔,逐字等于搬走之前
    IF EXISTS (SELECT 1 FROM expenses e WHERE (SELECT count(*) FROM expense_lines l WHERE l.expense_id = e.id) <> 1)
       OR (SELECT count(*) FROM expense_lines) <> 10
       OR EXISTS ((SELECT id, account_code, amount_ccy, amount_base, tax_code, tax_rate_pct, tax_ccy, tax_base, created_at, created_by
                     FROM em1_expense_cols
                   EXCEPT SELECT l.expense_id, l.account_code, l.amount_ccy, l.amount_base, l.tax_code, l.tax_rate_pct,
                                 l.tax_ccy, l.tax_base, l.created_at, l.created_by FROM expense_lines l WHERE l.line_no = 1 AND l.notes IS NULL)) THEN
        RAISE EXCEPTION 'EM1_PROOF|the expense conversion is not one exact line per document';
    END IF;
    IF EXISTS (SELECT 1 FROM expense_claims c WHERE (SELECT count(*) FROM expense_claim_items i WHERE i.claim_id = c.id) <> 1)
       OR (SELECT count(*) FROM expense_claim_items) <> 4
       OR EXISTS ((SELECT id, spend_date, amount_ccy, description, no_receipt_reason, account_code, tax_code, created_at, created_by
                     FROM em1_claim_cols
                   EXCEPT SELECT i.claim_id, i.spend_date, i.amount_ccy, i.description, i.no_receipt_reason, i.account_code,
                                 i.tax_code, i.created_at, i.created_by FROM expense_claim_items i WHERE i.line_no = 1)) THEN
        RAISE EXCEPTION 'EM1_PROOF|the claim conversion is not one exact item per claim';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(两张表头比拿掉搬走的列之后的);变更记录只写了两张新表与 document_types 那一行
    IF EXISTS ((SELECT b.k, b.id FROM em1_pending_before b EXCEPT SELECT a2.k, a2.id FROM em1_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM em1_pending_after a2 EXCEPT SELECT b.k, b.id FROM em1_pending_before b)) THEN
        RAISE EXCEPTION 'EM1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'EM1_PROOF|a pre-existing row changed';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM document_types WHERE key = 'expense_claim'
                    AND match_columns = ARRAY['description', 'decision_notes']::text[]) THEN
        RAISE EXCEPTION 'EM1_PROOF|the expense_claim search columns are not as ruled';
    END IF;
    SELECT COALESCE(string_agg(DISTINCT c.table_name, ', ' ORDER BY c.table_name), '') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM em1_log_before), 0) AND c.txid = txid_current();
    IF v_bad NOT IN ('expense_claim_items, expense_lines', 'document_types, expense_claim_items, expense_lines') THEN
        RAISE EXCEPTION 'EM1_PROOF|this migration wrote change_log rows for: %', v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'EM1_PROOF|require_calibrated_since was set or a COD changed';
    END IF;

    -- ④ 清单 ↔ 总账:两边未解释仍是 0.00,而且与迁移之前逐字相同
    {RECON_READ}
    IF (v_recon - 'base_currency') IS DISTINCT FROM (SELECT j FROM em1_recon_before)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                   WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'EM1_PROOF|the list-vs-ledger reconciliation moved: %', v_recon;
    END IF;

    -- ⑤ 结构:新函数在;旧签名各只有一支;搬走的列不在了;两张新表开着 RLS、anon 一个权限都没有;四条合计触发器是延迟的
    IF to_regprocedure('{NEW_SIGS["record_expense_document"]}') IS NULL
       OR to_regprocedure('{NEW_SIGS["submit_expense_claim_items"]}') IS NULL
       OR to_regprocedure('{NEW_SIGS["decide_expense_claim_items"]}') IS NULL
       OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public'
            AND p.proname IN ('record_expense', 'submit_expense_claim', 'decide_expense_claim', 'record_expense_document',
                              'submit_expense_claim_items', 'decide_expense_claim_items')) <> 6 THEN
        RAISE EXCEPTION 'EM1_PROOF|expected exactly one signature of each writer';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public'
                AND ((table_name = 'expenses' AND column_name IN ('account_code', 'tax_code', 'tax_rate_pct'))
                  OR (table_name = 'expense_claims' AND column_name IN ('account_code', 'tax_code', 'no_receipt_reason')))) THEN
        RAISE EXCEPTION 'EM1_PROOF|a moved column is still on a header';
    END IF;
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.expense_lines'::regclass)
       OR NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.expense_claim_items'::regclass)
       OR has_table_privilege('anon', 'public.expense_lines', 'SELECT') OR has_table_privilege('anon', 'public.expense_claim_items', 'SELECT') THEN
        RAISE EXCEPTION 'EM1_PROOF|the new tables are not closed to anon / not under RLS';
    END IF;
    IF (SELECT count(*) FROM pg_trigger WHERE tgname IN ('trg_expenses_totals_match', 'trg_expense_lines_totals_match',
            'trg_expense_claims_totals_match', 'trg_expense_claim_items_totals_match') AND tgdeferrable AND tginitdeferred) <> 4 THEN
        RAISE EXCEPTION 'EM1_PROOF|the four totals triggers are not all deferred constraint triggers';
    END IF;

    -- ⑥ 327 张表;变更记录覆盖零缺口、豁免 9;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 327 THEN
        RAISE EXCEPTION 'EM1_PROOF|expected 327 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'EM1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'EM1_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'EM1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑦ 匿名面与门户面不变
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'EM1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'EM1_PROOF|supplier_portal executes: %', v_bad;
    END IF;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.em1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'EM1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.em1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'EM1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.em1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
