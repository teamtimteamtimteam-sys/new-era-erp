#!/usr/bin/env python3
"""APR-5a:从镜像拼出迁移文件(形状照 build_role1b4b_migration.py / build_role1b3b_migration.py)。镜像是真源,
迁移是它的一次投影 —— 函数、表、策略、触发器、视图都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_apr5a_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql"


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


def dollar_fn(path, head, end="$fn$;"):
    """表镜像里用 $fn$ 包着的函数:从 head 抽到 end(stmt() 不认美元引号)。"""
    s = mirror(path)
    assert s.count(head) == 1, (path, head)
    i = s.index(head)
    j = s.index(end, i) + len(end)
    return s[i:j] + "\n"


HEADER = """-- db/migrations/2026-09-25-apr5a-credit-notes-and-voids-wait-for-the-cfo.sql
-- APR-5a —— 贷项通知与作废发票要 CFO 批准;绕过它的五条直连路关掉(docs/role-matrix.md「贷项通知、作废发票」)。
-- 由 db/scripts/build_apr5a_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-5 grilling Q9–Q11 · Q13 的 invoice_request 那一半,Tim 2026-09-25 全部接受)
--   ① invoice_requests:贷项 / 作废申请。财务提(module.finance.edit),CFO 批每一张、不分档,批准【当场过账】,
--      按提交时冻下来的日期;rejected(要理由)· withdrawn(提单人或 module.finance.edit)。一张发票同时只挂一张。
--      提交按同一支过账试跑(PQ004)。审批关着时生下来就是 approved 并当场过账(auto_approved)。
--      提单人之外没人批得动 → INVOICE_REQUEST_NO_OTHER_DECIDER(assert_other_decider)。
--   ② create_credit_note / void_invoice 变成只会按名拒的门(INVOICE_NEEDS_APPROVED_REQUEST);函数体搬进
--      create_credit_note_internal / void_invoice_internal(EXECUTE 从 authenticated 收回)。
--   ③ 五条直连路(Q11):invoices 与 invoice_lines 的 INSERT / UPDATE 写策略拿掉,直连写按名拒
--      INVOICE_THROUGH_FUNCTION_ONLY;invoice_voided 只许由作废传播写;reverse_journal_entry 拒 invoice /
--      credit_note 分录(JE_REVERSE_USE_SOURCE_PATH);挂着贷项通知的发票不作废(INVOICE_HAS_CREDIT_NOTES)。
--   ④ 发货(Q10):一张在等的作废申请 → INVOICE_VOID_REQUESTED;一条挂在在等的 unshipped_cancel 贷项申请里
--      的发票行 → INVOICE_CREDIT_REQUESTED。收款从不被挡。
--   ⑤ 引擎登记(Q13):approval_chain_gates 一行(二级,module.finance.view + data.view_prices);
--      approval_pending_documents 一支(blocks_disable、fixed_level = 2、主角 NULL);approval_log 的主体类型与
--      读策略各加 invoice_request;record_approval_decision 一支(本位币);operations_now 一支 invoice_request_pending。
--
-- 【不做什么】不新增任何权限码,所以"新码同时授给 admin"那条常设裁定这一刀无码可授;
-- 不碰 role_permissions、user_roles、审批开关与策略;不写任何业务行;不动发货的权限(APR-5b)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;在途单据一张不少、一张不多;approval_log、
-- journal_entries、发票(全部 / 作废)、发票行、贷项通知与行、发货、销售记录一行没变;授权一条没变;申请表是空的;
-- 四条写策略没了、两支守卫挂上、两支旧 enforce_write_permission 没了;两扇门只会拒;新链有人批得了;
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
       (SELECT count(*) FROM invoices) AS invoices_all,
       (SELECT count(*) FROM invoices WHERE status = 'void') AS invoices_void,
       (SELECT count(*) FROM invoice_lines) AS invoice_lines,
       (SELECT count(*) FROM invoice_lines WHERE invoice_voided) AS invoice_lines_voided,
       (SELECT count(*) FROM credit_notes) AS credit_notes,
       (SELECT count(*) FROM credit_note_lines) AS credit_note_lines,
       (SELECT count(*) FROM shipments) AS shipments,
       (SELECT count(*) FROM sales_records) AS sales_records"""

POLICIES = ["invoices insert by permission", "invoices update by permission",
            "invoice_lines insert by permission", "invoice_lines update by permission"]
pol_sql = ", ".join(f"'{p}'" for p in POLICIES)

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR5A_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.invoice_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR5A_PRE|invoice_requests already exists';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND policyname IN ({pol_sql})) <> 4 THEN
        RAISE EXCEPTION 'APR5A_PRE|the four invoice write policies are not all there to drop';
    END IF;
    IF (SELECT count(*) FROM pg_trigger WHERE tgname = 'enforce_write_permission'
         AND tgrelid IN ('public.invoices'::regclass, 'public.invoice_lines'::regclass)) <> 2 THEN
        RAISE EXCEPTION 'APR5A_PRE|the two enforce_write_permission triggers are not both there to replace';
    END IF;
    -- 批的人要持两个门码:cfo 今天持 module.finance.view 与 data.view_prices
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices')) <> 2 THEN
        RAISE EXCEPTION 'APR5A_PRE|cfo does not hold both gate codes';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a5a_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE a5a_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE a5a_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

# ── 1 · 表 ───────────────────────────────────────────────────────────────────
t = mirror("db/tables/invoice_requests.sql")
parts.append("\n-- ── 1 · invoice_requests(镜像原样)──────────────────────────────────────────\n")
parts.append(t[t.index("CREATE TABLE public.invoice_requests"):])

# ── 2 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'invoice_request')),", i) + len("'invoice_request'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 2 · approval_log:主体类型加 invoice_request;读策略加同名一支 ──────────────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 3 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in ["guard_invoice_direct_write", "void_invoice_internal", "create_credit_note_internal",
             "void_invoice", "create_credit_note",
             "invoice_request_post_internal", "invoice_request_dry_run", "invoice_request_submit_internal",
             "submit_credit_note_request", "submit_invoice_void_request",
             "decide_invoice_request", "withdraw_invoice_request",
             "record_approval_decision", "approval_pending_documents", "approval_chain_gates",
             "reverse_journal_entry", "ship_order"]:
    parts.append(fn(name))

# ── 4 · 发票两张表:写策略拿掉,直连写按名拒;invoice_voided 冻住 ───────────────
parts.append("\n-- ── 4 · invoices / invoice_lines:四条写策略拿掉;两支守卫取代 enforce_write_permission ──\n")
for p in POLICIES:
    tbl = p.split(" ")[0]
    parts.append(f'DROP POLICY "{p}" ON public.{tbl};\n')
parts.append("DROP TRIGGER enforce_write_permission ON public.invoices;\n")
parts.append("DROP TRIGGER enforce_write_permission ON public.invoice_lines;\n")
parts.append(stmt("db/tables/invoices.sql", "CREATE TRIGGER trg_invoices_direct_write\n"))
parts.append(stmt("db/tables/invoice_lines.sql", "CREATE TRIGGER trg_invoice_lines_direct_write\n"))
parts.append("\n-- invoice_voided 只许由作废传播写(Q11 ③)—— 行守卫从表镜像原样抽出\n")
parts.append(dollar_fn("db/tables/invoice_lines.sql", "CREATE OR REPLACE FUNCTION public.guard_invoice_line_mutation()"))

# ── 5 · operations_now ───────────────────────────────────────────────────────
v = mirror("db/views/operations_now.sql")
i = v.index("CREATE VIEW public.operations_now AS")
j = v.index("\n\nGRANT SELECT ON public.operations_now", i)
view = v[i:j].rstrip().rstrip(";") + ";\n"
parts.append("\n-- ── 5 · operations_now:加一支 invoice_request_pending(镜像原样)────────────────\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 6 · 自证 ─────────────────────────────────────────────────────────────────
b3b = mirror("db/migrations/2026-09-25-role1b3b-the-warehouse-makes-finance-releases.sql")
start = b3b.index("CREATE FUNCTION pg_temp.b3b_pending_decider_check")
dec = b3b[start:b3b.index("$f$;", start) + 4].replace("b3b_pending_decider_check", "a5a_pending_decider_check")
parts.append("\n-- ── 6 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
parts.append(f"""
CREATE TEMP TABLE a5a_pending_after ON COMMIT DROP AS
{PENDING}
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a5a_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a5a_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR5A_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR5A_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;业务行一行没变;申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a5a_pending_before b EXCEPT SELECT a.k, a.id FROM a5a_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a5a_pending_after a EXCEPT SELECT b.k, b.id FROM a5a_pending_before b)) THEN
        RAISE EXCEPTION 'APR5A_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a5a_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'APR5A_PROOF|a business row count changed: % → %',
            (SELECT row(c.*)::text FROM a5a_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM invoice_requests) THEN
        RAISE EXCEPTION 'APR5A_PROOF|invoice_requests is not empty';
    END IF;

    -- ④ 结构:四条写策略没了、两张表上没有任何写策略;两支守卫挂上、两支旧 enforce_write_permission 没了;
    --    两扇门只会拒;名册一行、只有二级
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('invoices', 'invoice_lines') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR5A_PROOF|an invoice write policy is still there';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE tgname IN ('trg_invoices_direct_write', 'trg_invoice_lines_direct_write');
    IF v_n <> 2 THEN RAISE EXCEPTION 'APR5A_PROOF|expected 2 invoice guard triggers, got %', v_n; END IF;
    IF EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'enforce_write_permission'
                AND tgrelid IN ('public.invoices'::regclass, 'public.invoice_lines'::regclass)) THEN
        RAISE EXCEPTION 'APR5A_PROOF|an old enforce_write_permission trigger is still on an invoice table';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_proc WHERE pronamespace = 'public'::regnamespace
                AND proname IN ('void_invoice', 'create_credit_note')
                AND (prosrc NOT LIKE '%INVOICE_NEEDS_APPROVED_REQUEST%' OR prosrc LIKE '%post_journal_entry%'
                     OR prosrc LIKE '%reverse_journal_entry_internal%')) THEN
        RAISE EXCEPTION 'APR5A_PROOF|a door still does the work itself';
    END IF;
    IF (SELECT prosrc FROM pg_proc WHERE oid = 'public.reverse_journal_entry(uuid, date, text)'::regprocedure)
       NOT LIKE '%''invoice'', ''credit_note''%' THEN
        RAISE EXCEPTION 'APR5A_PROOF|reverse_journal_entry does not refuse invoice / credit_note entries';
    END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'invoice_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR5A_PROOF|invoice_request chain row';
    END IF;

    -- ⑤ 二级这条新链此刻有人批得了(开着的审批不许因为一条新链而变成"开着却没人能批")
    SELECT count(*) INTO v_n FROM approval_deciders('invoice_request', 'decide_invoice_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR5A_PROOF|nobody can decide an invoice request'; END IF;
    RAISE NOTICE 'APR5A deciders for invoice_request: %', v_n;

    -- ⑥ 每一张在途单据,都还有一个【不是它自己当事人】的决定人(Tim 的硬要求)
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a5a_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR5A pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a5a_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR5A_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a5a_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a5a_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
