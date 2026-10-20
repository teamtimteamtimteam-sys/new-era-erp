#!/usr/bin/env python3
"""FIN-CHAIN-1(v1.4.63):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 换掉的函数与新函数原样从 db/functions 抽出,
quotes 的新触发器与十四个新科目原样从表镜像抽出,所以迁移建出来的与门重建出来的是同一串字。照抄 build_mes9c_migration.py 的形状。
跑法:python3 db/scripts/build_fin_chain1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-20-fin-chain-1.sql"

REPLACED_FUNCS = [                                    # 同签名
    # C1 · 六扇出钱的门按名拒明天
    "pay_payroll_lines", "pay_payroll_cpf", "pay_payroll_deductions", "remit_processing_costs",
    "remit_wht_internal", "record_bank_transfer_internal",
    # C3 · 关账按名拒未解释的差
    "close_period",
    # C2 · 管理包的「未解释」改基
    "management_pack_data",
    # B1 · B3 · 作废挂着在册发票的订单按名拒;短装收尾
    "set_sales_order_status",
    # B2 · 订单流的销售不许再开 sale 型发票
    "create_invoice",
]
NEW_FUNCS = ["guard_quote_status_through_function"]   # B4
RESIGNED_FUNCS = {                                    # C6 · 签名变了:先 DROP 旧签名,再按镜像建
    "reverse_freight_document": "public.reverse_freight_document(uuid, text)",
}
NEW_SIG = "public.reverse_freight_document(uuid, text, date)"
NEW_CODES = ["2600", "6010", "6130", "6140", "6210", "6220", "6230", "6240", "6250", "6310", "6410", "6420", "6510", "6520"]
REAL_ACCOUNTS = ["admin@swm-os.test", "chooer@evoltrya.test", "fusheng@evoltrya.test", "phua@evolytra.test",
                 "sandra@evoltrya.test", "tim@evoltrya.test", "vince@evoltrya.test"]
TIM = "634c00f9-c3a9-4444-9eed-b624cb6a2a93"          # tim@evoltrya.test(cfo:module.finance.view + 两个价格码)—— 只拿来【读】勾稽
codes_sql = ", ".join(f"'{c}'" for c in NEW_CODES)

# 前后比对的表(既有的行逐字未变;accounts 只比既有的行)
DIGEST_TABLES = {
    "accounts": (f"WHERE code NOT IN ({codes_sql})", []),
    "quotes": ("", []), "sales_orders": ("", []), "sales_order_lines": ("", []), "sales_order_reservations": ("", []),
    "sales_records": ("", []), "invoices": ("", []), "invoice_lines": ("", []), "credit_notes": ("", []),
    "freight_documents": ("", []), "management_packs": ("", []), "period_closes": ("", []),
    "payroll_periods": ("", []), "payroll_lines": ("", []), "wht_remittances": ("", []), "bank_transfers": ("", []),
    "journal_entries": ("", []), "journal_lines": ("", []), "payments": ("", []), "expenses": ("", []),
    "approval_log": ("", []), "permissions": ("", []), "role_permissions": ("", []), "roles": ("", []),
    "user_roles": ("", []), "finance_settings": ("", []), "ingest_settings": ("", []), "cod_issues": ("", []),
    "list_ledger_residue": ("", []),
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


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
quotes = mirror("db/tables/quotes.sql")
m = re.search(r"CREATE TRIGGER trg_quotes_status_through_function\n.*?;\n", quotes, re.S)
assert m, "quotes trigger in mirror"
QUOTE_TRIGGER = m.group(0)
acct = mirror("db/tables/accounts.sql")
m = re.search(r"INSERT INTO public\.accounts \(code, name_en, name_zh, account_type, is_system, is_monetary\) VALUES\n    \('2600'.*?;\n", acct, re.S)
assert m, "the fourteen accounts in the mirror"
ACCT_INSERT = m.group(0)
assert all(f"('{c}'," in ACCT_INSERT for c in NEW_CODES) and ACCT_INSERT.count("\n    (") == 14
assert "('3000','3100','2600')" in acct
for f in REPLACED_FUNCS + NEW_FUNCS + list(RESIGNED_FUNCS):
    assert (ROOT / f"db/functions/{f}.sql").exists(), f
assert "p_reversal_date date DEFAULT NULL::date" in mirror("db/functions/reverse_freight_document.sql")

HEADER = """-- db/migrations/2026-10-20-fin-chain-1.sql
-- FIN-CHAIN-1 —— 销售链与财务链的几处正确性,科目表增补十四个科目。(v1.4.63;发布那一行在 docs/handbacks/FIN-CHAIN-1.md 的抬头。)
--   由 db/scripts/build_fin_chain1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-20 的裁定:委托书 A–E 与 Step 0 Q1–Q13)
--   A1 · A2  十四个非系统科目:2600 应付借款(负债 · 货币性 · 筹资段)+ 十三个费用科目(非货币性)。只插新行,既有的科目一行不动。
--   B1  set_sales_order_status:作废一张挂着在册订单流发票的订单 → SO_CANCEL_HAS_LIVE_INVOICE|订单|发票(先提发票作废申请)。
--   B2  create_invoice:订单流的销售(sales_order_line_id 非空)→ SALE_IS_ORDER_FLOW|批次(它已经在订单发票上了)。
--   B3  set_sales_order_status:partially_shipped → closed 的显式短装收尾 —— 理由必填(SO_CLOSE_REASON_REQUIRED);
--       开了票、没发、也没被贷项取消的数量 → SO_CLOSE_INVOICED_UNSHIPPED|订单|行|数量;剩下的预留释放;写一行历史。
--   B4  quotes 新增行级守卫 trg_quotes_status_through_function:直连改 status / converted_order_id / decline_reason
--       (或直连插一行不是 draft 的)→ QT_STATUS_THROUGH_FUNCTION_ONLY;属主路径(三支 SECURITY DEFINER 函数)放行。
--   C1  六扇出钱的门(pay_payroll_lines · pay_payroll_cpf · pay_payroll_deductions · remit_processing_costs ·
--       remit_wht_internal · record_bank_transfer_internal)日期晚于今天 → DOCUMENT_DATE_IN_FUTURE|<种类>|日期|今天。
--   C2  management_pack_data:应收 / 应付的「未解释」改由 list_ledger_reconciliation 答(连同读它的时刻存进包);
--       旧的按机制分解原样保留。已冻结的包一行不动。
--   C3  close_period:清单 ↔ 总账任何一边未解释 ≠ 0 → CLOSE_LEDGER_LIST_UNEXPLAINED|边|金额;答不上来 → CLOSE_RECON_UNANSWERABLE。
--   C6  reverse_freight_document 多一个参数 p_reversal_date(必填 → REVERSAL_DATE_REQUIRED;不早于原分录;不默认)。
--       签名变了,所以先 DROP 旧签名(函数权限由 apply_migration.sh 随后整份重放 zzz_function_grants.sql 恢复)。
--
-- 【不做什么】不碰审批开关、hook、任何账号与角色;不改任何既有的行;不回填;不建任何单据;require_calibrated_since 保持空;
--   C4(结算过账)与 C5(薪资付款冲销)不在本刀(Tim Q1 · Q6)。
--
-- 【破窗】旧应用 + 新库这一窗里坏的只有一件:运费单详情页的「冲销」不传日期,会读到 REVERSAL_DATE_REQUIRED(按名拒,
--   不写任何东西)。其余全是收紧:旧页面上原来能做、现在被按名拒的动作(作废挂票的订单、给订单流销售开 sale 票、
--   明天的出钱日期、带未解释差额关账)—— 线上此刻这几种情形一张都没有(勾稽两边未解释 0.00,文末断言)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;七个账号一个都没被停、角色一个没变;十四个科目逐字是 Tim 定的那样,
--   2600 不在费用单的下拉里(account_type ≠ expense);既有的科目与单据行逐字未变;本事务写进变更记录的只有那十四行新科目;
--   在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;清单 ↔ 总账两边未解释仍是 0.00、与迁移之前逐字相同;
--   两张 COD 原样;变更记录覆盖零缺口、豁免 9;325 张表;匿名面与门户面不变;没有一张视图对 anon / authenticated 带写授权。
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
CREATE TEMP TABLE finchain1_recon_before (j jsonb) ON COMMIT DROP;
DO $pre$
DECLARE
    v_recon jsonb;
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM accounts WHERE code IN ({codes_sql})) THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|one of the fourteen account codes already exists';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM accounts WHERE code = '3000' AND name_en = 'Share Capital')
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '6300' AND name_en = 'Transport & Logistics')
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '6900' AND name_en = 'Miscellaneous') THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|3000 / 6300 / 6900 are expected with their current names';
    END IF;
    IF to_regprocedure('{RESIGNED_FUNCS["reverse_freight_document"]}') IS NULL OR to_regprocedure('{NEW_SIG}') IS NOT NULL
       OR to_regprocedure('public.guard_quote_status_through_function()') IS NOT NULL
       OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_quotes_status_through_function') THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected the two-argument reverse_freight_document and no quote status guard yet';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7
       OR (SELECT count(*) FROM auth.users WHERE email IN ({acct_list})) <> 7
       OR NOT EXISTS (SELECT 1 FROM auth.users WHERE id = '{TIM}' AND email = 'tim@evoltrya.test') THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected the 7 real accounts';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 325 THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected 325 public tables';
    END IF;
    IF (change_log_coverage_gaps() ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected 9 change-log exclusions';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|require_calibrated_since must be empty';
    END IF;
    IF (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|expected the two recorded COD byte strings';
    END IF;
    -- 清单 ↔ 总账此刻两边未解释都是 0.00(委托书:勾稽保持 0.00)—— 以 tim@(cfo)身份【读】,读完即清
    {RECON_READ}
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'FINCHAIN1_PRE|the list-vs-ledger reconciliation is expected at 0.00 unexplained: %', v_recon;
    END IF;
    INSERT INTO finchain1_recon_before (j) VALUES (v_recon - 'base_currency');
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w, d)} AS {t}" for t, (w, d) in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE finchain1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE finchain1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE finchain1_accounts_before ON COMMIT DROP AS
SELECT u.id, u.email, u.banned_until,
       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL) AS roles
  FROM auth.users u;
CREATE TEMP TABLE finchain1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · A1 · A2:十四个非系统科目(镜像原样;2600 的筹资段与镜像里那句 UPDATE 同一个值)──\n")
parts.append(ACCT_INSERT)
parts.append("UPDATE public.accounts SET cash_flow_section = 'financing' WHERE code = '2600';\n")
parts.append("\n-- ── 2 · 换掉的函数(镜像原样,同签名)──\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 3 · B4:新守卫(镜像原样)与它的触发器(与 db/tables/quotes.sql 同一串字)──\n")
for f in NEW_FUNCS:
    parts.append(fn(f))
parts.append("\n" + QUOTE_TRIGGER)
parts.append("\n-- ── 4 · C6:reverse_freight_document 多一个参数 —— 签名变了,先 DROP 旧签名,再按镜像建 ──\n")
for f, old in RESIGNED_FUNCS.items():
    parts.append(f"\nDROP FUNCTION {old};\n")
    parts.append(fn(f))
parts.append(f"""
-- ── 5 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION {NEW_SIG} FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION {NEW_SIG} TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_quote_status_through_function() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_quote_status_through_function() TO authenticated, service_role;
""")

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "finchain1_pending_decider_check")
parts.append("\n-- ── 6 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

digest_checks = "\n       OR ".join(
    f"{digest(t, w, d)} IS DISTINCT FROM (SELECT {t} FROM finchain1_rows_before)" for t, (w, d) in DIGEST_TABLES.items())

parts.append(f"""
CREATE TEMP TABLE finchain1_pending_after ON COMMIT DROP AS
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
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'FINCHAIN1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u
                EXCEPT SELECT id, email, banned_until, roles FROM finchain1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until, roles FROM finchain1_accounts_before
                EXCEPT SELECT u.id, u.email, u.banned_until,
                       (SELECT string_agg(r.code, ',' ORDER BY r.code) FROM user_roles ur JOIN roles r ON r.id = ur.role_id
                         WHERE ur.user_id = u.id AND ur.revoked_at IS NULL)
                  FROM auth.users u)) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|an account or its roles changed';
    END IF;

    -- ② 十四个科目逐字是 Tim 定的那样:非系统、启用;2600 负债 · 货币性 · 筹资;十三个费用非货币性;2600 不在费用单下拉的集合里
    IF (SELECT count(*) FROM accounts WHERE code IN ({codes_sql}) AND NOT is_system AND is_active) <> 14
       OR NOT EXISTS (SELECT 1 FROM accounts WHERE code = '2600' AND name_en = 'Loan Payable' AND name_zh = '应付借款'
                       AND account_type = 'liability' AND is_monetary AND cash_flow_section = 'financing' AND NOT is_cash)
       OR (SELECT count(*) FROM accounts WHERE code IN ({codes_sql}) AND code <> '2600' AND account_type = 'expense'
            AND NOT is_monetary AND NOT is_cash AND cash_flow_section IS NULL) <> 13
       OR EXISTS (SELECT 1 FROM accounts WHERE code = '2600' AND account_type = 'expense') THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|the fourteen accounts are not as ruled';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变;本事务写进变更记录的只有那十四行新科目
    IF EXISTS ((SELECT b.k, b.id FROM finchain1_pending_before b EXCEPT SELECT a2.k, a2.id FROM finchain1_pending_after a2)
               UNION ALL
               (SELECT a2.k, a2.id FROM finchain1_pending_after a2 EXCEPT SELECT b.k, b.id FROM finchain1_pending_before b)) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|a pre-existing row changed';
    END IF;
    SELECT COALESCE(string_agg(DISTINCT c.table_name, ', '), '') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM finchain1_log_before), 0) AND c.txid = txid_current();
    IF v_bad NOT IN ('', 'accounts') THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|this migration wrote change_log rows for: %', v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL OR (SELECT count(*) FROM cod_issues) <> 2 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|require_calibrated_since was set or a COD changed';
    END IF;

    -- ④ 清单 ↔ 总账:两边未解释仍是 0.00,而且与迁移之前逐字相同
    {RECON_READ}
    IF (v_recon - 'base_currency') IS DISTINCT FROM (SELECT j FROM finchain1_recon_before)
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_recon -> 'sides') s
                   WHERE s ->> 'refusal' IS NOT NULL OR (s ->> 'unexplained_base')::numeric <> 0) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|the list-vs-ledger reconciliation moved: %', v_recon;
    END IF;

    -- ⑤ 函数与守卫:旧的两参运费冲销不在了,新的三参在;守卫是 INVOKER、触发器挂在 quotes 上
    IF to_regprocedure('{RESIGNED_FUNCS["reverse_freight_document"]}') IS NOT NULL OR to_regprocedure('{NEW_SIG}') IS NULL
       OR (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname = 'reverse_freight_document') <> 1 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|reverse_freight_document: expected exactly the three-argument signature';
    END IF;
    IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.guard_quote_status_through_function()'::regprocedure)
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_quotes_status_through_function'
                       AND tgrelid = 'public.quotes'::regclass AND NOT tgisinternal) THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|the quote status guard is not in place as an invoker trigger';
    END IF;

    -- ⑥ 结构:325 张表;变更记录覆盖零缺口、豁免 9;遮蔽零缺口;F16 仍是 0
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 325 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|expected 325 public tables';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 9 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|mask gaps: %', v_j -> 'gaps';
    END IF;
    v_n := {VIEW_WRITE_SQL};
    IF v_n <> 0 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|F16: % (view, role) pairs carry a write grant', v_n;
    END IF;

    -- ⑦ 匿名面与门户面不变
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT COALESCE(string_agg(p.proname, ', ' ORDER BY p.proname), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND has_function_privilege('supplier_portal', p.oid, 'EXECUTE');
    IF v_bad <> 'portal_can_read_object, portal_can_upload_object, portal_certificates, portal_deliveries, portal_document_open, portal_documents, portal_export_my_data, portal_me, portal_submission_abandon, portal_submission_begin, portal_submission_finish' THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|supplier_portal executes: %', v_bad;
    END IF;

    -- ⑧ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.finchain1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'FINCHAIN1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.finchain1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'FINCHAIN1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.finchain1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
