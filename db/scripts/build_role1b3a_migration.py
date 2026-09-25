#!/usr/bin/env python3
"""ROLE-1 Batch 3a:从镜像拼出迁移文件(形状照 build_role1b4b_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数、表、策略、触发器都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_role1b3a_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql"
NEW_CODES = ["action.stocktake_count", "action.stocktake_post"]


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
    """从镜像里抽出以 head 开头、到【语句真正的结尾】为止的那一句(跳过 -- 注释与单引号字符串,
    只认它们之外的分号 —— PAYROLL-APR-1 那一次栽在"下一个分号"上)。"""
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


HEADER = """-- db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql
-- ROLE-1 Batch 3a —— 盘点录数归仓库、过账归财务,录过数的人永远不能过账;四个登记的缺口关上。
-- 由 db/scripts/build_role1b3a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(ROLE-1 Batch 3 grilling,Tim 2026-09-25:Q2–Q5 · Q10–Q13 全部接受;Q13 拆刀,本刀是 3a)
--   ① 两个新码:action.stocktake_count(开单与录数)→ warehouse · admin;action.stocktake_post(过账)→ finance · admin。
--      module.stocktakes.edit 改义:只剩取消盘点(描述改写)。★ 两个新码都一并授给 admin(Tim 的常设裁定)。
--   ② stocktake_counts:每一次录数与重录,连同录数的人 —— 只增不改;counted_by 由函数写。
--   ③ 盘点三张表没有直连写:stocktakes / stocktake_lines 的 INSERT / UPDATE 策略拿掉,直连 INSERT / UPDATE 按名拒
--      STOCKTAKE_THROUGH_FUNCTION_ONLY;开单 open_stocktake、录数 record_stocktake_count(新,SECURITY DEFINER)。
--   ④ post_stocktake:门换成 action.stocktake_post;开单人那条腿不变;新加录数人那条腿(按人认)
--      STOCKTAKE_COUNTER_CANNOT_POST|单号。
--   ⑤ 缺口 1(Q5):inbound_batch_landed_unit_cost 拿掉 module.stocktakes.edit 那一支;batch_freight_base 与
--      batch_processing_cost_base 先问 data.view_prices(不持的人读 NULL);allocate_processing_costs 改读 _all ——
--      【算一笔要过账的钱不许问权限】,分摊不再靠分摊人碰巧看得见。
--   ⑥ 缺口 2(Q10):assay_results.is_final 直连改 → ASSAY_FINAL_THROUGH_FUNCTION_ONLY。
--   ⑦ 缺口 3(Q11):已定价的收货改供应商 / 采购单 / 采购行 → RECEIPT_PRICED_SOURCE_FROZEN|收货(不分直连与属主路径)。
--   ⑧ 缺口 4 与 Q12:assert_other_decider(新)—— 审批开着、提单人之外二级没人批得动时按名拒;
--      submit_payroll_request(PAYROLL_NO_OTHER_DECIDER|工资期)与六支付款申请提交(PAYMENT_REQUEST_NO_OTHER_DECIDER)调它。
--
-- 【不做什么】不碰审批开关与策略、user_roles、任何业务行;不动工单、加工提交、回滚、注销批次、收货建单(那是 3b)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权 = 之前 + 裁定的那四行,一行不少、一行不多;
-- 新码的持有人正好是裁定的那几个角色;在途单据一张不少、一张不多;approval_log、journal_entries、盘点单与盘点行、
-- 收货(已定价 / 全部)、化验(正式 / 已应用)一行没变;stocktake_counts 是空的;直连写策略没了、守卫挂上;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

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
       (SELECT count(*) FROM stocktakes) AS stocktakes,
       (SELECT count(*) FROM stocktake_lines) AS stocktake_lines,
       (SELECT count(*) FROM inbound_batches WHERE unit_price IS NOT NULL) AS receipts_priced,
       (SELECT count(*) FROM inbound_batches) AS receipts_all,
       (SELECT count(*) FROM assay_results WHERE is_final) AS assays_final,
       (SELECT count(*) FROM assay_results WHERE applied_at IS NOT NULL) AS assays_applied,
       (SELECT count(*) FROM payment_requests) AS payment_requests,
       (SELECT count(*) FROM payroll_requests) AS payroll_requests"""

RULED = ["warehouse:action.stocktake_count", "admin:action.stocktake_count",
         "finance:action.stocktake_post", "admin:action.stocktake_post"]

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.stocktake_count', 'action.stocktake_post')) THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|new codes already exist';
    END IF;
    IF to_regclass('public.stocktake_counts') IS NOT NULL THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|stocktake_counts already exists';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND policyname IN ('stocktakes insert by permission', 'stocktakes update by permission',
                            'stocktake_lines insert by permission', 'stocktake_lines update by permission')) <> 4 THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|the four stocktake write policies are not all there to drop';
    END IF;
    -- 在途盘点上没有行 —— 没有"谁数过"要回填(Step 0 实测 5 张都是 0 行;不假设,问一遍)
    IF EXISTS (SELECT 1 FROM stocktake_lines l JOIN stocktakes s ON s.id = l.stocktake_id
                WHERE s.status = 'open' AND s.deleted_at IS NULL) THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|an open stocktake has lines — who counted them would have to be backfilled';
    END IF;
    -- 过账要读得到盘点单:finance 今天持 module.stocktakes.view
    IF NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                    WHERE r.code = 'finance' AND rp.permission_code = 'module.stocktakes.view') THEN
        RAISE EXCEPTION 'ROLE1B3A_PRE|finance does not hold module.stocktakes.view';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE b3a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE b3a_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE b3a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:两个新码;module.stocktakes.edit 的描述改写 ──────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
""")
perm = mirror("db/tables/permissions.sql")
rows = [l.strip().rstrip(",;") for l in perm.splitlines() if l.strip().startswith(tuple(f"('{c}'" for c in NEW_CODES))]
assert len(rows) == 2, rows
parts.append("    " + ",\n    ".join(rows) + ";\n")
line = [l for l in perm.splitlines() if l.strip().startswith("('module.stocktakes.edit'")]
assert len(line) == 1
m = re.match(r"\s*\('[^']+', '[^']+', '((?:[^']|'')*)', '((?:[^']|'')*)', '((?:[^']|'')*)', '((?:[^']|'')*)', (\d+)\),?$", line[0])
assert m, line
parts.append(f"UPDATE public.permissions SET name_en = '{m.group(1)}', name_zh = '{m.group(2)}',\n"
             f"       description_en = '{m.group(3)}', description_zh = '{m.group(4)}'\n"
             f" WHERE code = 'module.stocktakes.edit';\n")

parts.append("""
-- ── 2 · 授权(在函数之前:下面的自证要问到它们)────────────────────────────────
-- 录数归仓库、过账归财务;admin 两个都拿(Tim 的常设裁定)。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES ('warehouse', 'action.stocktake_count'), ('admin', 'action.stocktake_count'),
               ('finance', 'action.stocktake_post'), ('admin', 'action.stocktake_post')) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

parts.append("\n-- ── 3 · 守卫函数与断言(新;表与触发器要用到它们)─────────────────────────────\n")
for name in ["guard_stocktake_direct_write", "guard_stocktake_count_append_only", "assert_other_decider"]:
    parts.append(fn(name))

t = mirror("db/tables/stocktake_counts.sql")
parts.append("\n-- ── 4 · stocktake_counts(镜像原样)──────────────────────────────────────────\n")
parts.append(t[t.index("CREATE TABLE public.stocktake_counts"):])

parts.append("""
-- ── 5 · 盘点两张表:直连写策略拿掉,直连 INSERT / UPDATE 按名拒 ─────────────────
DROP POLICY "stocktakes insert by permission" ON public.stocktakes;
DROP POLICY "stocktakes update by permission" ON public.stocktakes;
DROP POLICY "stocktake_lines insert by permission" ON public.stocktake_lines;
DROP POLICY "stocktake_lines update by permission" ON public.stocktake_lines;
""")
parts.append(stmt("db/tables/stocktakes.sql", "CREATE TRIGGER trg_stocktakes_direct_write\n"))
parts.append(stmt("db/tables/stocktake_lines.sql", "CREATE TRIGGER trg_stocktake_lines_direct_write\n"))

parts.append("\n-- ── 6 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["open_stocktake", "record_stocktake_count", "post_stocktake",
             "inbound_batch_landed_unit_cost", "batch_freight_base", "batch_processing_cost_base",
             "allocate_processing_costs",
             "guard_assay_applied_columns", "guard_inbound_batch_price_request",
             "submit_payroll_request",
             "submit_payment_request", "submit_payment_reversal_request",
             "submit_bank_transfer_request", "submit_bank_transfer_reversal_request",
             "submit_wht_remittance_request", "submit_wht_remittance_reversal_request"]:
    parts.append(fn(name))

# ── 7 · 自证 ─────────────────────────────────────────────────────────────────
b1 = mirror("db/migrations/2026-09-23-role1a-the-matrix-batch-1.sql")
start = b1.index("CREATE FUNCTION pg_temp.role1_pending_decider_check")
dec = b1[start:b1.index("$f$;", start) + 4].replace("role1_pending_decider_check", "b3a_pending_decider_check")
old_st = """      LEFT JOIN holds h ON 'module.stocktakes.edit' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'"""
assert dec.count(old_st) == 1
dec = dec.replace(old_st, """      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')""")
parts.append("\n-- ── 7 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
ruled_sql = ", ".join(f"'{r}'" for r in RULED)
parts.append(f"""
CREATE TEMP TABLE b3a_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 裁定的那四行,一行不少、一行不多
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT (SELECT role_code || ':' || permission_code FROM b3a_grants_before
                 UNION SELECT unnest(ARRAY[{ruled_sql}])))
        UNION ALL
        ((SELECT role_code || ':' || permission_code FROM b3a_grants_before
          UNION SELECT unnest(ARRAY[{ruled_sql}]))
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'ROLE1B3A_PROOF|grants differ from before + ruled: %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.stocktake_count';
    IF v_bad IS DISTINCT FROM 'admin warehouse' THEN RAISE EXCEPTION 'ROLE1B3A_PROOF|stocktake_count holders are %', v_bad; END IF;
    SELECT string_agg(r.code, ' ' ORDER BY r.code) INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE rp.permission_code = 'action.stocktake_post';
    IF v_bad IS DISTINCT FROM 'admin finance' THEN RAISE EXCEPTION 'ROLE1B3A_PROOF|stocktake_post holders are %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变;"谁数过"是空的
    IF EXISTS ((SELECT b.k, b.id FROM b3a_pending_before b EXCEPT SELECT a.k, a.id FROM b3a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM b3a_pending_after a EXCEPT SELECT b.k, b.id FROM b3a_pending_before b)) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM b3a_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM b3a_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM stocktake_counts) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|stocktake_counts is not empty';
    END IF;

    -- ④ 结构:直连写策略没了;三支直连写守卫 + 只增不改守卫挂上;到岸成本判据里没有盘点码了
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('stocktakes', 'stocktake_lines')
                AND cmd IN ('INSERT', 'UPDATE')) THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|a stocktake write policy is still there';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_stocktakes_direct_write', 'trg_stocktake_lines_direct_write',
                                                             'trg_stocktake_counts_direct_write', 'trg_stocktake_counts_append_only');
    IF v_n <> 4 THEN RAISE EXCEPTION 'ROLE1B3A_PROOF|expected 4 stocktake guard triggers, got %', v_n; END IF;
    IF pg_get_functiondef('public.inbound_batch_landed_unit_cost(uuid)'::regprocedure) LIKE '%has_permission(''module.stocktakes.edit''%' THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|landed cost still lets module.stocktakes.edit through';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.post_stocktake(uuid)'::regprocedure) NOT LIKE '%require_permission(''action.stocktake_post'')%' THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|post_stocktake is not gated on action.stocktake_post';
    END IF;

    -- ⑤ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.b3a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'ROLE1B3A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.b3a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'ROLE1B3A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.b3a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.b3a_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
