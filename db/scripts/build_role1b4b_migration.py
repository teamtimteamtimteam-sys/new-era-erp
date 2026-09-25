#!/usr/bin/env python3
"""ROLE-1 Batch 4b:从镜像拼出迁移文件(形状照 build_payrollapr1_migration.py)。理由与 ROLE-1 Batch 2a / 2b 的拼装脚本同一条 ——
镜像是真源,迁移是它的一次投影;手抄两份迟早各说各话。函数、表、策略、触发器、视图都从镜像里
【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_role1b4b_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql"


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
    """从镜像里抽出以 head 开头、到【语句真正的结尾】为止的那一句。
    ★ 不能是"下一个分号":approval_log 那条读策略的【注释】里就有一个全角之外的半角分号,
    第一版照"下一个分号"切,切在注释中间 —— psql 把那个分号当成注释的一部分,语句于是永远没有结尾,
    后面整支迁移被吞进同一句,apply 在函数授权兜底那一步才报错(整笔回滚,线上未动)。
    所以这里逐字扫:跳过 -- 行注释与单引号字符串,只认它们之外的那个分号。"""
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


HEADER = """-- db/migrations/2026-09-25-role1b4b-receipt-pricing-waits-for-the-cfo.sql
-- ROLE-1 Batch 4b —— 收货定价要 CFO 批准:一个价格只有 CFO 批了才进账(docs/role-matrix.md「收货定价与改价」)。
-- 由 db/scripts/build_role1b4b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(ROLE-1 Batch 4 grilling Q2–Q8 + Batch 4b grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   ① receipt_price_requests:收货定价申请。submitted → approved(CFO 批准【当场过账】,记在批准日、
--      按那天的 tt_sell)· rejected(要理由)· withdrawn。冻结原币单价;提交与批准各按同一支过账试跑。
--      审批关着时生下来就是 approved 并当场过账(auto_approved)。
--   ② 四扇门变成提交:定价面板(set_inbound_unit_price)· 按已承诺条款改价(reprice_from_committed_terms)·
--      收货台带价建单(create_inbound_batch,同一事务)· 应用化验(apply_assay_result,含量等照旧全部
--      落地,同一事务提一张来源 assay 的申请;pricing_status 的 final 只在批准时置)。
--   ③ 等待期间冻住(Q5):改供应商 / 采购单 / 采购行 / 含量、注销、第二张申请 → RECEIPT_PRICE_REQUEST_OPEN;
--      批准时指纹再比 → RECEIPT_PRICE_CHANGED_SINCE_REQUEST。手工申请在等时应用化验按名拒;化验申请在等时,
--      新化验取代它(撤回并记下理由)。撤销应用化验撤回它那一张。
--   ④ 低于已付(Q6):提交与批准各按当天的牌价比 → RECEIPT_PRICE_BELOW_SETTLED。
--   ⑤ 提单人之外没人批得动(4b Q1):审批开着时提交按名拒 RECEIPT_PRICE_NO_OTHER_DECIDER。
--   ⑥ pricing_status 只经函数写(4b Q3):直连写 → PRICING_STATUS_VIA_FUNCTION。
--   ⑦ 引擎登记(Q8):approval_chain_gates 一行(二级,module.inbound.view + data.view_purchase_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);approval_log 的主体类型与
--      读策略各加 receipt_price_request;record_approval_decision 一支(金额 = |Δ 应付| 本位币);
--      operations_now 一支 receipt_price_request_pending(data.view_purchase_prices)。
--
-- 【不做什么】不新增任何权限码,所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行;引擎 reprice_inbound_batch 一个字不改。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;
-- approval_log、journal_entries、price_history、收货(已定价 / 全部 / 各定价状态)、含量行、已应用化验一行没变;
-- 授权一条没变;申请表是空的;新链有人批得了;每一张在途单据都还有一个【不是它自己当事人】的决定人。
-- 断言失败 = 整笔回滚。

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
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')"""

parts = [HEADER]

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM price_history) AS price_history,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM inbound_batches WHERE pricing_status = 'final') AS receipts_final,
       (SELECT count(*) FROM inbound_batch_metals) AS metal_rows,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied"""

parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B4B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.receipt_price_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'ROLE1B4B_PRE|receipt_price_requests already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname IN ('trg_inbound_batches_price_request',
                                                        'trg_inbound_batch_metals_price_request')) THEN
        RAISE EXCEPTION 'ROLE1B4B_PRE|a ROLE-1 Batch 4b trigger already exists';
    END IF;
    IF has_function_privilege('authenticated', 'public.reprice_inbound_batch(uuid, numeric, text, numeric, text)', 'EXECUTE') THEN
        RAISE EXCEPTION 'ROLE1B4B_PRE|the engine is expected closed to authenticated (Batch 4a)';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b4b_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE b4b_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE b4b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

# ── 1 · 表 ───────────────────────────────────────────────────────────────────
t = mirror("db/tables/receipt_price_requests.sql")
parts.append("\n-- ── 1 · receipt_price_requests(镜像原样)────────────────────────────────────\n")
parts.append(t[t.index("CREATE TABLE public.receipt_price_requests"):])

# ── 2 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'receipt_price_request')),", i) + len("'receipt_price_request'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 2 · approval_log:主体类型加 receipt_price_request;读策略加同名一支 ──────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 3 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["receipt_price_fingerprint", "receipt_price_open", "receipt_settled_base",
             "receipt_price_post_internal", "receipt_price_request_dry_run", "receipt_price_withdraw_internal",
             "receipt_price_submit_internal", "decide_receipt_price_request", "withdraw_receipt_price_request",
             "set_inbound_unit_price", "reprice_from_committed_terms", "create_inbound_batch",
             "apply_assay_result", "unapply_assay_result", "soft_delete_inbound_batch",
             "record_approval_decision", "approval_pending_documents", "approval_chain_gates",
             "guard_inbound_batch_price_request", "guard_inbound_batch_metals_price_request"]:
    parts.append(fn(name))

# ── 4 · 两支守卫的触发器 ──────────────────────────────────────────────────────
parts.append("\n-- ── 4 · 守卫(Q5 · 4b Q3):两张表各一支 BEFORE 行级守卫 ─────────────────────────\n")
parts.append(stmt("db/tables/inbound_batches.sql", "CREATE TRIGGER trg_inbound_batches_price_request\n"))
parts.append(stmt("db/tables/inbound_batch_metals.sql", "CREATE TRIGGER trg_inbound_batch_metals_price_request\n"))

# ── 5 · operations_now ───────────────────────────────────────────────────────
v = mirror("db/views/operations_now.sql")
i = v.index("CREATE VIEW public.operations_now AS")
j = v.index("\n\nGRANT SELECT ON public.operations_now", i)
view = v[i:j].rstrip().rstrip(";") + ";\n"
parts.append("\n-- ── 5 · operations_now:加一支 receipt_price_request_pending(镜像原样)──────────\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 6 · 自证 ─────────────────────────────────────────────────────────────────
b1 = mirror("db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql")
start = b1.index("CREATE FUNCTION pg_temp.role1_pending_decider_check")
dec = b1[start:b1.index("$f$;", start) + 4].replace("role1_pending_decider_check", "b4b_pending_decider_check")
parts.append("\n-- ── 6 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE b4b_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM b4b_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM b4b_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B4B_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM b4b_pending_before b EXCEPT SELECT a.k, a.id FROM b4b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b4b_pending_after a EXCEPT SELECT b.k, b.id FROM b4b_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM b4b_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM b4b_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM receipt_price_requests) THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|receipt_price_requests is not empty';
    END IF;

    -- ④ 结构:两支守卫挂上;链的名册一行、只有二级;内层算子 authenticated 调不到(zzz 重放之前,
    --    这里先看函数本身 —— 重放在本文件之后由 apply_migration.sh 做,自证只断言守卫与名册)
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_inbound_batches_price_request',
                                                             'trg_inbound_batch_metals_price_request');
    IF v_n <> 2 THEN RAISE EXCEPTION 'ROLE1B4B_PROOF|expected 2 guard triggers, got %', v_n; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'receipt_price_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|receipt_price_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('receipt_price_request', 'decide_receipt_price_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'ROLE1B4B_PROOF|nobody can decide a receipt price request'; END IF;
    RAISE NOTICE 'ROLE1B4B deciders for receipt_price_request: %', v_n;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b4b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B4B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b4b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B4B_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b4b_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b4b_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
