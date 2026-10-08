#!/usr/bin/env python3
"""MES-5b-1(v1.4.45):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新视图、换掉的函数与视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。两列新列、目录的声明块、拆分工序的容差 0 在这里逐句写出或从镜像原样抽出,
并先断言镜像里那几行真的是这个样子。照抄 build_mes5a2_migration.py 的形状。
跑法:python3 db/scripts/build_mes5b1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-08-mes5b1-balance-and-yield.sql"

# 依赖顺序:先基视图(flow → 月度 / 滚动 / 树 → 得率 → 份额 → 分组),后带门的外壳
NEW_VIEWS = ["processing_run_flow_all", "processing_balance_monthly_all", "stock_rollforward_monthly_all", "batch_balance_tree_all",
             "processing_run_yield_all", "processing_run_origin_share_all", "processing_yield_summary_all",
             "processing_balance_monthly", "stock_rollforward_monthly", "batch_balance_tree", "processing_run_yield", "processing_yield_summary"]
BASE_VIEWS = [v for v in NEW_VIEWS if v.endswith("_all")]
READERS = [v for v in NEW_VIEWS if not v.endswith("_all")]
REPLACED_FUNCS = ["set_role_permissions", "split_failed_modules_to_quarantine"]
REPLACED_VIEWS = ["pending_values"]


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


def between(path, start, end_marker):
    s = mirror(path)
    i = s.index(start)
    j = s.index(end_marker, i) + len(end_marker)
    return s[i:j]


# 目录:新列的定义与注释、声明块、目录自己的自检 —— 全部原样取自 db/tables/permissions.sql
must("db/tables/permissions.sql", "    requires_view_any text[]\n);")
PERM_COMMENT = between("db/tables/permissions.sql", "COMMENT ON COLUMN public.permissions.requires_view_any IS", "';\n")
PERM_DECL = between("db/tables/permissions.sql", "UPDATE public.permissions p SET requires_view_any = d.views", " WHERE p.code = d.code;\n")
PERM_CHECK = between("db/tables/permissions.sql", "DO $requires_view_check$", "$requires_view_check$;\n")
# V37:新列与注释原样取自 db/tables/operation_type_output_forms.sql
V37_COL = "    expected_yield_pct  numeric CHECK (expected_yield_pct IS NULL OR (expected_yield_pct >= 0 AND expected_yield_pct <= 100))\n"
must("db/tables/operation_type_output_forms.sql", V37_COL)
V37_COMMENT = between("db/tables/operation_type_output_forms.sql", "COMMENT ON COLUMN public.operation_type_output_forms.expected_yield_pct IS", "';\n")
# 拆分工序的容差 0:镜像里就是这一句
TOL = must("db/tables/operation_types.sql", "UPDATE public.operation_types SET balance_tolerance_pct = 0 WHERE code = 'discharge_quarantine_split';")

HEADER = """-- db/migrations/2026-10-08-mes5b1-balance-and-yield.sql
-- MES-5b-1 —— 物料平衡与得率、"动作码蕴含查看码"的检查、引导的 admin(MES 组第九刀,v1.4.45;发布那一行在 docs/handbacks/MES-5b-1.md 的抬头)。
-- 由 db/scripts/build_mes5b1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-08:MES-5b Step 0 的平衡 / 得率 / f 检查那一部分 —— Q1 · Q3–Q14 · Q30 · Q32–Q37 —— 照建议裁定,
--   Q15 加 V37,Q31 修引导;docs/surveys/MES-5b/STEP0-HANDBACK.md)
--   ① 一炉在质量账上算哪一类(processing_run_flow_all):消耗 / 穿过去(深度放电)/ 搬运(拆去隔离)/ 回滚;单位不全是 kg 的单不合计(Q3 · Q10)。
--   ② 月度物料平衡(processing_balance_monthly_all + 外壳)与库存的月度滚动(stock_rollforward_monthly_all + 外壳)(Q8 · Q9)。
--   ③ 一个批次往下走的质量树,按投入质量成比例、精确的份额(batch_balance_tree_all + 外壳)(Q4 · Q5 · Q6 · Q7)。
--   ④ 质量得率:每一炉(processing_run_yield_all + 外壳)、按工序 × 月 × 分组(processing_run_origin_share_all · processing_yield_summary_all + 外壳)(Q13 · Q14)。
--   ⑤ V37:operation_type_output_forms.expected_yield_pct(空)+ pending_values 一支(Q15 · Q33)。
--   ⑥ 拆去隔离那一炉自己结平(split_failed_modules_to_quarantine,同签名)+ 这道工序的容差播成 0(Q11)。
--   ⑦ f 检查:permissions.requires_view_any(声明块 + 目录自检)+ set_role_permissions 按名拒 ACTION_REQUIRES_VIEW(Q30)。
--      引导的 admin 与财务(Q31)只在镜像里改 —— 那是全新安装的起点,线上的角色本刀【一个都不动】。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据、加工单、批次、
--   流水或分录;不回填任何东西;V37 保持空;require_calibrated_since 保持空。线上只多出:两列新列(一列空、一列是 33 个动作码的声明)、
--   拆分工序的容差 0、十二张视图、换掉的两支函数与一张视图。
--
-- 【破窗】见 docs/surveys/MES-5b/STEP0-HANDBACK.md §11:只加视图;拆分那一炉从此自己结平(旧应用不受影响);旧应用存一个违反新规矩的角色
--   会被按名拒(ACTION_REQUIRES_VIEW,旧应用画成一句兜底话)—— 线上七个角色今天全部满足(文末断言)。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   既有的加工单、投料与产出腿、损耗、结平、批次、流水、分录、费用单、设备与安全状态逐字未变;变更记录只在 permissions(33 行声明)
--   与 operation_types(1 行容差)上动了;线上每一个角色都满足"动作码蕴含查看码";V37 没有一个值;anon 能执行的【恰好】两支;
--   基视图谁都读不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免仍是 8、规则 111 条);提醒臂 59 支不变;
--   待补的值 20 支(V37 今天零行 —— 线上没有一张 MES-4a 之后的单);每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

DIGEST_TABLES = ["processing_runs", "processing_inputs", "processing_outputs", "processing_run_losses", "processing_run_closures",
                 "inbound_batches", "output_batches", "inventory_movements", "journal_entries", "journal_lines", "expenses", "payments",
                 "devices", "inbound_batch_safety_states", "output_batch_safety_states", "processing_cost_entries", "discharge_module_splits",
                 "operation_type_output_forms"]


def digest(t):
    return f"(SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM {t} t) AS {t}"


parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5B1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.processing_run_flow_all') IS NOT NULL OR to_regclass('public.batch_balance_tree_all') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PRE|MES-5b-1 views already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'permissions' AND column_name = 'requires_view_any')
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'operation_type_output_forms' AND column_name = 'expected_yield_pct') THEN
        RAISE EXCEPTION 'MES5B1_PRE|a MES-5b-1 column already exists';
    END IF;
    IF (SELECT balance_tolerance_pct FROM operation_types WHERE code = 'discharge_quarantine_split') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PRE|the split operation''s tolerance is expected empty';
    END IF;
    IF (SELECT count(*) FROM permissions WHERE category = 'action') <> 34 THEN
        RAISE EXCEPTION 'MES5B1_PRE|expected 34 action codes, got %', (SELECT count(*) FROM permissions WHERE category = 'action');
    END IF;
    IF (SELECT count(*) FROM auth.users) <> 7 THEN
        RAISE EXCEPTION 'MES5B1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 111 THEN
        RAISE EXCEPTION 'MES5B1_PRE|expected 111 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5B1_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 19 THEN
        RAISE EXCEPTION 'MES5B1_PRE|pending_values should have 19 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5b1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes5b1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5b1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5b1_ops_before ON COMMIT DROP AS
SELECT md5(string_agg((to_jsonb(o) - 'balance_tolerance_pct')::text || '|' || CASE WHEN o.code = 'discharge_quarantine_split' THEN '' ELSE COALESCE(o.balance_tolerance_pct::text, '') END, '|' ORDER BY o.code)) AS d
  FROM operation_types o;
CREATE TEMP TABLE mes5b1_rows_before ON COMMIT DROP AS
SELECT {(',' + chr(10) + '       ').join(digest(t) for t in DIGEST_TABLES)};
""")

parts.append(f"""
-- ── 1 · 目录:每一个动作码声明"用它的那一页要哪几个查看码之一"(Q30)——列、注释、声明块、目录自检,与 db/tables/permissions.sql 逐字同一份 ──
ALTER TABLE public.permissions ADD COLUMN requires_view_any text[];
{PERM_COMMENT}
{PERM_DECL}
{PERM_CHECK}""")

parts.append(f"""
-- ── 2 · V37:每道工序 × 每种产出形态的预期质量得率(Q15)—— 空(Not yet set);只标不拒 ──────────────────────────────
ALTER TABLE public.operation_type_output_forms ADD COLUMN {V37_COL.strip()};
{V37_COMMENT}""")

parts.append(f"""
-- ── 3 · 拆去隔离那一道工序的平衡容差 = 0(Q11):这道工序原样搬运质量,任何不为 0 的余数按定义就是错的 ──────────────────
{TOL}
""")

parts.append("\n-- ── 4 · 换掉的两支函数(镜像原样,同签名):角色保存多一道 ACTION_REQUIRES_VIEW · 拆分那一炉自己结平 ──────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))
parts.append("\n-- ── 5 · 十二张新视图(镜像原样,依赖顺序;基视图从 authenticated 收回,外壳带门)──────────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v, False))
parts.append("\n-- ── 6 · 换掉的视图(镜像原样):待补的值 +V37 ──────────────────────────────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, True))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes5b1_pending_decider_check")
parts.append("\n-- ── 7 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

digest_checks = "\n       OR ".join(
    f"(SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM {t} t) IS DISTINCT FROM (SELECT {t} FROM mes5b1_rows_before)"
    for t in DIGEST_TABLES if t != "operation_type_output_forms")
base_list = ", ".join(f"'{v}'" for v in BASE_VIEWS)
reader_list = ", ".join(f"'{v}'" for v in READERS)
all_list = ", ".join(f"'{v}'" for v in NEW_VIEWS)

parts.append(f"""
CREATE TEMP TABLE mes5b1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行都没动(本刀不加码、不改任何一个角色的授权;引导的修正只在镜像里)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5b1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes5b1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5B1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5b1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5b1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5B1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的加工单、腿、损耗、结平、批次、流水、分录、费用单、付款、设备、安全状态逐字未变(不回填)
    IF EXISTS ((SELECT b.k, b.id FROM mes5b1_pending_before b EXCEPT SELECT a.k, a.id FROM mes5b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5b1_pending_after a EXCEPT SELECT b.k, b.id FROM mes5b1_pending_before b)) THEN
        RAISE EXCEPTION 'MES5B1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES5B1_PROOF|a pre-existing run, leg, loss, closure, batch, movement, journal, expense, payment, device or state changed';
    END IF;
    -- 产出形态表:只多了一列空的(去掉那一列之后逐字相同)
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'expected_yield_pct')::text, '|' ORDER BY (to_jsonb(t) - 'expected_yield_pct')::text), '')) FROM operation_type_output_forms t)
         IS DISTINCT FROM (SELECT operation_type_output_forms FROM mes5b1_rows_before)
       OR EXISTS (SELECT 1 FROM operation_type_output_forms WHERE expected_yield_pct IS NOT NULL) THEN
        RAISE EXCEPTION 'MES5B1_PROOF|operation_type_output_forms changed beyond an empty V37 column';
    END IF;
    -- 工序表:除了拆分那一道的容差,逐字相同;拆分那一道的容差 = 0
    IF (SELECT md5(string_agg((to_jsonb(o) - 'balance_tolerance_pct')::text || '|' || CASE WHEN o.code = 'discharge_quarantine_split' THEN '' ELSE COALESCE(o.balance_tolerance_pct::text, '') END, '|' ORDER BY o.code)) FROM operation_types o)
         IS DISTINCT FROM (SELECT d FROM mes5b1_ops_before)
       OR (SELECT balance_tolerance_pct FROM operation_types WHERE code = 'discharge_quarantine_split') IS DISTINCT FROM 0 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|operation_types changed beyond the split tolerance 0';
    END IF;

    -- ④ 变更记录只在 permissions(33 行声明)与 operation_types(1 行容差)上动了
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes5b1_log_before), 0) AND c.table_name NOT IN ('permissions', 'operation_types');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|change_log moved on %', v_bad; END IF;
    IF (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5b1_log_before), 0) AND c.table_name = 'permissions') <> 33
       OR (SELECT count(*) FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5b1_log_before), 0) AND c.table_name = 'operation_types') <> 1 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|expected 33 permissions rows and 1 operation_types row in the change log';
    END IF;

    -- ⑤ 声明:33 个动作码声明了,没有屏幕的那一个没声明;线上【每一个】角色都满足"动作码蕴含查看码"(Step 0 §0:67 / 67)
    IF (SELECT count(*) FROM permissions WHERE requires_view_any IS NOT NULL) <> 33
       OR (SELECT requires_view_any FROM permissions WHERE code = 'action.anonymise_employee') IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PROOF|expected 33 declared action codes and action.anonymise_employee undeclared';
    END IF;
    SELECT string_agg(ro.code || ' -> ' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|a live role holds an action without any of its views: %', v_bad; END IF;

    -- ⑥ 没有设任何东西:V37 空(上面)、require_calibrated_since 空;线上没有一张 MES-4a 之后的单,所以 V37 那一支零行
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 匿名面:anon 能执行的【恰好】两支;十二张新视图 anon 一张都读不到;基视图 authenticated 读不到,外壳读得到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5B1_PROOF|anon executes: %', v_bad;
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({all_list}) AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|anon can read %', v_bad; END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({base_list}) AND has_table_privilege('authenticated', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|a base view is readable by authenticated: %', v_bad; END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ({reader_list}) AND NOT has_table_privilege('authenticated', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B1_PROOF|a reader is not readable by authenticated: %', v_bad; END IF;
    IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = 'public' AND c.relname IN ({all_list})) <> {len(NEW_VIEWS)} THEN
        RAISE EXCEPTION 'MES5B1_PROOF|expected {len(NEW_VIEWS)} new views';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条;变更记录覆盖零缺口(没有新表,豁免仍是 8);遮蔽零缺口(规则仍是 111 条 —— 没有新的遮蔽列)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|the open read policies are no longer 44';
    END IF;
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 111 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 59 不变;待补的值 19 → 20 支;V37 今天零行;V1 不再列拆分那道工序
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|operations_now should still have 59 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|pending_values should have 20 arms';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5B1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5b1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
