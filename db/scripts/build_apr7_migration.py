#!/usr/bin/env python3
"""APR-7:从镜像拼出迁移文件(形状照 build_apr6_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数、表、策略、触发器、视图都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_apr7_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql"


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


HEADER = """-- db/migrations/2026-09-25-apr7-write-offs-rollbacks-and-cod-voids-wait-for-the-cfo.sql
-- APR-7 —— 注销批次、加工回滚、作废销毁证书:仓库提,CFO 批每一张,批准之前什么都不发生
-- (docs/role-matrix.md「删除批次 · 加工回滚 · 作废销毁证书 | 仓库提 | CFO」)。
-- 由 db/scripts/build_apr7_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-7 grilling Q1–Q9,Tim 2026-09-25 全部接受)
--   ① 哪些注销要经 CFO(Q1):还有料(计价与否)、或进料批挂着已签发的销毁证书。空批照旧由仓库一步删
--      (batch_write_off_needs_request 一份判据)。
--   ② 一张表 warehouse_requests,四种(Q2):write_off_inbound · write_off_output · rollback · cod_void;
--      submitted → approved(当场生效)· rejected(要理由)· withdrawn。提交按同一条路试跑。
--      审批关着时生下来就是 approved 并当场生效(auto_approved)。
--   ③ 冻结(Q3):注销的那一批、回滚那张单的产出批上任何库存流水按名拒 WAREHOUSE_REQUEST_FREEZES_BATCH;
--      进料批上不许新开定价申请;一个批次、它的证书、消耗它的加工单同一时刻只挂一张在等的申请。
--   ④ 批准那一天生效、按那一刻的活数计价;欠款在提交时与批准时各查一遍(Q4)。
--   ⑤ 已锁期间里的加工单照旧可以回滚;CFO 那一块先说出来(Q5,snapshot.locked_period · cods_voided)。
--   ⑥ deleted_by / voided_by = 提单人(Q6);void_cod_internal 加一个参数 p_voided_by。
--   ⑦ 旧门(Q7):rollback_processing_run 与 void_cod 一张都不做,按名拒 WAREHOUSE_NEEDS_APPROVED_REQUEST;
--      soft_delete_inbound_batch / soft_delete_output_batch 只剩空批。函数体搬进 *_internal(收回 EXECUTE)。
--   ⑧ 引擎登记(Q8):approval_chain_gates 一行(二级,module.finance.view + data.view_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2);approval_log 的主体类型与读策略;
--      record_approval_decision 一支;operations_now 一支 warehouse_request_pending。
--   ⑨ 自证里"每一张在途单据都有一个不是它自己当事人的决定人"扩到每一条申请链(Q9)。
--
-- 【不做什么】不新增任何权限码(Q8),所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一条没变;在途单据一张不少、一张不多;
-- approval_log、分录、流水、被删批次、回滚过的加工单、证书状态一行没变;申请表是空的;申请表没有写策略;
-- 内层算子 authenticated 调不到;旧的回滚 / 作废门只会拒;两支冻结守卫挂上;新链有人批得了;
-- 每一张在途单据(连同每一条申请链)都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

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
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM inventory_movements) AS movements,
       (SELECT count(*) FROM inbound_batches WHERE deleted_at IS NOT NULL) AS inbound_deleted,
       (SELECT count(*) FROM output_batches WHERE deleted_at IS NOT NULL) AS output_deleted,
       (SELECT count(*) FROM processing_runs WHERE deleted_at IS NOT NULL) AS runs_deleted,
       (SELECT string_agg(status || ':' || n, ' ' ORDER BY status)
          FROM (SELECT status, count(*) AS n FROM certificates_of_destruction GROUP BY status) c) AS cods"""

INTERNALS = ["soft_delete_inbound_batch_internal(uuid, text, uuid)",
             "soft_delete_output_batch_internal(uuid, text, uuid)",
             "rollback_processing_run_internal(uuid, text, uuid)",
             "warehouse_request_submit_internal(text, uuid, text)",
             "warehouse_request_execute_internal(uuid)",
             "warehouse_request_dry_run(uuid)",
             "warehouse_request_touches(text, uuid)",
             "warehouse_request_freezing(uuid, uuid)",
             "warehouse_request_snapshot(text, uuid)",
             "warehouse_request_conflict(text, uuid)",
             "batch_write_off_needs_request(uuid, uuid)",
             "void_cod_internal(uuid, text, uuid, uuid)"]

DOORS = ["guard_warehouse_request_freeze()",
         "submit_inbound_write_off_request(uuid, text)", "submit_output_write_off_request(uuid, text)",
         "submit_rollback_request(uuid, text)", "submit_cod_void_request(uuid, text)",
         "decide_warehouse_request(uuid, boolean, text)", "withdraw_warehouse_request(uuid, text)",
         "warehouse_requests_visible(integer)"]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR7_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.warehouse_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR7_PRE|warehouse_requests already exists';
    END IF;
    IF to_regprocedure('public.void_cod_internal(uuid, text, uuid)') IS NULL THEN
        RAISE EXCEPTION 'APR7_PRE|void_cod_internal(uuid, text, uuid) is not there to replace';
    END IF;
    -- 批的人要持两个门码:cfo 今天持 module.finance.view 与 data.view_prices
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR7_PRE|cfo does not hold both gate codes';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a7_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE a7_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE a7_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

# ── 1 · 表 ───────────────────────────────────────────────────────────────────
t = mirror("db/tables/warehouse_requests.sql")
parts.append("\n-- ── 1 · warehouse_requests(镜像原样)────────────────────────────────────────\n")
parts.append(t[t.index("CREATE TABLE public.warehouse_requests"):])

# ── 2 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'warehouse_request')),", i) + len("'warehouse_request'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 2 · approval_log:主体类型加 warehouse_request;读策略加同名一支 ────────────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 3 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
parts.append("-- void_cod_internal 多了一个参数 p_voided_by(Q6):换签名,旧的那一支先拿掉\n"
             "DROP FUNCTION public.void_cod_internal(uuid, text, uuid);\n")
for name in ["void_cod_internal",
             "soft_delete_inbound_batch_internal", "soft_delete_output_batch_internal",
             "rollback_processing_run_internal",
             "batch_write_off_needs_request", "warehouse_request_touches", "warehouse_request_conflict",
             "warehouse_request_freezing", "guard_warehouse_request_freeze", "warehouse_request_snapshot",
             "warehouse_request_execute_internal", "warehouse_request_dry_run",
             "warehouse_request_submit_internal",
             "submit_inbound_write_off_request", "submit_output_write_off_request",
             "submit_rollback_request", "submit_cod_void_request",
             "decide_warehouse_request", "withdraw_warehouse_request", "warehouse_requests_visible",
             "soft_delete_inbound_batch", "soft_delete_output_batch", "rollback_processing_run", "void_cod",
             "record_approval_decision", "approval_pending_documents", "approval_chain_gates"]:
    parts.append(fn(name))

# ── 4 · 冻结守卫 ──────────────────────────────────────────────────────────────
parts.append("\n-- ── 4 · 冻结守卫:库存流水与定价申请(Q3)──────────────────────────────────────\n")
parts.append(stmt("db/tables/inventory_movements.sql", "CREATE TRIGGER trg_inventory_movements_warehouse_request_freeze\n"))
parts.append(stmt("db/tables/receipt_price_requests.sql", "CREATE TRIGGER trg_receipt_price_requests_warehouse_request_freeze\n"))

# ── 5 · EXECUTE ──────────────────────────────────────────────────────────────
parts.append("\n-- ── 5 · EXECUTE:内层算子从 authenticated 收回(与 zzz_function_grants.sql 同句)────────\n")
for sig in INTERNALS:
    parts.append(f"REVOKE EXECUTE ON FUNCTION public.{sig} FROM PUBLIC, anon, authenticated;\n")
for sig in DOORS:
    parts.append(f"REVOKE EXECUTE ON FUNCTION public.{sig} FROM PUBLIC, anon;\n")

# ── 6 · operations_now ───────────────────────────────────────────────────────
v = mirror("db/views/operations_now.sql")
i = v.index("CREATE VIEW public.operations_now AS")
j = v.index("\n\nGRANT SELECT ON public.operations_now", i)
view = v[i:j].rstrip().rstrip(";") + ";\n"
parts.append("\n-- ── 6 · operations_now:加一支 warehouse_request_pending(镜像原样)──────────────\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 7 · 自证 ─────────────────────────────────────────────────────────────────
a5b = mirror("db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql")
start = a5b.index("CREATE FUNCTION pg_temp.a5b_pending_decider_check")
dec = a5b[start:a5b.index("$f$;", start) + 4].replace("a5b_pending_decider_check", "a7_pending_decider_check")
# Q9:把每一条申请链(fixed_level 有值的那几条)加进 items —— 与 assert_other_decider 同一份判据
anchor = """     WHERE s.status = 'open' AND s.deleted_at IS NULL
)"""
assert dec.count(anchor) == 1
dec = dec.replace(anchor, """     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
)""")
parts.append("\n-- ── 7 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
internal_list = ", ".join(f"'public.{s}'" for s in INTERNALS)
parts.append(f"""
CREATE TEMP TABLE a7_pending_after ON COMMIT DROP AS
{PENDING}
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码,Q8)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a7_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a7_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR7_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR7_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;分录、流水、批次、加工单、证书、留痕一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a7_pending_before b EXCEPT SELECT a.k, a.id FROM a7_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a7_pending_after a EXCEPT SELECT b.k, b.id FROM a7_pending_before b)) THEN
        RAISE EXCEPTION 'APR7_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a7_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'APR7_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM a7_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM warehouse_requests) THEN
        RAISE EXCEPTION 'APR7_PROOF|warehouse_requests is not empty';
    END IF;

    -- ④ 结构:申请表上没有写策略;两支冻结守卫挂上;内层算子 authenticated 调不到;旧的回滚 / 作废门只会拒、
    --    不再调函数体;两扇一步删的门先问"要不要经 CFO";名册一行、只有二级
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename = 'warehouse_requests' AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR7_PROOF|a warehouse_requests write policy exists';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger
     WHERE tgname IN ('trg_inventory_movements_warehouse_request_freeze',
                      'trg_receipt_price_requests_warehouse_request_freeze');
    IF v_n <> 2 THEN RAISE EXCEPTION 'APR7_PROOF|expected 2 freeze triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY[{internal_list}]) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR7_PROOF|authenticated can still execute: %', v_bad; END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.rollback_processing_run(uuid, text)'::regprocedure)
         NOT LIKE '%WAREHOUSE_NEEDS_APPROVED_REQUEST%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.rollback_processing_run(uuid, text)'::regprocedure)
         LIKE '%_internal%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.void_cod(uuid, text)'::regprocedure)
         NOT LIKE '%WAREHOUSE_NEEDS_APPROVED_REQUEST%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.void_cod(uuid, text)'::regprocedure)
         LIKE '%_internal%' THEN
        RAISE EXCEPTION 'APR7_PROOF|an old one-step rollback / void door still does the work';
    END IF;
    IF (SELECT count(*) FROM pg_proc
         WHERE oid IN ('public.soft_delete_inbound_batch(uuid, text)'::regprocedure,
                       'public.soft_delete_output_batch(uuid, text)'::regprocedure)
           AND prosrc LIKE '%batch_write_off_needs_request%') <> 2 THEN
        RAISE EXCEPTION 'APR7_PROOF|a one-step delete door does not ask whether the CFO is needed';
    END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'warehouse_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR7_PROOF|warehouse_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('warehouse_request', 'decide_warehouse_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR7_PROOF|nobody can decide a warehouse request'; END IF;
    RAISE NOTICE 'APR7 deciders for warehouse_request: %', v_n;

    -- ⑥ 每一张在途单据 —— 连同每一条申请链(Q9)—— 都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a7_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR7 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a7_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR7_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a7_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a7_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
