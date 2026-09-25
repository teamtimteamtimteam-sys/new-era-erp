#!/usr/bin/env python3
"""APR-5b:从镜像拼出迁移文件(形状照 build_apr5a_migration.py / build_role1b3b_migration.py)。镜像是真源,
迁移是它的一次投影 —— 函数、表、策略、视图都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_apr5b_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql"
NEW_CODES = ["action.request_shipping_release", "action.ship_goods"]
RULED = ["cco:action.request_shipping_release", "admin:action.request_shipping_release",
         "warehouse:action.ship_goods", "admin:action.ship_goods"]


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


HEADER = """-- db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql
-- APR-5b —— 发货前 CFO 放行;仓库照放行、在一页不带价格的队列里发货(docs/role-matrix.md §10「发货」)。
-- 由 db/scripts/build_apr5b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-5 grilling Q2–Q8 · Q13;5b grilling Q1–Q12,Tim 2026-09-25 全部接受)
--   ① 两个新码,都一并授给 admin(Tim 的常设裁定):
--      action.request_shipping_release → cco(提放行)· action.ship_goods → warehouse(发货、开发货单)。
--      cco 从此不发货(ship_order / record_shipment_issue 的门换成 action.ship_goods);仓库【不】拿 module.sales.view。
--   ② shipping_releases + shipping_release_lines:submitted → approved(CFO,批准就是放行)· rejected(要理由)·
--      withdrawn(提单人或持提单码的人)。点名已开票的发票行;覆盖 = approved 且发票行未作废(作废自动失效)。
--      一张订单同时只挂一张 submitted;已覆盖的行不许再点名。审批关着时生下来就是 approved(auto_approved)。
--      提单人之外没人批得动 → SHIPPING_RELEASE_NO_OTHER_DECIDER。
--   ③ ship_order:门 action.ship_goods;发货那一刻客户冻结 → SO_SHIP_CUSTOMER_ON_HOLD(Q6);没有放行覆盖 →
--      SO_SHIP_NOT_RELEASED(Q3);超过 开票 − 未发货取消的数量 − 已发 → SO_SHIP_EXCEEDS_RELEASABLE(Q8);
--      部分发货改调 release_reservation_internal;返回值里没有任何金额(5b Q5)。
--      release_reservation / reserve_stock 的函数体搬进 *_internal(对 authenticated 收权,apply_migration.sh
--      重放 zzz_function_grants)。天花板的唯一推导:sales_order_line_releasable_all(基视图,收权)。
--   ④ 贷项申请:未发货取消提交时必带数量(CN_UNSHIPPED_CANCEL_QTY_REQUIRED · …_EXCEEDS,5b Q1)。
--   ⑤ 读者:shipping_release_context(CFO,门 module.sales.view + data.view_prices)· shipping_queue_rows
--      (仓库,门 action.ship_goods,没有价格,带送货地址 —— Tim 5b Q6)· shipment_document(发货单,
--      module.sales.view 或 action.ship_goods)。三张发货表的读策略放宽到 module.sales.view 或 action.ship_goods(Q7)。
--   ⑥ 引擎登记(Q13):approval_chain_gates 一行(二级,module.sales.view + data.view_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);approval_log 的主体类型与
--      读策略各加 shipping_release;record_approval_decision 一支;operations_now 两支
--      (shipping_release_pending · shipping_release_ready)。forbid_self_approval 按人认;self_approval_exception 不动。
--
-- 【不做什么】不碰审批开关与策略、user_roles、任何业务行;不改集装箱挂发货单的门(5b Q9,登记);
-- 不改 APR5-PARTIALLY-SHIPPED-HAS-NO-EXIT(登记着)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权 = 之前 + 裁定的那四行;两个新码的持有人
-- 正好是裁定的角色;在途单据一张不少、一张不多;approval_log、journal_entries、发货、发货行、预留、销售记录、
-- 发票、贷项一行没变;两张新表是空的;三条发货读策略放宽了;两扇门换了码;新链有人批得了;
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
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM shipment_lines) AS shipment_lines,
       (SELECT count(*) FROM shipment_issues) AS shipment_issues,
       (SELECT count(*) FROM sales_order_reservations) AS reservations,
       (SELECT count(*) FROM sales_order_reservations WHERE released_at IS NULL AND consumed_at IS NULL) AS reservations_live,
       (SELECT count(*) FROM sales_records) AS sales_records,
       (SELECT count(*) FROM sales_orders) AS sales_orders,
       (SELECT count(*) FROM invoices) AS invoices,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM invoice_requests) AS invoice_requests"""

SHIP_TABLES = ["shipments", "shipment_lines", "shipment_issues"]

parts = [HEADER]
codes_sql = ", ".join(f"'{c}'" for c in NEW_CODES)
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR5B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.shipping_releases') IS NOT NULL OR to_regclass('public.shipping_release_lines') IS NOT NULL
       OR to_regclass('public.sales_order_line_releasable_all') IS NOT NULL THEN
        RAISE EXCEPTION 'APR5B_PRE|a 5b relation already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ({codes_sql})) THEN
        RAISE EXCEPTION 'APR5B_PRE|new codes already exist';
    END IF;
    -- 批的人要持两个门码:cfo 今天持 module.sales.view 与 data.view_prices
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.sales.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR5B_PRE|cfo does not hold both gate codes';
    END IF;
    -- Q7:仓库【不】拿 module.sales.view —— 今天它就不持
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                WHERE r.code = 'warehouse' AND rp.permission_code = 'module.sales.view') THEN
        RAISE EXCEPTION 'APR5B_PRE|warehouse unexpectedly holds module.sales.view';
    END IF;
    -- 发货读策略今天是 module.sales.view 一个码(Step 0 读过)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public'
         AND tablename IN ('shipments', 'shipment_lines', 'shipment_issues') AND cmd = 'SELECT'
         AND qual = 'has_permission(''module.sales.view''::text)') <> 3 THEN
        RAISE EXCEPTION 'APR5B_PRE|the three shipment read policies are not what Step 0 read';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a5b_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE a5b_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE a5b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;

-- ── 1 · 目录:两个新码 ─────────────────────────────────────────────────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
""")
perm = mirror("db/tables/permissions.sql")
rows = [l.strip().rstrip(",;") for l in perm.splitlines() if l.strip().startswith(tuple(f"('{c}'" for c in NEW_CODES))]
assert len(rows) == 2, rows
parts.append("    " + ",\n    ".join(rows) + ";\n")

values = ",\n               ".join(f"('{r.split(':')[0]}', '{r.split(':')[1]}')" for r in RULED)
parts.append(f"""
-- ── 2 · 授权(在函数之前:下面的自证要问到它们)────────────────────────────────
-- cco 提放行、仓库发货;admin 两个都拿(Tim 的常设裁定)。幂等。
INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES {values}) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

# ── 3 · 表 ───────────────────────────────────────────────────────────────────
for t in ["shipping_releases", "shipping_release_lines"]:
    s = mirror(f"db/tables/{t}.sql")
    parts.append(f"\n-- ── 3 · {t}(镜像原样)──────────────────────────────────────────\n")
    parts.append(s[s.index(f"CREATE TABLE public.{t}"):])

# ── 4 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'shipping_release')),", i) + len("'shipping_release'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 4 · approval_log:主体类型加 shipping_release;读策略加同名一支 ──────────────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 5 · 天花板的基视图 ─────────────────────────────────────────────────────────
v = mirror("db/views/sales_order_line_releasable_all.sql")
parts.append("\n-- ── 5 · sales_order_line_releasable_all(镜像原样)──────────────────────────\n")
parts.append(v[v.index("CREATE VIEW public.sales_order_line_releasable_all"):])

# ── 6 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 6 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["reserve_stock_internal", "release_reservation_internal", "reserve_stock", "release_reservation",
             "submit_shipping_release", "decide_shipping_release", "withdraw_shipping_release",
             "shipping_release_context", "shipping_queue_rows", "shipment_document",
             "ship_order", "record_shipment_issue", "invoice_request_submit_internal",
             "record_approval_decision", "approval_pending_documents", "approval_chain_gates"]:
    parts.append(fn(name))

# ── 7 · 三张发货表的读策略 ─────────────────────────────────────────────────────
parts.append("\n-- ── 7 · 发货三张表:读策略放宽到 module.sales.view 或 action.ship_goods(5b Q7)──────\n")
for t in SHIP_TABLES:
    parts.append(f'DROP POLICY "{t} select by permission" ON public.{t};\n')
    parts.append(stmt(f"db/tables/{t}.sql", f'CREATE POLICY "{t} select by permission"'))

# ── 8 · operations_now ───────────────────────────────────────────────────────
v = mirror("db/views/operations_now.sql")
i = v.index("CREATE VIEW public.operations_now AS")
j = v.index("\n\nGRANT SELECT ON public.operations_now", i)
view = v[i:j].rstrip().rstrip(";") + ";\n"
parts.append("\n-- ── 8 · operations_now:加两支 shipping_release_pending · shipping_release_ready(镜像原样)──\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 9 · 自证 ─────────────────────────────────────────────────────────────────
a5a = mirror("db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql")
start = a5a.index("CREATE FUNCTION pg_temp.a5a_pending_decider_check")
dec = a5a[start:a5a.index("$f$;", start) + 4].replace("a5a_pending_decider_check", "a5b_pending_decider_check")
ruled_sql = ", ".join(f"'{r}'" for r in RULED)
parts.append("\n-- ── 9 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE a5b_pending_after ON COMMIT DROP AS
{PENDING}
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权 = 之前 + 裁定的那四行(不多、不少、不收回任何一行)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT (SELECT role_code || ':' || permission_code FROM a5b_grants_before
                 UNION SELECT unnest(ARRAY[{ruled_sql}])))
        UNION ALL
        ((SELECT role_code || ':' || permission_code FROM a5b_grants_before
          UNION SELECT unnest(ARRAY[{ruled_sql}]))
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR5B_PROOF|grants differ from before + ruled: %', v_bad; END IF;
    IF (SELECT string_agg(r.code, ' ' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.request_shipping_release') IS DISTINCT FROM 'admin cco'
       OR (SELECT string_agg(r.code, ' ' ORDER BY r.code) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE rp.permission_code = 'action.ship_goods') IS DISTINCT FROM 'admin warehouse' THEN
        RAISE EXCEPTION 'APR5B_PROOF|new code holders are not exactly the ruled roles';
    END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR5B_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变;两张新表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a5b_pending_before b EXCEPT SELECT a.k, a.id FROM a5b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a5b_pending_after a EXCEPT SELECT b.k, b.id FROM a5b_pending_before b)) THEN
        RAISE EXCEPTION 'APR5B_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a5b_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'APR5B_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM a5b_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM shipping_releases) OR EXISTS (SELECT 1 FROM shipping_release_lines) THEN
        RAISE EXCEPTION 'APR5B_PROOF|the release tables are not empty';
    END IF;

    -- ④ 结构:两扇门换了码;三条发货读策略放宽;名册一行、只有二级
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.ship_order(uuid, date, jsonb)'::regprocedure)
         NOT LIKE '%require_permission(''action.ship_goods'')%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.ship_order(uuid, date, jsonb)'::regprocedure)
         LIKE '%require_permission(''module.sales.edit'')%'
       OR (SELECT prosrc FROM pg_proc WHERE oid = 'public.record_shipment_issue(uuid, text, text)'::regprocedure)
         NOT LIKE '%require_permission(''action.ship_goods'')%' THEN
        RAISE EXCEPTION 'APR5B_PROOF|ship_order / record_shipment_issue are not gated on action.ship_goods alone';
    END IF;
    SELECT count(*) INTO v_n FROM pg_policies WHERE schemaname = 'public'
       AND tablename IN ('shipments', 'shipment_lines', 'shipment_issues') AND cmd = 'SELECT'
       AND qual LIKE '%module.sales.view%' AND qual LIKE '%action.ship_goods%';
    IF v_n <> 3 THEN RAISE EXCEPTION 'APR5B_PROOF|expected 3 widened shipment read policies, got %', v_n; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'shipping_release')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR5B_PROOF|shipping_release chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('shipping_release', 'decide_shipping_release', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR5B_PROOF|nobody can decide a shipping release'; END IF;
    RAISE NOTICE 'APR5B deciders for shipping_release: %', v_n;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a5b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR5B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a5b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR5B_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a5b_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a5b_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
