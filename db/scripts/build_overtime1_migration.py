#!/usr/bin/env python3
"""OVERTIME-1:从镜像拼出迁移文件(形状照 build_emp_self1_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数、两张新表、视图都从 db/ 下原样抽出,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_overtime1_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql"


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


HEADER = """-- db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql
-- OVERTIME-1(v1.4.30)—— 现场员工的加班:财务按月录,仓库整批批;批过的小时在那个月考勤完成时冻进底稿。
-- 由 db/scripts/build_overtime1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(OVERTIME-1 grilling Q1–Q23,Tim 2026-09-28 全部接受)
--   ① 员工:employees.is_site_staff boolean NOT NULL DEFAULT false(末尾)—— 迁移【一个人都不标】;
--      同一支迁移里补列授权与 employees_masked(遮蔽表加列的三件事,AGENTS.md)。
--   ② 两个码:action.overtime_enter → finance + admin;action.overtime_approve → warehouse + admin
--      (admin 拿到每一个新码 —— 常设裁定 2026-09-24,role-matrix 第 149 行;第 147 行那句"只做系统管理"已被它取代)。
--   ③ 两张新表:overtime_batches(月批次)· overtime_lines(一个员工一天一行)。只有读策略;写只经函数。
--   ④ 新函数:overtime_day_kind · overtime_approved_hours · overtime_assert_month_open · overtime_other_approver_exists
--      (三支内层,EXECUTE 从 authenticated 收回)· create_overtime_batch · add_overtime_line · delete_overtime_line ·
--      submit_overtime_batch · withdraw_overtime_batch · decide_overtime_batch · reverse_overtime_batch ·
--      discard_overtime_batch · overtime_month_hours · overtime_batch_lines · overtime_site_staff · my_overtime_lines。
--   ⑤ 替换:record_attendance(签名不变;非零加班按名拒 ATTENDANCE_OT_THROUGH_OVERTIME)·
--      complete_attendance_period(开着的加班批挡住完成;批过的小时冻进三个桶;冻进的总和必须等于批过的总和)·
--      attendance_period_status_rows(还开着的月读此刻批过的小时)· record_approval_decision(overtime_batch 一支)·
--      approval_pending_documents(overtime_batch 一支,blocks_disable = false)。
--   ⑥ approval_log:主体类型加 overtime_batch;读策略加同名一支。
--
-- 【不做什么】不碰审批开关与策略;不写任何业务行;不标任何员工;线上 attendance_periods / attendance_lines 0 行,
-- 所以没有任何已有底稿的三个桶被改写。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权只多了那四行;在途单据一张不少、一张不多;
-- 留痕、分录、三种自助单据一行没变;没有一个员工被标;两张新表是空的;新函数形状对;每一张在途单据都还有一个
-- 【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

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
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted'"""

COUNTS = """SELECT (SELECT count(*) FROM approval_log) AS approval_log,
       (SELECT count(*) FROM journal_entries) AS journal_entries,
       (SELECT count(*) FROM journal_lines) AS journal_lines,
       (SELECT round(sum(debit), 2) FROM journal_lines) AS debit_total,
       (SELECT count(*) FROM attendance_periods) AS attendance_periods,
       (SELECT count(*) FROM attendance_lines) AS attendance_lines,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM leave_requests) AS leave,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM medical_claims) AS medical,
       (SELECT md5(COALESCE(string_agg(code || ':' || status || ':' || COALESCE(decided_by::text, '-'), ',' ORDER BY code), ''))
          FROM expense_claims) AS expense,
       (SELECT md5(COALESCE(string_agg(code || ':' || work_category || ':' || employment_status, ',' ORDER BY code), ''))
          FROM employees) AS employees,
       (SELECT locked_before FROM finance_settings) AS locked_before"""

NEW_GRANTS = [("finance", "action.overtime_enter"), ("admin", "action.overtime_enter"),
              ("warehouse", "action.overtime_approve"), ("admin", "action.overtime_approve")]

HELPERS = ["overtime_day_kind", "overtime_approved_hours", "overtime_assert_month_open",
           "overtime_other_approver_exists"]
NEW_FNS = ["create_overtime_batch", "add_overtime_line", "delete_overtime_line", "submit_overtime_batch",
           "withdraw_overtime_batch", "decide_overtime_batch", "reverse_overtime_batch", "discard_overtime_batch",
           "overtime_month_hours", "overtime_batch_lines", "overtime_site_staff", "my_overtime_lines"]
REPLACED = ["record_attendance", "complete_attendance_period", "attendance_period_status_rows",
            "record_approval_decision", "approval_pending_documents"]
SIGS = {
    "create_overtime_batch": "public.create_overtime_batch(date)",
    "add_overtime_line": "public.add_overtime_line(uuid, uuid, date, numeric, text)",
    "delete_overtime_line": "public.delete_overtime_line(uuid)",
    "submit_overtime_batch": "public.submit_overtime_batch(uuid)",
    "withdraw_overtime_batch": "public.withdraw_overtime_batch(uuid)",
    "decide_overtime_batch": "public.decide_overtime_batch(uuid, text, text)",
    "reverse_overtime_batch": "public.reverse_overtime_batch(uuid, text)",
    "discard_overtime_batch": "public.discard_overtime_batch(uuid)",
    "overtime_month_hours": "public.overtime_month_hours(date)",
    "overtime_batch_lines": "public.overtime_batch_lines(uuid)",
    "overtime_site_staff": "public.overtime_site_staff()",
    "my_overtime_lines": "public.my_overtime_lines()",
}
INTERNAL = {
    "overtime_approved_hours": "public.overtime_approved_hours(date)",
    "overtime_assert_month_open": "public.overtime_assert_month_open(date)",
    "overtime_other_approver_exists": "public.overtime_other_approver_exists(uuid, uuid[])",
}

# ── 从镜像里抽出要重放的片段 ─────────────────────────────────────────────────
perm_mirror = mirror("db/tables/permissions.sql")
perm_rows = re.findall(r"^    (\('action\.overtime_(?:enter|approve)'.*?\)),?;?$", perm_mirror, re.M)
assert len(perm_rows) == 2, perm_rows

emp_comment = re.search(r"COMMENT ON COLUMN public\.employees\.is_site_staff IS\n.*?';\n", mirror("db/tables/employees.sql"), re.S)
assert emp_comment

masked = mirror("db/views/employees_masked.sql")
masked_body = masked[masked.index("CREATE VIEW public.employees_masked"):]
masked_body = masked_body.replace("CREATE VIEW public.employees_masked", "CREATE OR REPLACE VIEW public.employees_masked", 1)
assert masked_body.startswith("CREATE OR REPLACE VIEW public.employees_masked")

alog = mirror("db/tables/approval_log.sql")
subj = re.search(r"subject_type\s+text NOT NULL CHECK \((subject_type IN \(.*?'overtime_batch'\))\),", alog, re.S)
assert subj, "approval_log subject_type CHECK not found"
policy = re.search(r'CREATE POLICY "approval_log select by permission".*?\n    \);\n', alog, re.S)
assert policy and "'overtime_batch'" in policy.group(0)

ot_batches = mirror("db/tables/overtime_batches.sql")
ot_lines = mirror("db/tables/overtime_lines.sql")

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'OT1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.overtime_batches') IS NOT NULL OR to_regclass('public.overtime_lines') IS NOT NULL THEN
        RAISE EXCEPTION 'OT1_PRE|overtime tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.employees'::regclass
                AND attname = 'is_site_staff' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'OT1_PRE|employees.is_site_staff already exists';
    END IF;
    IF EXISTS (SELECT 1 FROM permissions WHERE code IN ('action.overtime_enter', 'action.overtime_approve')) THEN
        RAISE EXCEPTION 'OT1_PRE|overtime codes already exist';
    END IF;
    -- Tim 2026-09-20 实测 0 行;这支迁移改写 complete_attendance_period 的冻结逻辑,前提是没有已冻的底稿
    IF EXISTS (SELECT 1 FROM attendance_periods WHERE status = 'complete') THEN
        RAISE EXCEPTION 'OT1_PRE|a completed attendance period exists — re-read the Q3 assumption';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE ot1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE ot1_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE ot1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
""")

grant_values = ", ".join(f"('{r}', '{c}')" for r, c in NEW_GRANTS)
parts.append(f"""
-- ── 1 · 两个码(镜像原样)与授权 —— 每一个新码也给 admin(常设裁定,2026-09-24)。幂等。──────────
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
    {perm_rows[0]},
    {perm_rows[1]};

INSERT INTO role_permissions (role_id, permission_code)
SELECT r.id, g.c FROM roles r
  JOIN (VALUES {grant_values}) g(role_code, c)
    ON g.role_code = r.code
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

parts.append(f"""
-- ── 2 · 员工:现场员工标记(镜像 db/tables/employees.sql 同改;列加在末尾)───────────────
-- 遮蔽表加列 = 三件事,一支迁移:ADD COLUMN · 列授权 · employees_masked(AGENTS.md)。
ALTER TABLE public.employees ADD COLUMN is_site_staff boolean NOT NULL DEFAULT false;
GRANT SELECT (is_site_staff) ON public.employees TO authenticated;
{emp_comment.group(0)}
{masked_body.rstrip()}
""")

parts.append("\n-- ── 3 · 两张新表(镜像原样)──────────────────────────────────────────────────\n")
parts.append(ot_batches + "\n" + ot_lines)

parts.append(f"""
-- ── 4 · approval_log:主体类型加 overtime_batch;读策略加同名一支(镜像原样)──────────────
ALTER TABLE public.approval_log DROP CONSTRAINT approval_log_subject_type_check;
ALTER TABLE public.approval_log ADD CONSTRAINT approval_log_subject_type_check
    CHECK ({subj.group(1)});

DROP POLICY "approval_log select by permission" ON public.approval_log;
{policy.group(0)}""")

parts.append("\n-- ── 5 · 内层判据(镜像原样)──────────────────────────────────────────────────\n")
for f in HELPERS:
    parts.append(fn(f))
parts.append("\n-- ── 6 · 新:加班批的写与读(镜像原样)────────────────────────────────────────\n")
for f in NEW_FNS:
    parts.append(fn(f))
parts.append("\n-- ── 7 · 替换:考勤、留痕、在途清单(镜像原样)──────────────────────────────────\n")
for f in REPLACED:
    parts.append(fn(f))

# ── 7b · 函数权限:与 db/views/zzz_function_grants.sql 同一套话。apply_migration.sh 会在本体之后
#    再重放那份文件,但下面的自证跑在本体【里面】,所以新函数的权限要在这里先落好,自证才问得到真值。
acl = ["\n-- ── 7b · 新函数的权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──\n"]
for sig in list(SIGS.values()) + list(INTERNAL.values()) + ["public.overtime_day_kind(date)"]:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL.values():
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

# ── 8 · 自证 ────────────────────────────────────────────────────────────────
es1 = mirror("db/migrations/2026-09-27-emp-self1-find-see-and-withdraw-your-own.sql")
start = es1.index("CREATE FUNCTION pg_temp.es1_pending_decider_check")
dec = es1[start:es1.index("$f$;", start) + 4].replace("es1_pending_decider_check", "ot1_pending_decider_check")
anchor = """    WHERE q.status = 'submitted'
)"""
assert dec.count(anchor) == 1
dec = dec.replace(anchor, """    WHERE q.status = 'submitted'
    UNION ALL
    -- ★ OVERTIME-1:加班批 —— 门 action.overtime_approve;提交人不算,批里任何一个员工也不算(按人认)
    SELECT 'overtime_batch', b.label, b.submitted_by, NULL, h.user_id
      FROM public.overtime_batches b
      LEFT JOIN holds h ON 'action.overtime_approve' = ANY (h.codes)
                       AND public.self_leg(b.submitted_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.overtime_lines l
                                        WHERE l.batch_id = b.id AND l.voided_at IS NULL
                                          AND public.self_leg(NULL, l.employee_id, h.user_id) <> 'none')
     WHERE b.status = 'submitted'
)""")
parts.append("\n-- ── 8 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

expected_new = " UNION ALL ".join(f"SELECT '{r}'::text, '{c}'::text" for r, c in NEW_GRANTS)
new_fn_checks = "\n".join(
    f"""    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{sig}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|{name}: expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;""" for name, sig in SIGS.items())
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'OT1_PROOF|{name} must not be executable by authenticated';
    END IF;""" for name, sig in INTERNAL.items())

parts.append(f"""
CREATE TEMP TABLE ot1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权只多了那四行(两个码 × 各自的角色 + admin),一行没少
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM ot1_grants_before
         EXCEPT SELECT role_code || ':' || c FROM ({expected_new}) e(role_code, c))
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM ot1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'OT1_PROOF|unexpected grant change: %', v_bad; END IF;
    SELECT string_agg(role_code || ':' || c, ', ') INTO v_bad FROM ({expected_new}) e(role_code, c)
     WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                        WHERE r.code = e.role_code AND rp.permission_code = e.c);
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'OT1_PROOF|missing grant: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'OT1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、考勤、自助单据、员工一行没变
    IF EXISTS ((SELECT b.k, b.id FROM ot1_pending_before b EXCEPT SELECT a.k, a.id FROM ot1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM ot1_pending_after a EXCEPT SELECT b.k, b.id FROM ot1_pending_before b)) THEN
        RAISE EXCEPTION 'OT1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM ot1_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'OT1_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM ot1_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;

    -- ④ 没有一个员工被标(Tim:迁移一个人都不标);两张新表是空的
    SELECT count(*) INTO v_n FROM employees WHERE is_site_staff;
    IF v_n <> 0 THEN RAISE EXCEPTION 'OT1_PROOF|% employee(s) flagged as site staff', v_n; END IF;
    IF EXISTS (SELECT 1 FROM overtime_batches) OR EXISTS (SELECT 1 FROM overtime_lines) THEN
        RAISE EXCEPTION 'OT1_PROOF|overtime tables are not empty';
    END IF;

    -- ⑤ 形状:新函数 DEFINER、authenticated 调得到、anon 调不到;三支内层 authenticated 调不到
{new_fn_checks}
{internal_checks}
    -- 遮蔽表加列的两半:列授权 + employees_masked(colgrant 的判据)
    IF NOT has_column_privilege('authenticated', 'public.employees', 'is_site_staff', 'SELECT') THEN
        RAISE EXCEPTION 'OT1_PROOF|employees.is_site_staff is not SELECT-granted';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.employees_masked'::regclass
                    AND attname = 'is_site_staff' AND NOT attisdropped) THEN
        RAISE EXCEPTION 'OT1_PROOF|employees_masked lacks is_site_staff';
    END IF;
    -- record_attendance 签名没变(破窗里旧界面照旧调得通)
    IF to_regprocedure('public.record_attendance(uuid, numeric, numeric, numeric, text)') IS NULL THEN
        RAISE EXCEPTION 'OT1_PROOF|record_attendance signature changed';
    END IF;
    -- 没有 JWT 的读者(本迁移自己,postgres)读 my_overtime_lines():0 行
    SELECT count(*) INTO v_n FROM my_overtime_lines();
    IF v_n <> 0 THEN RAISE EXCEPTION 'OT1_PROOF|my_overtime_lines gave % row(s) to a caller with no employee record', v_n; END IF;

    -- ⑥ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.ot1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'OT1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.ot1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'OT1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.ot1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.ot1_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
