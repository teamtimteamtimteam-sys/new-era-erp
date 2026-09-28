#!/usr/bin/env python3
"""LEAVE-BAL-1 + NAME-1:从镜像拼出迁移文件(形状照 build_overtime1_migration.py)。镜像是真源,迁移是它的一次投影 ——
函数、列注释、视图、授权都从 db/ 下原样抽出,所以迁移建出来的与门重建出来的是同一串字。
跑法:python3 db/scripts/build_leavebal1_migration.py(在仓库根目录)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql"


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


HEADER = """-- db/migrations/2026-09-28-leavebal1-leave-balance-and-first-last-name.sql
-- LEAVE-BAL-1 + NAME-1(v1.4.31)—— 请假不能超过余额;员工有了名字与姓氏。
-- 由 db/scripts/build_leavebal1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(LEAVE-BAL-1 grilling Q1–Q22,Tim 2026-09-28 全部接受)
--   ① leave_balance_internal:第三个来源「按年额度」(年假以外、default_days_per_year 不为空的假别);
--      新增 'pending'(待批)· 'bookable'(= available − pending)· 'balance_checked'(有没有额度)。
--      'available' 的含义一个字没改(额度 − 已批),employees_masked 与三个页面照旧读它。
--   ② submit_leave_request:每一个有额度的假别都查(只有 unpaid 不查),比 bookable(扣待批);
--      HR 例外一样查;先锁员工行。拒绝码不变(年假 INSUFFICIENT_ACCRUED_LEAVE,其余 INSUFFICIENT_BALANCE)。
--   ③ decide_leave_request:审批时再查一次,每一个有额度的假别;比 available(只扣已批,Q10 Option A);锁员工行。
--   ④ annual_leave_available_from:比 bookable —— "哪天起提交得动"。
--   ⑤ leave_requests:收回 authenticated 的写权限,删掉三条写策略(先例 import_batches)——
--      写只走三支 SECURITY DEFINER 函数。is_exception 的列注释改成"例外不能多给"。
--   ⑥ employees:first_name / last_name(text,可空,末尾)—— 列授权 + employees_masked + 列注释,一支迁移;
--      22 行全部留空。export_my_personal_data 带上两列;anonymise_employee 把两列清成 NULL。
--
-- 【不做什么】不碰审批开关与策略;不写任何业务行;不碰任何一张已有的请假单(LV-2026-0004/0005/0006 原样);
-- 不改 leave_types 的任何值(compassionate 3 · marriage 3 · examination 2 照现值生效,Tim Q2)。
-- ★ RUNTIME CONFIG 声明(AGENTS.md):leave_types.default_days_per_year 的【含义】变了 —— 从说明性的数变成
--   一道硬额度。镜像里的种子值(db/tables/leave_types.sql)在新含义下【仍然是 Tim 要的数】(Q2 · Q3 裁定照现值),
--   所以引导默认值不改;三个日历周假别的单位问题登记在 docs/known-issues.md(Q3)。
--
-- 【审批是开着的】最后那一段自证在同一笔事务里断言:开关仍开;授权一行没变;在途单据一张不少、一张不多;
-- 留痕、分录、请假单、员工一行没变;新列两列全空;leave_requests 登录用户只剩读;
-- 每一张在途单据都还有一个【不是它自己当事人】的决定人。断言失败 = 整笔回滚。

BEGIN;
"""

# 在途清单与计数:与 OVERTIME-1 同一套(加上 overtime_batch 那一行)
ot1 = mirror("db/scripts/build_overtime1_migration.py")
PENDING = re.search(r'PENDING = """(.*?)"""', ot1, re.S).group(1) + \
    "\nUNION ALL SELECT 'overtime_batch', id FROM overtime_batches WHERE status = 'submitted'"
COUNTS = re.search(r'COUNTS = """(.*?)"""', ot1, re.S).group(1)
assert "FROM leave_requests) AS leave" in COUNTS and "FROM employees) AS employees" in COUNTS

FNS = ["leave_balance_internal", "submit_leave_request", "decide_leave_request",
       "annual_leave_available_from", "export_my_personal_data", "anonymise_employee"]
SIGS = {
    "leave_balance_internal": "public.leave_balance_internal(uuid, text, date)",
    "submit_leave_request": "public.submit_leave_request(uuid, text, date, date, boolean, boolean, text, text, boolean, numeric, text)",
    "decide_leave_request": "public.decide_leave_request(uuid, boolean, text)",
    "annual_leave_available_from": "public.annual_leave_available_from(uuid, numeric, date)",
    "export_my_personal_data": "public.export_my_personal_data()",
    "anonymise_employee": "public.anonymise_employee(uuid, text)",
}

# ── 从镜像里抽出要重放的片段 ─────────────────────────────────────────────────
emp = mirror("db/tables/employees.sql")
emp_comments = re.findall(r"COMMENT ON COLUMN public\.employees\.(?:first_name|last_name) IS\n.*?';\n", emp, re.S)
assert len(emp_comments) == 2, emp_comments
assert "greeting_name, is_site_staff, first_name, last_name)\n    ON public.employees TO authenticated;" in emp

masked = mirror("db/views/employees_masked.sql")
masked_body = masked[masked.index("CREATE VIEW public.employees_masked"):]
masked_body = masked_body.replace("CREATE VIEW public.employees_masked", "CREATE OR REPLACE VIEW public.employees_masked", 1)
assert "    first_name,\n    last_name\n   FROM employees" in masked_body

lr = mirror("db/tables/leave_requests.sql")
assert "REVOKE ALL ON public.leave_requests FROM authenticated;\nGRANT SELECT ON public.leave_requests TO authenticated;" in lr
for p in ("insert", "update", "delete"):
    assert f'"leave_requests {p} by permission"' not in lr, p
exc_comment = re.search(r"COMMENT ON COLUMN public\.leave_requests\.is_exception IS\n.*?';\n", lr, re.S)
assert exc_comment and "cannot grant more than the entitlement" in exc_comment.group(0)

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'LB1_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.employees'::regclass
                AND attname IN ('first_name', 'last_name') AND NOT attisdropped) THEN
        RAISE EXCEPTION 'LB1_PRE|employees.first_name / last_name already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.leave_requests'::regclass
         AND polname IN ('leave_requests insert by permission', 'leave_requests update by permission',
                         'leave_requests delete by permission')) <> 3 THEN
        RAISE EXCEPTION 'LB1_PRE|the three leave_requests write policies are not all present';
    END IF;
END;
$pre$;
""")
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE lb1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE lb1_counts_before ON COMMIT DROP AS
{COUNTS};
CREATE TEMP TABLE lb1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE lb1_leave_before ON COMMIT DROP AS
SELECT md5(string_agg(row(l.*)::text, ',' ORDER BY l.id)) AS h, count(*) AS n FROM leave_requests l;
""")

parts.append(f"""
-- ── 1 · 员工:名字与姓氏(镜像 db/tables/employees.sql 同改;列加在末尾)───────────────
-- 遮蔽表加列 = 三件事,一支迁移:ADD COLUMN · 列授权 · employees_masked(AGENTS.md)。
ALTER TABLE public.employees ADD COLUMN first_name text, ADD COLUMN last_name text;
GRANT SELECT (first_name, last_name) ON public.employees TO authenticated;
{"".join(emp_comments)}
{masked_body.rstrip()}
""")

parts.append(f"""
-- ── 2 · leave_requests:写只走函数(Q12,镜像 db/tables/leave_requests.sql 同改)────────────
REVOKE ALL ON public.leave_requests FROM authenticated;
GRANT SELECT ON public.leave_requests TO authenticated;
DROP POLICY "leave_requests insert by permission" ON public.leave_requests;
DROP POLICY "leave_requests update by permission" ON public.leave_requests;
DROP POLICY "leave_requests delete by permission" ON public.leave_requests;
{exc_comment.group(0)}""")

parts.append("\n-- ── 3 · 函数(镜像原样;签名一个都没变)──────────────────────────────────────\n")
for f in FNS:
    parts.append(fn(f))

# ── 4 · 自证 ────────────────────────────────────────────────────────────────
ot1_mig = mirror("db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql")
start = ot1_mig.index("CREATE FUNCTION pg_temp.ot1_pending_decider_check")
dec = ot1_mig[start:ot1_mig.index("$f$;", start) + 4].replace("ot1_pending_decider_check", "lb1_pending_decider_check")
parts.append("\n-- ── 4 · 自证 ─────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

fn_checks = "\n".join(
    f"""    IF to_regprocedure('{sig}') IS NULL THEN
        RAISE EXCEPTION 'LB1_PROOF|{name}: signature changed';
    END IF;""" for name, sig in SIGS.items())

parts.append(f"""
CREATE TEMP TABLE lb1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad  text;
    v_n    int;
    k      text;
BEGIN
    -- ① 授权一行没变
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM lb1_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM lb1_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'LB1_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'LB1_PROOF|approvals switched off';
    END IF;

    -- ③ 在途单据一张不少、一张不多;留痕、分录、请假单、员工一行没变
    IF EXISTS ((SELECT b.k, b.id FROM lb1_pending_before b EXCEPT SELECT a.k, a.id FROM lb1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM lb1_pending_after a EXCEPT SELECT b.k, b.id FROM lb1_pending_before b)) THEN
        RAISE EXCEPTION 'LB1_PROOF|a pending document changed state';
    END IF;
    IF (SELECT row(c.*)::text FROM lb1_counts_before c) IS DISTINCT FROM (SELECT row(n.*)::text FROM ({COUNTS}) n) THEN
        RAISE EXCEPTION 'LB1_PROOF|a count changed: % → %',
            (SELECT row(c.*)::text FROM lb1_counts_before c), (SELECT row(n.*)::text FROM ({COUNTS}) n);
    END IF;
    IF (SELECT h FROM lb1_leave_before) IS DISTINCT FROM
       (SELECT md5(string_agg(row(l.*)::text, ',' ORDER BY l.id)) FROM leave_requests l) THEN
        RAISE EXCEPTION 'LB1_PROOF|a leave request row changed';
    END IF;

    -- ④ 两列新名字:全空(Tim:22 行留空,下一次保存时补);列授权 + employees_masked(colgrant 的两半)
    SELECT count(*) INTO v_n FROM employees WHERE first_name IS NOT NULL OR last_name IS NOT NULL;
    IF v_n <> 0 THEN RAISE EXCEPTION 'LB1_PROOF|% employee(s) got a first/last name', v_n; END IF;
    IF NOT has_column_privilege('authenticated', 'public.employees', 'first_name', 'SELECT')
       OR NOT has_column_privilege('authenticated', 'public.employees', 'last_name', 'SELECT') THEN
        RAISE EXCEPTION 'LB1_PROOF|employees.first_name / last_name are not SELECT-granted';
    END IF;
    IF (SELECT count(*) FROM pg_attribute WHERE attrelid = 'public.employees_masked'::regclass
         AND attname IN ('first_name', 'last_name') AND NOT attisdropped) <> 2 THEN
        RAISE EXCEPTION 'LB1_PROOF|employees_masked lacks first_name / last_name';
    END IF;

    -- ⑤ leave_requests:登录用户只剩读;三条写策略没了;读策略两条还在
    IF has_table_privilege('authenticated', 'public.leave_requests', 'INSERT')
       OR has_table_privilege('authenticated', 'public.leave_requests', 'UPDATE')
       OR has_table_privilege('authenticated', 'public.leave_requests', 'DELETE')
       OR NOT has_table_privilege('authenticated', 'public.leave_requests', 'SELECT') THEN
        RAISE EXCEPTION 'LB1_PROOF|authenticated should hold SELECT only on leave_requests';
    END IF;
    IF (SELECT count(*) FROM pg_policy WHERE polrelid = 'public.leave_requests'::regclass) <> 2
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.leave_requests'::regclass AND polcmd <> 'r') THEN
        RAISE EXCEPTION 'LB1_PROOF|leave_requests should keep exactly its two read policies';
    END IF;

    -- ⑥ 签名一个都没变(破窗里旧界面照旧调得通)
{fn_checks}

    -- ⑦ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.lb1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'LB1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.lb1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'LB1_PROOF|% pending document(s) would have no decider: %', v_n,
            (SELECT string_agg(c.k || ':' || c.doc, ', ') FROM pg_temp.lb1_pending_decider_check(true) c WHERE c.deciders = 0);
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.lb1_pending_decider_check(boolean);

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
