#!/usr/bin/env python3
"""MES-7a-2(v1.4.53):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数、新视图与换掉的函数 / 视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(科目表多一行 6800、分录来源多一种、流水多两种类型与它们的符号 / 侧面、流水上
一支"只经函数"的守卫、保养记录上一支"挂着件不能资本化"的守卫)在这里逐句写出,并先断言镜像里那几行真的是这个样子。
照抄 build_mes7a1_migration.py 的形状。跑法:python3 db/scripts/build_mes7a2_migration.py(在仓库根目录)。
应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-16-mes7a2-spare-parts.sql"

NEW_TABLES = ["maintenance_part_issues"]
# 先于新表:三支触发器函数(plpgsql 的体建的时候不解析表名)
NEW_FUNCS_EARLY = ["guard_maintenance_movement", "guard_part_issue_write", "guard_maintenance_capitalise_parts"]
# 新表之后
NEW_FUNCS_LATE = ["inbound_batch_maintenance_net_qty", "issue_spare_parts", "return_spare_parts"]
# 同签名换掉
REPLACED_FUNCS = ["reprice_inbound_batch", "preview_reprice_inbound_batch", "guard_quality_hold", "inventory_control_reconciliation",
                  "journal_entry_reversal_route", "trail_subject_members"]

PUBLIC_SIGS = ["public.issue_spare_parts(uuid, date, jsonb)",
               "public.return_spare_parts(uuid, numeric, date, text)",
               "public.reprice_split(numeric, numeric, numeric, numeric, numeric)"]
INTERNAL_SIGS = ["public.guard_maintenance_movement()", "public.guard_part_issue_write()", "public.guard_maintenance_capitalise_parts()",
                 "public.inbound_batch_maintenance_net_qty(uuid)"]

# 前后比对的表(既有的行逐字未变)。科目表只比 6800 以外的行(6800 是本刀加的那一行)
DIGEST_TABLES = {
    "inbound_batches": "", "inventory_movements": "", "journal_entries": "", "journal_lines": "", "price_history": "",
    "materials": "", "material_kinds": "", "equipment_maintenance": "", "equipment_downtime": "", "equipment_service_intervals": "",
    "fixed_assets": "", "nonconformance_reports": "", "certificates_of_destruction": "", "cod_issues": "",
    "certificates_of_analysis": "", "coa_issues": "", "warehouse_requests": "", "receipt_price_requests": "", "expenses": "",
    "payments": "", "approval_log": "", "processing_runs": "", "processing_inputs": "", "stocktakes": "", "stocktake_lines": "",
    "accounts": "WHERE code <> '6800'",
}


def fn(name, create=False):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    if create:
        # 换了签名的那一支:DROP 之后 CREATE(preflight 不许 CREATE OR REPLACE 换签名 —— 那会是一次镜像看不见的重载)
        assert body.count("CREATE OR REPLACE FUNCTION") == 1, name
        body = body.replace("CREATE OR REPLACE FUNCTION", "CREATE FUNCTION")
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def view(name, replace=False):
    text = mirror(f"db/views/{name}.sql")
    assert text.count(f"CREATE VIEW public.{name} ") == 1, name
    if replace:
        text = text.replace(f"CREATE VIEW public.{name} ", f"CREATE OR REPLACE VIEW public.{name} ")
    return "\n" + text


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


def digest(t, where):
    return f"(SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM {t} t {where})"


def trigger_stmt(path, name):
    m = re.search(r"CREATE TRIGGER " + re.escape(name) + r"\n.*?;\n", mirror(path), re.S)
    assert m, (path, name)
    return m.group(0)


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
ACC_ROW = must("db/tables/accounts.sql", "    ('6800', 'Repairs & Maintenance', '维修保养费', 'expense', true, false);")
JE_LIST = must("db/tables/journal_entries.sql",
               "'credit_note','wht_remittance','maintenance_part')),")
IM = "db/tables/inventory_movements.sql"
must(IM, "         'transfer_out','transfer_in','maintenance_issue','maintenance_return')),")
must(IM, "        WHEN 'maintenance_issue' THEN qty_delta < 0\n        WHEN 'maintenance_return' THEN qty_delta > 0\n")
must(IM, "        WHEN 'maintenance_issue' THEN inbound_batch_id IS NOT NULL AND stock_status = 'available'\n"
         "        WHEN 'maintenance_return' THEN inbound_batch_id IS NOT NULL AND stock_status = 'available'\n")
IM_TRG = trigger_stmt(IM, "trg_inventory_movements_maintenance_ctx")
EM_TRG = trigger_stmt("db/tables/equipment_maintenance.sql", "trg_equipment_maintenance_parts_capitalise")
assert "received as lots so stock and cost are counted" in mirror("db/tables/material_kinds.sql")

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))
grants = mirror("db/views/zzz_function_grants.sql")
for sig in INTERNAL_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" in grants, sig
for sig in PUBLIC_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" not in grants, sig
assert "'V21'::text AS value_code" in mirror("db/views/pending_values.sql")
assert "issued_to_maintenance" in mirror("db/views/stock_rollforward_monthly.sql")
assert "('maintenance'::text,n.maintenance,6)" in mirror("db/views/batch_balance_tree_all.sql")
assert "'maintenance_issue'" in mirror("db/functions/guard_quality_hold.sql")
assert "'maintenance_part'" in mirror("db/functions/journal_entry_reversal_route.sql")
assert "e.st = 'maintenance_part'" in mirror("db/functions/inventory_control_reconciliation.sql")

# 流水上的三条 CHECK —— 照镜像里的字逐字写出(上面的 must 已经断言镜像里是这几行)
MV_TYPE_CHECK = ("CHECK (movement_type IN ('receipt','processing_consume','processing_produce','reversal_restore','reversal_void','sale',"
                 "'writeoff','adjustment','status_change_out','status_change_in','transfer_out','transfer_in','maintenance_issue','maintenance_return'))")
MV_SIGN = """CHECK (CASE movement_type
        WHEN 'receipt' THEN qty_delta > 0
        WHEN 'processing_produce' THEN qty_delta > 0
        WHEN 'reversal_restore' THEN qty_delta > 0
        WHEN 'processing_consume' THEN qty_delta < 0
        WHEN 'reversal_void' THEN qty_delta < 0
        WHEN 'sale' THEN qty_delta < 0
        WHEN 'writeoff' THEN qty_delta < 0
        WHEN 'status_change_out' THEN qty_delta < 0
        WHEN 'status_change_in' THEN qty_delta > 0
        WHEN 'transfer_out' THEN qty_delta < 0
        WHEN 'transfer_in' THEN qty_delta > 0
        WHEN 'maintenance_issue' THEN qty_delta < 0
        WHEN 'maintenance_return' THEN qty_delta > 0
        ELSE true END)"""
MV_SIDE = """CHECK (CASE movement_type
        WHEN 'processing_produce' THEN output_batch_id IS NOT NULL
        WHEN 'reversal_void' THEN output_batch_id IS NOT NULL
        WHEN 'sale' THEN output_batch_id IS NOT NULL
        WHEN 'maintenance_issue' THEN inbound_batch_id IS NOT NULL AND stock_status = 'available'
        WHEN 'maintenance_return' THEN inbound_batch_id IS NOT NULL AND stock_status = 'available'
        ELSE true END)"""
JE_CHECK = ("CHECK (source_type IN ('manual','purchase','sale','processing_cost','allocation','stocktake','writeoff','payment','fx','expense',"
            "'prepayment','payroll','transfer','revaluation','depreciation','asset_disposal','year_close','freight','invoice','shipment',"
            "'credit_note','wht_remittance','maintenance_part'))")
for frag in ["WHEN 'transfer_in' THEN qty_delta > 0\n        WHEN 'maintenance_issue' THEN qty_delta < 0",
             "WHEN 'sale' THEN output_batch_id IS NOT NULL\n        -- MES-7a-2"]:
    assert frag in mirror(IM), frag

HEADER = """-- db/migrations/2026-10-16-mes7a2-spare-parts.sql
-- MES-7a-2 —— 备件:按批收货,出给一条保养记录(借 6800 Repairs & Maintenance / 贷 1200,按落地单价),带理由退回
--   (MES 组的第十七刀,v1.4.53;发布那一行在 docs/handbacks/MES-7a-2.md 的抬头)。由 db/scripts/build_mes7a2_migration.py 从镜像拼出;
--   改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-16:MES-7a Step 0 的 Q2 · Q10–Q17 · Q20–Q23 照推荐裁定;Q11:费用科目 6800 Repairs & Maintenance,系统科目)
--   ① 科目表多一行 6800 Repairs & Maintenance(expense,is_system —— issue_spare_parts / return_spare_parts / reprice_inbound_batch 按 code 点名)。
--   ② 分录来源多一种 maintenance_part(出给保养 / 退回;journal_entry_reversal_route 认它作 source_path —— 更正是一行退回,不是冲掉分录)。
--   ③ 库存流水多两种类型 maintenance_issue(为负,进料一侧,可用桶)与 maintenance_return(为正);只由那两支函数写
--      (trg_inventory_movements_maintenance_ctx 按名拒别的写法 MAINTENANCE_MOVEMENT_THROUGH_FUNCTION_ONLY)。
--   ④ maintenance_part_issues(一行一次出库或一次退回;只可追加;只经函数写;不带钱 —— 钱在分录上)进变更记录(豁免仍是 8;没有遮蔽的列)。
--   ⑤ issue_spare_parts · return_spare_parts(码 module.inventory.edit,没有审批 —— Q10):只出 spare_part 的批;只出给没有资本化的保养记录;
--      数量 ≤ 可用;没定价的批按名拒 SPARE_PART_UNPRICED(暂定价是价);质量暂扣挡出库不挡退回(guard_quality_hold 多认一种);
--      一条还挂着件的保养记录不能再资本化(trg_equipment_maintenance_parts_capitalise,MAINTENANCE_HAS_PARTS)。
--   ⑥ 改价:reprice_split 多一个入参(出给保养的净数量),已出给保养那一份的价差进 6800、不进 5000 —— 一份算术照旧两个调用者
--      (reprice_inbound_batch · preview_reprice_inbound_batch);签名换了,旧的那一支 DROP。
--   ⑦ 存货控制科目勾稽把 maintenance_part 的 1200 行归回批次,M3 / M4 的"已被消耗"只算加工消耗(inventory_control_reconciliation)。
--   ⑧ 库存月度滚动多一列 issued_to_maintenance(DROP + CREATE 两张视图:新列排在 voided 之后、moved 之前);质量树多一条去向 maintenance;
--      待定值多一支 V21(备件的最低库存);备件库存的读视图 spare_part_stock(可用 · 有没有价 · 在不在暂扣 —— 与函数同一组判据,不带钱)。
--   ⑨ 审计:不加新主语;出库记录在 equipment 下(家)与 inbound_batch 下(连同那张分录)。
--   material_kinds 那一行备件的说明在镜像里改写(Q2:按批收货、挂保养记录出库、不逐件追溯)—— 它是 RUNTIME CONFIG,本迁移【不】改线上那一行。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权一行不动;不写、不改任何一行既有的批次、流水、分录、物料、保养记录、证书;
--   不建任何备件物料、批次、出库、退回或最低库存;不回填。require_calibrated_since 保持空。线上由本迁移造出的只有:6800 那一个科目、
--   两种流水类型(与一种分录来源)、一张空表、两支函数与它们的守卫、一张读视图、V21 那一支(线上没有备件物料,它读出 0 行)。
--
-- 【破窗】(Q21:这一窗什么都不坏)旧应用不写这两种新类型、不读新表;库存滚动两张视图换成 DROP + CREATE 的那一瞬在同一笔事务里,
--   旧应用读的列一列不少(只多一列)。旧应用的改价预览不读多出来的那个返回键。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动,admin 持目录里每一个码(79);在途单据一张不少、一张不多,每一张仍有
--   一个不是它当事人的决定人;七个账号一个都没被停;既有的批次、流水、分录、物料、物料种类、保养、停机、间隔、资产、不合格报告、证书、字节档案、
--   申请、费用、付款、审批留痕、加工单、盘点、科目(减去 6800)逐字未变;科目恰好多一行 6800(系统、启用);流水 14 种类型;出库表 0 行、两种新流水
--   0 行;旧的 reprice_split 不在了;守卫都在;本事务往变更记录只写了科目那一行;三支对外的函数员工调得到、四支内层与触发器调不到;anon 能执行的
--   【恰好】两支;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);提醒 66 支、待定值 24 支;299 张表。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES7A2_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM accounts WHERE code = '6800') THEN
        RAISE EXCEPTION 'MES7A2_PRE|account 6800 already exists: %', (SELECT name_en FROM accounts WHERE code = '6800');
    END IF;
    IF to_regclass('public.maintenance_part_issues') IS NOT NULL OR to_regclass('public.spare_part_stock') IS NOT NULL
       OR to_regprocedure('public.issue_spare_parts(uuid, date, jsonb)') IS NOT NULL
       OR to_regprocedure('public.reprice_split(numeric, numeric, numeric, numeric, numeric)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A2_PRE|MES-7a-2 objects already exist';
    END IF;
    IF to_regprocedure('public.reprice_split(numeric, numeric, numeric, numeric)') IS NULL THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected the four-argument reprice_split';
    END IF;
    IF pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'inventory_movements_movement_type_check')) LIKE '%maintenance%'
       OR pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'journal_entries_source_type_check')) LIKE '%maintenance%' THEN
        RAISE EXCEPTION 'MES7A2_PRE|the movement / source type checks already know maintenance';
    END IF;
    IF EXISTS (SELECT 1 FROM materials WHERE kind_code = 'spare_part') THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected no spare-part material on live (opening reading)';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected a catalogue of 79 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66 THEN
        RAISE EXCEPTION 'MES7A2_PRE|operations_now should have 66 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES7A2_PRE|pending_values should have 23 arms';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 298 THEN
        RAISE EXCEPTION 'MES7A2_PRE|expected 298 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A2_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, w)} AS {t}" for t, w in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes7a2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes7a2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes7a2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes7a2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes7a2_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 新函数(镜像原样),先于新表:两种保养流水只经函数 · 出库记录只可追加只经函数 · 挂着件不能资本化(三支触发器函数)──\n")
for f in NEW_FUNCS_EARLY:
    parts.append(fn(f))

parts.append(f"""
-- ── 2 · 科目表多一行 6800(与 db/tables/accounts.sql 系统段那一行逐字同一份)───────────────────────────
INSERT INTO public.accounts (code, name_en, name_zh, account_type, is_system, is_monetary) VALUES
{ACC_ROW.rstrip().rstrip(';')};

-- ── 3 · 分录来源多一种 maintenance_part(镜像 db/tables/journal_entries.sql 的列内 CHECK;约束名是线上那一个)────────
ALTER TABLE public.journal_entries DROP CONSTRAINT journal_entries_source_type_check;
ALTER TABLE public.journal_entries ADD CONSTRAINT journal_entries_source_type_check
    {JE_CHECK};

-- ── 4 · 库存流水:两种新类型与它们的符号、侧面(镜像 db/tables/inventory_movements.sql);只经函数的守卫 ──────────────
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_movement_type_check;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_movement_type_check
    {MV_TYPE_CHECK};
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_sign;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_sign {MV_SIGN};
ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_side;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_side {MV_SIDE};
{IM_TRG}""")

parts.append("\n-- ── 5 · 新表(镜像原样):备件出给保养与退回 ─────────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append(f"""
-- ── 6 · 保养记录:一条还挂着件的记录不能再资本化(与 db/tables/equipment_maintenance.sql 那一支逐字同一份)────────
{EM_TRG}""")

parts.append("\n-- ── 7 · 新函数(镜像原样),新表之后:出给保养的净数量 · 出库 · 退回 ──────────────────────────\n")
for f in NEW_FUNCS_LATE:
    parts.append(fn(f))

parts.append("\n-- ── 8 · reprice_split 换签名(四个入参 → 五个):DROP 旧的,CREATE 新的 —— 两支并存是一次镜像看不见的重载 ─────\n")
parts.append("DROP FUNCTION public.reprice_split(numeric, numeric, numeric, numeric);\n")
parts.append(fn("reprice_split", create=True))

parts.append("\n-- ── 9 · 换掉的函数(镜像原样,同签名):改价两支认得保养份额 · 质量暂扣挡出库 · 存货勾稽归因 · 冲销路由 · 审计成员 ─\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 10 · 视图(镜像原样):库存滚动 DROP + CREATE(多一列)· 质量树与待定值 CREATE OR REPLACE(列不变)· 备件库存(新)──\n")
parts.append("DROP VIEW public.stock_rollforward_monthly;\nDROP VIEW public.stock_rollforward_monthly_all;\n")
parts.append(view("stock_rollforward_monthly_all"))
parts.append(view("stock_rollforward_monthly"))
parts.append(view("batch_balance_tree_all", replace=True))
parts.append(view("pending_values", replace=True))
parts.append(view("spare_part_stock"))

parts.append("\n-- ── 11 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 12 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in PUBLIC_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO service_role;\n")
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes7a2_pending_decider_check")
parts.append("\n-- ── 13 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

public_checks = "\n".join(
    f"""    IF NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|{sig} must be callable by staff and not by anon';
    END IF;""" for sig in PUBLIC_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(f"{digest(t, w)} IS DISTINCT FROM (SELECT {t} FROM mes7a2_rows_before)" for t, w in DIGEST_TABLES.items())
TRIGGERS = [("inventory_movements", "trg_inventory_movements_maintenance_ctx"), ("inventory_movements", "trg_inventory_movements_quality_hold"),
            ("inventory_movements", "trg_inventory_movements_through_function"),
            ("maintenance_part_issues", "trg_maintenance_part_issues_direct"), ("maintenance_part_issues", "trg_maintenance_part_issues_immutable"),
            ("maintenance_part_issues", "zzz_change_log"), ("equipment_maintenance", "trg_equipment_maintenance_parts_capitalise"),
            ("equipment_maintenance", "trg_equipment_maintenance_direct")]
for t, g in TRIGGERS:
    if g != "zzz_change_log":
        assert g in mirror(f"db/tables/{t}.sql"), (t, g)
trigger_checks = "\n       OR ".join(
    f"NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '{g}' AND tgrelid = 'public.{t}'::regclass)" for t, g in TRIGGERS)

parts.append(f"""
CREATE TEMP TABLE mes7a2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行没动;admin 持目录里每一个码(79)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes7a2_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes7a2_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A2_PROOF|a grant changed: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 79
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|admin does not hold every one of the 79 codes';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES7A2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes7a2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes7a2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes7a2_pending_before b EXCEPT SELECT a.k, a.id FROM mes7a2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes7a2_pending_after a EXCEPT SELECT b.k, b.id FROM mes7a2_pending_before b)) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES7A2_PROOF|a pre-existing batch, movement, journal, price, material, kind, maintenance, downtime, interval, asset, NCR, certificate, byte record, request, expense, payment, approval, run, stocktake or account changed';
    END IF;

    -- ④ 科目恰好多一行 6800(系统、启用、费用);流水 14 种类型;出库表与两种新流水都是 0 行;旧的 reprice_split 不在了
    IF (SELECT count(*) FROM accounts WHERE code = '6800' AND is_system AND is_active AND account_type = 'expense'
          AND name_en = 'Repairs & Maintenance') <> 1 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|6800 Repairs & Maintenance must exist once, as an active system expense account';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_constraintdef((SELECT oid FROM pg_constraint WHERE conname = 'inventory_movements_movement_type_check')),
                                            '''[a-z_]+''::text', 'g')) <> 14 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|the movement type check should name 14 types';
    END IF;
    IF EXISTS (SELECT 1 FROM maintenance_part_issues)
       OR EXISTS (SELECT 1 FROM inventory_movements WHERE movement_type IN ('maintenance_issue', 'maintenance_return'))
       OR EXISTS (SELECT 1 FROM journal_entries WHERE source_type = 'maintenance_part') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|no issue, movement or entry of the new kinds may exist';
    END IF;
    IF to_regprocedure('public.reprice_split(numeric, numeric, numeric, numeric)') IS NOT NULL
       OR to_regprocedure('public.reprice_split(numeric, numeric, numeric, numeric, numeric)') IS NULL THEN
        RAISE EXCEPTION 'MES7A2_PROOF|reprice_split must exist only with five arguments';
    END IF;
    IF {trigger_checks} THEN
        RAISE EXCEPTION 'MES7A2_PROOF|a guard trigger is missing';
    END IF;

    -- ⑤ 本事务往变更记录只写了科目那一行(按 txid 认 —— 同一时刻同事们在线上的写不算在本刀头上);require_calibrated_since 仍空
    SELECT string_agg(c.table_name || ':' || c.op, ', ' ORDER BY c.seq) INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes7a2_log_before), 0) AND c.txid = txid_current();
    IF v_bad IS DISTINCT FROM 'accounts:INSERT' THEN
        RAISE EXCEPTION 'MES7A2_PROOF|change_log rows of this transaction: % (expected only the 6800 account)', v_bad;
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES7A2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:提醒 66 支、待定值 24 支(多了 V21);299 张表;出库表的审计成员在册(设备是家)
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 66
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 24 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|operations_now should have 66 arms and pending_values 24';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 299 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|expected 299 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subject_members() m WHERE m.subject = 'equipment' AND m.table_name = 'maintenance_part_issues' AND m.home) THEN
        RAISE EXCEPTION 'MES7A2_PROOF|part issues must live under the equipment trail';
    END IF;

    -- ⑦ 函数面:三支员工调得到;四支内层与触发器调不到;anon 能执行的【恰好】两支;新表与新视图 anon 读不到
{public_checks}
{internal_checks}
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES7A2_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_table_privilege('anon', 'public.maintenance_part_issues'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.spare_part_stock'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES7A2_PROOF|anon reads a new relation';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|the open read policies are no longer 44';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(出库表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes7a2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES7A2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes7a2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES7A2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes7a2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
