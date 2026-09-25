#!/usr/bin/env python3
"""ROLE-1 Batch 3b:从镜像拼出迁移文件(形状照 build_role1b3a_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数、策略、触发器、视图都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_role1b3b_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-25-role1b3b-the-warehouse-makes-finance-releases.sql"
NEW_CODES = ["action.receive_goods", "action.batch_write_off", "action.wo_create", "action.wo_release",
             "action.processing_commit", "action.processing_rollback", "action.processing_aftercare"]
WAREHOUSE_CODES = ["action.receive_goods", "action.batch_write_off", "action.wo_create",
                   "action.processing_commit", "action.processing_rollback", "action.processing_aftercare"]


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.lstrip().startswith("--"):
        body = f"-- ─── {name}\n" + body
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def stmt(path, head):
    """从镜像里抽出以 head 开头、到【语句真正的结尾】为止的那一句(跳过 -- 注释与单引号字符串)。"""
    s = mirror(path)
    assert s.count(head) == 1, (path, head)
    i = s.index(head)
    k = i
    while True:
        c = s[k]
        if s.startswith("--", k):
            k = s.index("\n", k)
        elif c == "'":
            k = s.index("'", k + 1)
            while s.startswith("''", k):
                k = s.index("'", k + 2)
        elif c == ";":
            return s[i:k + 1] + "\n"
        k += 1


HEADER = """-- db/migrations/2026-09-25-role1b3b-the-warehouse-makes-finance-releases.sql
-- ROLE-1 Batch 3b —— 收货建单、工单、加工提交、回滚与注销归仓库;工单下达归财务,建单人永远不能下达。
-- 由 db/scripts/build_role1b3b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(ROLE-1 Batch 3 grilling Q1 · Q6–Q9,Tim 2026-09-25;Batch 3b grilling Q1–Q6,同日)
--   ① 七个新码,全部一并授给 admin(Tim 的常设裁定):
--      action.receive_goods(建收货单:create_inbound_batch · receive_inbound_batch_against_po)→ warehouse
--      action.batch_write_off(soft_delete_inbound_batch · soft_delete_output_batch)→ warehouse
--      action.wo_create(建工单;改 / 取消 / 关闭 = 它或 module.processing.edit)→ warehouse
--      action.wo_release(下达;建单人按人认永远不能下达 —— forbid_self_approval 早已在)→ finance
--      action.processing_commit · action.processing_rollback → warehouse
--      action.processing_aftercare(损耗分类与交接班 = 它或 module.processing.edit;Batch 3b Q2)→ warehouse
--      仓库另拿 module.processing.view(Q6);【不】拿 module.materials.view(Q8)。
--   ② create_work_order:建单人之外没有真持有人持 action.wo_release → WO_NO_OTHER_RELEASER(Batch 3b Q3)。
--   ③ 加工三张表不许绕过函数写(Q7 · Batch 3b Q1):runs / outputs 的 INSERT 策略、runs / outputs / inputs 的
--      DELETE 策略拿掉;guard_processing_direct_write 按名拒 PROCESSING_THROUGH_FUNCTION_ONLY(直连插、直连删、
--      runs 上直连改 status 或 work_order_id)。UPDATE 策略留着(登记)。
--   ④ material_lookup 的谓词加 module.processing.view(Batch 3b Q4);三页改读它(应用侧)。
--
-- 【不做什么】不碰审批开关与策略、user_roles、任何业务行;不动 COD 作废与发货(Q9);不动加工费用条目
-- (processing_cost_entries 仍归 module.processing.edit)与分摊(module.finance.edit,读 _all —— 3a 的裁定)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权 = 之前 + 裁定的那十五行;七个新码的持有人
-- 正好是裁定的角色;在途单据一张不少、一张不多;approval_log、journal_entries、工单、加工单(按状态)、产出、投料、
-- 损耗、收货与产出批次(全部 / 已注销)一行没变;五条策略没了、五支守卫触发器挂上;十三支函数的门换成新码;
-- 每一张在途单据(含草稿工单:下达人不是建单人)都还有一个决定人。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = """SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM work_orders) AS work_orders,
       (SELECT count(*) FROM work_orders WHERE status = 'released') AS work_orders_released,
       (SELECT count(*) FROM processing_runs WHERE status = 'committed') AS runs_committed,
       (SELECT count(*) FROM processing_runs WHERE status = 'reversed') AS runs_reversed,
       (SELECT count(*) FROM processing_outputs) AS processing_outputs,
       (SELECT count(*) FROM processing_inputs) AS processing_inputs,
       (SELECT count(*) FROM processing_run_losses) AS processing_run_losses,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS receipts_written_off,
       (SELECT count(*) FROM output_batches) AS outputs_all,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS outputs_written_off,
       (SELECT count(*) FROM shift_handovers) AS shift_handovers"""

RULED = ([f"warehouse:{c}" for c in WAREHOUSE_CODES] + [f"admin:{c}" for c in NEW_CODES]
         + ["finance:action.wo_release", "warehouse:module.processing.view"])
assert len(RULED) == 15

HOLDERS = {c: "admin warehouse" for c in WAREHOUSE_CODES}
HOLDERS["action.wo_release"] = "admin finance"

DROPPED = [("processing_runs", "insert"), ("processing_runs", "delete"),
           ("processing_outputs", "insert"), ("processing_outputs", "delete"),
           ("processing_inputs", "delete")]
GUARDS = ["trg_processing_runs_direct_write", "trg_processing_runs_direct_delete",
          "trg_processing_outputs_direct_write", "trg_processing_outputs_direct_delete",
          "trg_processing_inputs_direct_delete"]
FUNCS = {
    "create_inbound_batch": "require_permission('action.receive_goods')",
    "receive_inbound_batch_against_po": "require_permission('action.receive_goods')",
    "soft_delete_inbound_batch": "require_permission('action.batch_write_off')",
    "soft_delete_output_batch": "require_permission('action.batch_write_off')",
    "create_work_order": "require_permission('action.wo_create')",
    "amend_work_order": "has_any_permission(ARRAY['action.wo_create', 'module.processing.edit'])",
    "cancel_work_order": "has_any_permission(ARRAY['action.wo_create', 'module.processing.edit'])",
    "close_work_order": "has_any_permission(ARRAY['action.wo_create', 'module.processing.edit'])",
    "release_work_order": "require_permission('action.wo_release')",
    "commit_processing_run": "require_permission('action.processing_commit')",
    "rollback_processing_run": "require_permission('action.processing_rollback')",
    "submit_shift_handover": "has_any_permission(ARRAY['action.processing_aftercare', 'module.processing.edit'])",
    "acknowledge_shift_handover": "has_any_permission(ARRAY['action.processing_aftercare', 'module.processing.edit'])",
}

parts = [HEADER]
codes_sql = ", ".join(f"'{c}'" for c in NEW_CODES)
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ({codes_sql})) THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|new codes already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND policyname IN ('processing_runs insert by permission', 'processing_runs delete by permission',
                            'processing_outputs insert by permission', 'processing_outputs delete by permission',
                            'processing_inputs delete by permission')) <> 5 THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|the five processing write policies are not all there to drop';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code = 'module.processing.view') THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|warehouse already holds module.processing.view';
    END IF;
    -- 下达要读得到工单:finance 今天持 module.processing.view
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                    WHERE r.code = 'finance' AND rp.permission_code = 'module.processing.view') THEN
        RAISE EXCEPTION 'ROLE1B3B_PRE|finance does not hold module.processing.view';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b3b_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE b3b_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE b3b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:七个新码 ─────────────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
""")
perm = mirror("db/tables/permissions.sql")
rows = [l.strip().rstrip(",;") for l in perm.splitlines() if l.strip().startswith(tuple(f"('{c}'" for c in NEW_CODES))]
assert len(rows) == 7, rows
parts.append("    " + ",\n    ".join(rows) + ";\n")

values = ",\n               ".join(f"('{r.split(':')[0]}', '{r.split(':')[1]}')" for r in RULED)
parts.append(f"""
-- ── 2 · 授权(在函数之前:下面的自证要问到它们)────────────────────────────────
-- 仓库做、财务下达;admin 七个都拿(Tim 的常设裁定);仓库另拿 module.processing.view。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES {values}) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

parts.append("\n-- ── 3 · 守卫函数(新;触发器要用到它)────────────────────────────────────────\n")
parts.append(fn("guard_processing_direct_write"))

parts.append("""
-- ── 4 · 加工三张表:INSERT / DELETE 写策略拿掉,直连写按名拒 ─────────────────────
""")
for t, op in DROPPED:
    parts.append(f'DROP POLICY "{t} {op} by permission" ON public.{t};\n')
for g in GUARDS:
    t = g[len("trg_"):].rsplit("_direct_", 1)[0]
    parts.append(stmt(f"db/tables/{t}.sql", f"CREATE TRIGGER {g}\n"))

parts.append("""
-- ── 5 · 损耗分类:module.processing.edit 或 action.processing_aftercare ────────────
""")
for op in ["insert", "update", "delete"]:
    parts.append(f'DROP POLICY "processing_run_losses {op} by permission" ON public.processing_run_losses;\n')
    parts.append(stmt("db/tables/processing_run_losses.sql", f'CREATE POLICY "processing_run_losses {op} by permission"\n'))
parts.append("DROP TRIGGER enforce_write_permission ON public.processing_run_losses;\n")
parts.append(stmt("db/tables/processing_run_losses.sql", "CREATE TRIGGER enforce_write_permission\n"))

parts.append("""
-- ── 6 · material_lookup:谓词加 module.processing.view(列清单不变)────────────────
""")
v = stmt("db/views/material_lookup.sql", "CREATE VIEW public.material_lookup")
parts.append(v.replace("CREATE VIEW public.material_lookup", "CREATE OR REPLACE VIEW public.material_lookup", 1))

parts.append("\n-- ── 7 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in FUNCS:
    parts.append(fn(name))

# ── 8 · 自证 ─────────────────────────────────────────────────────────────────
b3a = mirror("db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql")
start = b3a.index("CREATE FUNCTION pg_temp.b3a_pending_decider_check")
dec = b3a[start:b3a.index("$f$;", start) + 4].replace("b3a_pending_decider_check", "b3b_pending_decider_check")
old_wo = """      LEFT JOIN holds h ON 'module.processing.edit' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'"""
assert dec.count(old_wo) == 1
dec = dec.replace(old_wo, """      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'""")
parts.append("\n-- ── 8 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
ruled_sql = ", ".join(f"'{r}'" for r in RULED)
holders_checks = "\n".join(f"""    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = '{c}';
    IF v_bad IS DISTINCT FROM '{h}' THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|{c} holders are %', v_bad; END IF;"""
                           for c, h in HOLDERS.items())
gate_checks = "\n".join(f"""    IF NOT EXISTS (SELECT 1 FROM pg_proc WHERE proname = '{f}' AND pronamespace = 'public'::regnamespace)
       OR EXISTS (SELECT 1 FROM pg_proc WHERE proname = '{f}' AND pronamespace = 'public'::regnamespace
                     AND prosrc NOT LIKE '%{g.replace("'", "''")}%') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|{f} is not gated as ruled';
    END IF;""" for f, g in FUNCS.items())
guards_sql = ", ".join(f"'{g}'" for g in GUARDS)
parts.append(f"""
CREATE TEMP TABLE b3b_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 裁定的那十五行,一行不少、一行不多
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT (SELECT role_code || ':' || permission_code FROM b3b_grants_before
                 UNION SELECT unnest(ARRAY[{ruled_sql}])))
        UNION ALL
        ((SELECT role_code || ':' || permission_code FROM b3b_grants_before
          UNION SELECT unnest(ARRAY[{ruled_sql}]))
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|grants differ from before + ruled: %', v_bad; END IF;
{holders_checks}
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code = 'module.materials.view') THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|warehouse must not hold module.materials.view (Q8)';
    END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变
    IF EXISTS ((SELECT b.k, b.id FROM b3b_pending_before b EXCEPT SELECT a.k, a.id FROM b3b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b3b_pending_after a EXCEPT SELECT b.k, b.id FROM b3b_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM b3b_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM b3b_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;

    -- ④ 结构:五条策略没了;五支守卫挂上;损耗四处认两码;查名视图认 processing.view;十三支函数的门
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND ((tablename IN ('processing_runs', 'processing_outputs') AND cmd IN ('INSERT', 'DELETE'))
                  OR (tablename = 'processing_inputs' AND cmd = 'DELETE'))) THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|a processing insert / delete policy is still there';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ({guards_sql});
    IF v_n <> 5 THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|expected 5 processing guard triggers, got %', v_n; END IF;
    SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'public' AND tablename = 'processing_run_losses'
       AND cmd <> 'SELECT' AND coalesce(qual, with_check) LIKE '%action.processing_aftercare%';
    IF v_n <> 3 THEN RAISE EXCEPTION 'ROLE1B3B_PROOF|expected 3 loss write policies naming aftercare, got %', v_n; END IF;
    IF pg_get_viewdef('public.material_lookup'::regclass) NOT LIKE '%module.processing.view%' THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|material_lookup does not admit module.processing.view';
    END IF;
{gate_checks}

    -- ⑤ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求;草稿工单:下达人不是建单人)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b3b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B3B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b3b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B3B_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b3b_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b3b_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
