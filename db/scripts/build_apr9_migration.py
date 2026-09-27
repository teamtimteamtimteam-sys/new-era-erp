#!/usr/bin/env python3
"""APR-9:从镜像拼出迁移文件(形状照 build_apr8_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数、表、策略、触发器、视图都从镜像里【原样抽出】,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_apr9_migration.py(在仓库根目录)。"""
import pathlib

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql"


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


HEADER = """-- db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql
-- APR-9 —— 调薪与固定资产处置:批准之前什么都不生效
-- (docs/role-matrix.md「调薪 | 只经绩效评估或调薪申请 | CFO」·「处置 | 财务 | CFO」)。
-- 由 db/scripts/build_apr9_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(APR-9 grilling Q1–Q10,Tim 2026-09-27 全部接受)
--   ① 绩效评估的侧门(Q1):Step 0 以 sandra@ 在回滚的事务里实测 —— cco 直连插一张 submitted_by = CFO 的已提交评估、
--      自己批掉,别人的月薪就改了。守卫 guard_performance_review_write:直连只许建草稿;生命周期列只经函数;
--      提交之后调薪两列、转正结论、被评估人冻结。评估只改已有的月薪(SALARY_NOT_SET_USE_INITIAL)。
--   ② 调薪申请(Q2–Q6):salary_change_requests。财务提(module.hr.edit + data.view_pay,不许给自己提);
--      CFO 批,CFO 这个人是当事人时 cco 批 —— pay_decision_code 一份判据,review_approval_code 委托给它;
--      不看审批开关,永远等人批;生效日提交与批准各判一次;一个人一次在途调薪(跨评估);fingerprint 再比。
--      不进 approval_chain_gates(按人路由);进 approval_pending_documents(blocks_disable = false)。
--   ③ 处置申请(Q7–Q10):asset_disposal_requests,APR-7 的形状。财务提,CFO 批每一张;处置日 = 批准日,
--      按那一刻的活数过账;收款与银行科目提交时冻结;在等的时候卡上的价值列冻结(guard_asset_disposal_freeze);
--      dispose_fixed_asset 只会按名拒(ASSET_DISPOSAL_NEEDS_REQUEST),原函数体搬进 dispose_fixed_asset_internal。
--   ④ 处置分录挪进"走源路径"(Q9):journal_entry_reversal_route 认 asset_disposal 为 source_path。
--   ⑤ 引擎:approval_chain_gates 一行(处置,二级);approval_pending_documents 两支;approval_log 两个主体类型与
--      读策略两支;record_approval_decision 两支;operations_now 两支。
--
-- 【不做什么】不新增任何权限码 —— "新码同时授给 admin"那条常设裁定这一刀无码可授;不碰 role_permissions、user_roles、
-- 审批开关与策略;不写任何业务行。第一份月薪(set_initial_salary)照 ROLE-1 Batch 1 留下的样子不动。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一条没变;在途单据一张不少、一张不多;
-- 留痕、分录、资产、月薪、履历、评估一行没变;两张申请表是空的、没有写策略;两支守卫挂上;内层算子 authenticated 调不到;
-- 处置链二级有人批;调薪链对每一名在职员工、由每一个真能提单的人提,都还有一个不是当事人的决定人;
-- review_approval_code 与 pay_decision_code 逐对相等;每一张在途单据都还有一个【不是它自己当事人】的决定人。
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
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM fixed_assets) AS assets,
       (SELECT count(*) FROM fixed_assets WHERE status = 'disposed') AS assets_disposed,
       (SELECT round(sum(cost_base), 2) FROM fixed_assets) AS asset_cost,
       (SELECT count(*) FROM fixed_asset_depreciation) AS depreciation_rows,
       (SELECT count(*) FROM employees WHERE monthly_salary IS NOT NULL) AS salaries_set,
       (SELECT md5(COALESCE(string_agg(id::text || ':' || monthly_salary::text, ',' ORDER BY id), ''))
          FROM employees WHERE monthly_salary IS NOT NULL) AS salary_digest,
       (SELECT count(*) FROM employment_history) AS employment_history,
       (SELECT count(*) FROM performance_reviews) AS reviews"""

INTERNALS = ["salary_change_execute_internal(uuid)", "salary_change_fingerprint(uuid)", "salary_change_open(uuid)",
             "salary_change_deciders(uuid, uuid)", "salary_effective_period_block(date)", "pay_decision_code(uuid, uuid)",
             "asset_disposal_execute_internal(uuid)", "asset_disposal_dry_run(uuid)", "asset_disposal_fingerprint(uuid)",
             "dispose_fixed_asset_internal(uuid, date, numeric, text, text)"]

DOORS = ["submit_salary_change_request(uuid, numeric, date, text)",
         "decide_salary_change_request(uuid, boolean, text)", "withdraw_salary_change_request(uuid, text)",
         "salary_change_requests_visible(uuid, integer)",
         "submit_asset_disposal_request(uuid, numeric, text, text)",
         "decide_asset_disposal_request(uuid, boolean, text)", "withdraw_asset_disposal_request(uuid, text)",
         "asset_disposal_requests_visible(uuid, integer)",
         "guard_performance_review_write()", "guard_asset_disposal_freeze()"]

GUARDS = ["trg_performance_reviews_guard_write", "trg_fixed_assets_disposal_freeze"]

FUNCTIONS = ["pay_decision_code", "review_approval_code", "salary_effective_period_block", "salary_change_fingerprint",
             "salary_change_open", "salary_change_deciders", "salary_change_execute_internal",
             "submit_salary_change_request", "decide_salary_change_request", "withdraw_salary_change_request",
             "salary_change_requests_visible", "guard_performance_review_write", "submit_review", "approve_review",
             "asset_disposal_fingerprint", "dispose_fixed_asset_internal", "dispose_fixed_asset",
             "asset_disposal_execute_internal", "asset_disposal_dry_run", "submit_asset_disposal_request",
             "decide_asset_disposal_request", "withdraw_asset_disposal_request", "asset_disposal_requests_visible",
             "guard_asset_disposal_freeze", "journal_entry_reversal_route",
             "record_approval_decision", "approval_pending_documents", "approval_chain_gates"]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR9_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.salary_change_requests') IS NOT NULL OR to_regclass('public.asset_disposal_requests') IS NOT NULL THEN
        RAISE EXCEPTION 'APR9_PRE|a request table already exists';
    END IF;
    -- 处置的决定人要持两个门码;调薪的两条路(cfo / cco)各要自己的决定码 + 人事模块 + 看得见工资
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cfo' AND rp.permission_code IN ('module.finance.view', 'data.view_prices',
               'action.approve_review', 'module.hr.view', 'data.view_pay')) <> 5 THEN
        RAISE EXCEPTION 'APR9_PRE|cfo does not hold the five codes this cut routes to it';
    END IF;
    IF (SELECT count(*) FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         WHERE r.code = 'cco' AND rp.permission_code IN ('action.hr_reviews', 'module.hr.view', 'data.view_pay')) <> 3 THEN
        RAISE EXCEPTION 'APR9_PRE|cco does not hold the three codes this cut routes to it';
    END IF;
    -- 处置从来没有发生过(APR-4 实测 0;Step 0 再读一遍 0)
    IF EXISTS (SELECT 1 FROM fixed_assets WHERE status = 'disposed')
       OR EXISTS (SELECT 1 FROM journal_entries WHERE source_type = 'asset_disposal') THEN
        RAISE EXCEPTION 'APR9_PRE|a disposal already exists';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE a9_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE a9_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE a9_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

# ── 1 · 表 ───────────────────────────────────────────────────────────────────
for tname in ["salary_change_requests", "asset_disposal_requests"]:
    t = mirror(f"db/tables/{tname}.sql")
    parts.append(f"\n-- ── 1 · {tname}(镜像原样)────────────────────────────────────────────\n")
    parts.append(t[t.index(f"CREATE TABLE public.{tname}"):])

# ── 2 · approval_log:主体类型 + 读策略 ─────────────────────────────────────────
al = mirror("db/tables/approval_log.sql")
i = al.index("subject_type        text NOT NULL CHECK (subject_type IN (")
j = al.index("'asset_disposal_request')),", i) + len("'asset_disposal_request'))")
check_body = al[i + len("subject_type        text NOT NULL "):j]
parts.append("\n-- ── 2 · approval_log:主体类型加两种;读策略加同名两支 ─────────────────────────\n")
parts.append("ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;\n")
parts.append("ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check\n    "
             + check_body + ";\n")
parts.append('DROP POLICY "approval_log select by permission" ON public.approval_log;\n')
parts.append(stmt("db/tables/approval_log.sql", 'CREATE POLICY "approval_log select by permission"'))

# ── 3 · 函数 ─────────────────────────────────────────────────────────────────
parts.append("\n-- ── 3 · 函数(镜像原样)──────────────────────────────────────────────────────\n")
for name in FUNCTIONS:
    parts.append(fn(name))

# ── 4 · 两支守卫 ─────────────────────────────────────────────────────────────
parts.append("\n-- ── 4 · 两支守卫(Q1 · Q8)────────────────────────────────────────────────\n")
parts.append(stmt("db/tables/performance_reviews.sql", "CREATE TRIGGER trg_performance_reviews_guard_write\n"))
parts.append(stmt("db/tables/fixed_assets.sql", "CREATE TRIGGER trg_fixed_assets_disposal_freeze\n"))

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
parts.append("\n-- ── 6 · operations_now:加两支 asset_disposal_pending · salary_change_pending(镜像原样)──────\n")
parts.append(view.replace("CREATE VIEW public.operations_now AS", "CREATE OR REPLACE VIEW public.operations_now AS", 1))

# ── 7 · 自证 ─────────────────────────────────────────────────────────────────
a8 = mirror("db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql")
start = a8.index("CREATE FUNCTION pg_temp.a8_pending_decider_check")
dec = a8[start:a8.index("$f$;", start) + 4].replace("a8_pending_decider_check", "a9_pending_decider_check")
# APR-9:调薪申请不在名册里 —— 它的决定人由 salary_change_deciders 答(提交时的同一份判据)
old_tail = """     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
)"""
assert dec.count(old_tail) == 1
dec = dec.replace(old_tail, """     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)""")
parts.append("\n-- ── 7 · 自证 ──────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")
internal_list = ", ".join(f"'public.{s}'" for s in INTERNALS)
guard_list = ", ".join(f"'{g}'" for g in GUARDS)
parts.append(f"""
CREATE TEMP TABLE a9_pending_after ON COMMIT DROP AS
{PENDING}
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一条没变(本刀不新增、不收回任何码)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM a9_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM a9_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR9_PROOF|grants changed: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'APR9_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、资产、折旧、月薪、履历、评估一行没变;两张申请表是空的
    IF EXISTS ((SELECT b.k, b.id FROM a9_pending_before b EXCEPT SELECT a.k, a.id FROM a9_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM a9_pending_after a EXCEPT SELECT b.k, b.id FROM a9_pending_before b)) THEN
        RAISE EXCEPTION 'APR9_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM a9_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'APR9_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM a9_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF EXISTS (SELECT 1 FROM salary_change_requests) OR EXISTS (SELECT 1 FROM asset_disposal_requests) THEN
        RAISE EXCEPTION 'APR9_PROOF|a request table is not empty';
    END IF;

    -- ④ 结构:两张申请表没有写策略;两支守卫挂上;内层算子 authenticated 调不到;
    --    名册里处置一行、只有二级;调薪【不在】名册里
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                AND tablename IN ('salary_change_requests', 'asset_disposal_requests') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'APR9_PROOF|a request table has a write policy';
    END IF;
    SELECT count(*) INTO v_n FROM pg_trigger WHERE NOT tgisinternal AND tgname IN ({guard_list});
    IF v_n <> {len(GUARDS)} THEN RAISE EXCEPTION 'APR9_PROOF|expected {len(GUARDS)} guard triggers, got %', v_n; END IF;
    SELECT string_agg(s, ', ') INTO v_bad FROM unnest(ARRAY[{internal_list}]) s
     WHERE has_function_privilege('authenticated', s::regprocedure, 'EXECUTE');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'APR9_PROOF|authenticated can still execute: %', v_bad; END IF;
    IF (SELECT array_agg(level ORDER BY level) FROM approval_chain_gates() WHERE subject_type = 'asset_disposal_request')
       IS DISTINCT FROM ARRAY[2]::smallint[] THEN
        RAISE EXCEPTION 'APR9_PROOF|asset_disposal_request chain row';
    END IF;
    IF EXISTS (SELECT 1 FROM approval_chain_gates() WHERE subject_type = 'salary_change_request') THEN
        RAISE EXCEPTION 'APR9_PROOF|salary_change_request must not be in approval_chain_gates (Q2)';
    END IF;
    IF journal_entry_reversal_route(NULL) IS NOT NULL THEN
        RAISE EXCEPTION 'APR9_PROOF|reversal route of nothing';
    END IF;

    -- ⑤ 一份判据:review_approval_code 与 pay_decision_code 对每一对(账号 × 员工)逐字相等
    SELECT count(*) INTO v_n
      FROM auth.users u CROSS JOIN employees e
     WHERE e.deleted_at IS NULL
       AND review_approval_code(u.id, e.id) IS DISTINCT FROM pay_decision_code(u.id, e.id);
    IF v_n > 0 THEN RAISE EXCEPTION 'APR9_PROOF|review_approval_code and pay_decision_code disagree on % pairs', v_n; END IF;

    -- ⑥ 处置链此刻有人批得了
    SELECT count(*) INTO v_n FROM approval_deciders('asset_disposal_request', 'decide_asset_disposal_request', 2::smallint,
        NULL, NULL, (SELECT approval_level1_role_code FROM finance_settings),
        (SELECT approval_level2_role_code FROM finance_settings));
    IF v_n = 0 THEN RAISE EXCEPTION 'APR9_PROOF|nobody can decide an asset disposal'; END IF;
    RAISE NOTICE 'APR9 deciders for asset_disposal_request: %', v_n;

    -- ⑦ 调薪:每一个真能提单的人(module.hr.edit + data.view_pay)替每一名在职员工(不是他自己)提,
    --    都还有一个不是当事人的决定人 —— 除非落进 Step 0 量过的那一格(提单人与主角把两条路都占了)。
    --    这里只数、只报,不拒:那一格由提交时的 SALARY_CHANGE_NO_OTHER_DECIDER 按名拒(Q4 的一部分)。
    FOR k, v_bad IN
        SELECT (SELECT email::text FROM auth.users WHERE id = r.user_id) || ' → ' || e.code,
               COALESCE((SELECT string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = d.user_id), ' ')
                           FROM salary_change_deciders(r.user_id, e.id) d), '(nobody — refused at submit)')
          FROM (SELECT DISTINCT rg.user_id FROM role_permissions rp JOIN roles ro ON ro.id = rp.role_id
                 CROSS JOIN LATERAL real_role_grants(ro.code) rg
                 WHERE rp.permission_code = 'module.hr.edit'
                   AND rg.user_id IN (SELECT rg2.user_id FROM role_permissions rp2 JOIN roles ro2 ON ro2.id = rp2.role_id
                                       CROSS JOIN LATERAL real_role_grants(ro2.code) rg2
                                       WHERE rp2.permission_code = 'data.view_pay')) r
         CROSS JOIN employees e
         WHERE e.deleted_at IS NULL AND e.employment_status <> 'separated'
           AND self_leg(NULL, e.id, r.user_id) = 'none'
         ORDER BY 1
    LOOP
        RAISE NOTICE 'APR9 salary route % : %', k, v_bad;
    END LOOP;

    -- ⑧ 每一张在途单据 —— 连同每一条申请链与调薪 —— 都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.a9_pending_decider_check(true) c LOOP
        RAISE NOTICE 'APR9 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.a9_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'APR9_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.a9_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.a9_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
