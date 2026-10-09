#!/usr/bin/env python3
"""MES-5b-2(v1.4.46):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新视图、新函数与换掉的函数 / 视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有对象上的结构改动(拿掉 run_id 的唯一约束、加一支触发器、换一支表镜像里的守卫函数)
在这里逐句写出,并先断言镜像里那几行真的是这个样子。照抄 build_mes5a2_migration.py / build_mes5b1_migration.py 的形状。
跑法:python3 db/scripts/build_mes5b2_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-09-mes5b2-reversals.sql"

NEW_TABLES = ["electricity_allocation_reversals"]
NEW_VIEWS = ["electricity_allocation_reversals_masked"]
NEW_FUNCS = ["guard_electricity_line_one_live_allocation", "reverse_expense_internal", "reverse_electricity_allocation"]
REPLACED_FUNCS = ["reverse_expense", "electricity_allocation_compute", "post_electricity_allocation", "relieve_processing_accruals",
                  "remit_processing_costs", "trail_subjects", "trail_subject_members", "change_log_mask_rules"]
REPLACED_VIEWS = ["processing_cost_variance", "processing_run_energy", "processing_cost_entry_lookup"]

STAFF_SIGS = ["public.reverse_electricity_allocation(uuid, text)"]
INTERNAL_SIGS = ["public.reverse_expense_internal(uuid, text)", "public.guard_electricity_line_one_live_allocation()"]

DIGEST_TABLES = ["processing_runs", "processing_cost_entries", "processing_cost_entry_history", "expenses", "journal_entries",
                 "journal_lines", "payments", "payment_allocations", "prepayment_applications", "devices", "fixed_assets",
                 "fixed_asset_cost_entries", "electricity_allocations", "electricity_allocation_lines", "operation_type_output_forms"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def view(name, replace):
    body = (ROOT / f"db/views/{name}.sql").read_text().rstrip("\n") + "\n"
    if replace:
        assert "CREATE VIEW public." in body, name
        body = body.replace("CREATE VIEW public.", "CREATE OR REPLACE VIEW public.", 1)
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


def digest(t):
    return f"(SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM {t} t) AS {t}"


HEADER = """-- db/migrations/2026-10-09-mes5b2-reversals.sql
-- MES-5b-2 —— 撤回:一张电费单整张撤回、冲掉一张月结冲抵把估计放回去、经付款结过的费用单先冲付款、结算戳只经财务函数改
--   (MES 组的第十刀,v1.4.46;发布那一行在 docs/handbacks/MES-5b-2.md 的抬头)。
-- 由 db/scripts/build_mes5b2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-09:MES-5b Step 0 的撤回那一部分 —— Q21–Q29 与 Q1 · Q32 · Q34–Q36 的撤回部分 —— 全部照推荐裁定;
--   并入 MES5B1-V37-NOT-ON-OPERATION-TRAIL;docs/surveys/MES-5b/STEP0-HANDBACK.md §14 E)
--   ① F2(Q21):reverse_expense 冲掉一张月结冲抵时,同一笔事务清掉它冲抵过的估计上的戳(不过分录 —— 冲掉的那张分录已经还回 2200);
--      那一炉此后被一张没撤回的电费分摊覆盖了就按名拒 RELIEF_ESTIMATE_NOW_ALLOCATED;processing_cost_variance 不再算冲销过的冲抵;
--      relieve_processing_accruals 的 'SGD', 1 换成从数据读的本位币。
--   ② F1(Q22):reverse_electricity_allocation(module.finance.edit,理由必填)—— 一笔事务、一个冲销日:冲费用单与分录
--      (reverse_expense_internal,与 reverse_expense 同一段);每一炉的实际电费行清戳再软删;被冲掉的估计清戳、取消软删、明写重新计提;
--      一行 electricity_allocation_reversals(金额遮蔽:列 + 列级授权 + _masked 视图 + 遮蔽规则,一支迁移)。
--   ③ Q23:electricity_allocation_lines.run_id 的唯一约束换成"一炉最多在一张没撤回的分摊里"的守卫;compute 的"已分过"与"重叠"不认撤回过的。
--   ④ Q24:经付款结过的费用单(每一种)按名拒 EXPENSE_HAS_SETTLEMENT,先冲付款;冲抵过预付款的按名拒 EXPENSE_HAS_PREPAYMENT_APPLIED。
--   ⑤ Q26:结算戳(remitted_* / relieved_* 四列)只许经五支财务函数改 —— guard_cost_entry_settled 认事务级标记,插入那一半也一样;
--      COST_ENTRY_SETTLEMENT_THROUGH_FUNCTION_ONLY。
--   ⑥ Q28:post_electricity_allocation 也要 module.finance.view。
--   ⑦ Q32 · 并入:审计记录 —— 撤回住在那张电费单下、也出现在它覆盖过的每一炉上;V37(operation_type_output_forms)挂到工序下。
--      变更记录绑一张新表;遮蔽规则 +3。processing_run_energy 只读没撤回的那一张分摊的那一行。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改、不冲任何一张既有单据、费用单、
--   付款、成本行、分录、加工单或设备;不过任何账单、不撤任何分摊;require_calibrated_since 保持空。不播任何行。
--
-- 【破窗】见 docs/surveys/MES-5b/STEP0-HANDBACK.md §11:旧应用调的函数都没改签名。旧的费用单页上冲销一张冲抵,从此也把估计放回去(更好,不坏);
--   冲销一张经付款结过的费用单从此按名拒(新);一次直连改结算戳从此按名拒(旧应用不发这种请求);旧的电费页没有撤回钮(线上 0 次分摊)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;
--   七个账号一个都没被停;既有的加工单、成本行与它的修改史、费用单、分录、付款与核销、预付款冲抵、设备、资产、分摊逐字未变;
--   变更记录一行都没动;新表是空的;run_id 不再唯一而守卫在;'SGD' 字面量不在了;anon 能执行的【恰好】两支;内层谁都调不到;
--   金额不在列级授权里;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免仍是 8、规则 114 条);提醒臂 59、待补的值 20 不变。
--   断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))

# 遮蔽表的列级授权与 _masked 视图都在镜像里(三件事一支迁移)
must("db/tables/electricity_allocation_reversals.sql", "REVOKE SELECT ON public.electricity_allocation_reversals FROM authenticated, anon;")
# 分摊行:镜像里 run_id 已经不唯一,索引与守卫触发器在
LINES = mirror("db/tables/electricity_allocation_lines.sql")
assert "    run_id          uuid NOT NULL REFERENCES public.processing_runs (id),\n" in LINES
LINE_INDEX = must("db/tables/electricity_allocation_lines.sql",
                  "CREATE INDEX electricity_allocation_lines_run_id_rel ON public.electricity_allocation_lines (run_id);\n")
LINE_TRIGGER = must("db/tables/electricity_allocation_lines.sql", """CREATE TRIGGER trg_electricity_allocation_lines_one_live
    BEFORE INSERT ON public.electricity_allocation_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_electricity_line_one_live_allocation();
""")
LINE_COMMENT = re.search(r"COMMENT ON TABLE public\.electricity_allocation_lines IS\n    '.*?';\n", LINES, re.S).group(0)
# 成本行:表镜像里那支守卫函数与插入那一半的触发器,原样抽出
PCE = mirror("db/tables/processing_cost_entries.sql")
GUARD = PCE[PCE.index("CREATE OR REPLACE FUNCTION public.guard_cost_entry_settled()"):PCE.index("$fn$;\n", PCE.index("CREATE OR REPLACE FUNCTION public.guard_cost_entry_settled()")) + 6]
INS_TRIGGER = must("db/tables/processing_cost_entries.sql", """CREATE TRIGGER trg_processing_cost_entries_settlement_insert_guard
    BEFORE INSERT ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION public.guard_cost_entry_settled();
""")
assert "'SGD', 1" not in mirror("db/functions/relieve_processing_accruals.sql")

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5B2_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.electricity_allocation_reversals') IS NOT NULL OR to_regprocedure('public.reverse_electricity_allocation(uuid, text)') IS NOT NULL
       OR to_regprocedure('public.reverse_expense_internal(uuid, text)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B2_PRE|MES-5b-2 objects already exist';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'electricity_allocation_lines_run_id_key' AND contype = 'u'
                     AND conrelid = 'public.electricity_allocation_lines'::regclass) THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected the unique constraint electricity_allocation_lines_run_id_key';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.relieve_processing_accruals(uuid[], numeric, date, text, text, uuid, text, text)'::regprocedure)
         NOT LIKE '%''SGD'', 1%' THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected the SGD literal in relieve_processing_accruals (MES5A2-RELIEVE-SGD-LITERAL)';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 111 THEN
        RAISE EXCEPTION 'MES5B2_PRE|expected 111 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5B2_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B2_PRE|pending_values should have 20 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B2_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5b2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes5b2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5b2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5b2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5b2_rows_before ON COMMIT DROP AS
SELECT {(',' + chr(10) + '       ').join(digest(t) for t in DIGEST_TABLES)};
""")

parts.append("\n-- ── 1 · 新表(镜像原样):一张电费单的撤回 ─────────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))
parts.append("\n-- ── 2 · 新视图(镜像原样):撤回的遮蔽伴生 ──────────────────────────────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v, False))
parts.append("\n-- ── 3 · 新函数(镜像原样):分摊行的守卫 · 冲一张费用单的那一段 · 撤回一张电费单 ─────────────────────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))

parts.append(f"""
-- ── 4 · 分摊行:run_id 的唯一约束换成"一炉最多在一张没撤回的分摊里"(Q23)—— 索引与触发器与 db/tables/electricity_allocation_lines.sql 逐字同一份 ──
ALTER TABLE public.electricity_allocation_lines DROP CONSTRAINT electricity_allocation_lines_run_id_key;
{LINE_INDEX}{LINE_TRIGGER}{LINE_COMMENT}""")

parts.append(f"""
-- ── 5 · 成本行:结算戳只许经财务函数改(Q26)—— 守卫函数与插入那一半的触发器,与 db/tables/processing_cost_entries.sql 逐字同一份 ──
{GUARD}

{INS_TRIGGER}""")

parts.append("\n-- ── 6 · 换掉的函数(镜像原样,同签名)────────────────────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 7 · 换掉的视图(镜像原样):冲销过的冲抵不再算偏差 · 一炉的电只读没撤回的那一张 ──────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, True))

parts.append("\n-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 9 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in STAFF_SIGS + INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes5b2_pending_decider_check")
parts.append("\n-- ── 10 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

staff_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|{sig}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for sig in STAFF_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(
    f"(SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM {t} t) IS DISTINCT FROM (SELECT {t} FROM mes5b2_rows_before)"
    for t in DIGEST_TABLES)
rel_list = ", ".join(f"'{r}'" for r in NEW_TABLES + NEW_VIEWS)

parts.append(f"""
CREATE TEMP TABLE mes5b2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行都没动(本刀不加码、不改授权)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5b2_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes5b2_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B2_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5B2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5b2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5b2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5B2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes5b2_pending_before b EXCEPT SELECT a.k, a.id FROM mes5b2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5b2_pending_after a EXCEPT SELECT b.k, b.id FROM mes5b2_pending_before b)) THEN
        RAISE EXCEPTION 'MES5B2_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES5B2_PROOF|a pre-existing run, cost line, expense, journal, payment, allocation, device, asset or output form changed';
    END IF;

    -- ④ 变更记录一行都没动(本刀不写任何数据);新表是空的,线上仍然一次分摊都没有
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5b2_log_before), 0)) <> 0 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|change_log moved (%)', (SELECT string_agg(DISTINCT c.table_name, ', ') FROM change_log c
                                                                WHERE c.seq > COALESCE((SELECT mx FROM mes5b2_log_before), 0));
    END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocation_reversals) OR EXISTS (SELECT 1 FROM electricity_allocations) THEN
        RAISE EXCEPTION 'MES5B2_PROOF|reversals or allocations exist';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑤ 结构:run_id 不再唯一,守卫与索引在;成本行两支守卫触发器在;'SGD' 字面量不在了
    IF EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'electricity_allocation_lines_run_id_key')
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_electricity_allocation_lines_one_live')
       OR to_regclass('public.electricity_allocation_lines_run_id_rel') IS NULL THEN
        RAISE EXCEPTION 'MES5B2_PROOF|run_id should no longer be unique, with the one-live guard and the index in place';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_processing_cost_entries_settlement_insert_guard')
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_processing_cost_entries_settled_guard') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|the cost-entry settlement guards are missing';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.relieve_processing_accruals(uuid[], numeric, date, text, text, uuid, text, text)'::regprocedure)
         LIKE '%''SGD'', 1%' THEN
        RAISE EXCEPTION 'MES5B2_PROOF|the SGD literal is still in relieve_processing_accruals';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;撤回那一支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5B2_PROOF|anon executes: %', v_bad;
    END IF;
{staff_checks}
{internal_checks}
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({rel_list})
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B2_PROOF|anon can read %', v_bad; END IF;
    IF has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'bill_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'actual_line_amount', 'SELECT')
       OR has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'restored_estimate_amount', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.electricity_allocation_reversals'::regclass, 'reason', 'SELECT') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|the reversal amounts must be out of the column grant and the reason in it';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ({", ".join(f"'{t}'" for t in NEW_TABLES)}) AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES5B2_PROOF|a write policy exists on the reversals table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(新表记,豁免仍是 8);遮蔽零缺口(111 → 114 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 59、待补的值 20 不变
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|reminder arms 59 / pending-value arms 20 changed';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5b2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5B2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5b2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5B2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5b2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
