#!/usr/bin/env python3
"""AUDIT-TRAIL-1d-3:fixture 246 的故障注入 —— 每一格注入一处缺陷,fixture 246 必须在【它点名的那一臂】红。

做法照 1d-2 的 db/scripts/2026-10-04-at1d2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;
注入随 ROLLBACK 消失。函数的注入用 pg_get_functiondef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
成员行与"之前"那一段的原文从镜像里按前缀取出来(手抄一行的空格一错,注入就静悄悄地没换上)。

跑法:python3 db/scripts/2026-10-05-at1d3-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>" [临时文件目录]
退出码:0 = 每一格都红在它的那一臂、干净跑绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
TMPDIR = pathlib.Path(sys.argv[2] if len(sys.argv) > 2 else "/tmp/claude-501")
ROOT = pathlib.Path(".")
F246 = next(ROOT.glob("db/fixtures/246-*.sql"))
MEMBERS_SRC = (ROOT / "db/functions/trail_subject_members.sql").read_text()
PRE_SRC = (ROOT / "db/functions/trail_prelog_sources.sql").read_text()
SUBJ_SRC = (ROOT / "db/functions/trail_subjects.sql").read_text()


def patch(fn_sig, old, new):
    o = old.replace("'", "''")
    n = new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_functiondef('{fn_sig}'::regprocedure);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{fn_sig}'; END IF;
    EXECUTE d2;
END $inj$;
"""


SUBJ = "public.trail_subjects()"
MEM = "public.trail_subject_members()"
PRE = "public.trail_prelog_sources()"
REC = "public.trail_row_record(text, jsonb, jsonb, jsonb)"
LAB = "public.trail_ref_label(text, text, text)"
MASK = "public.change_log_mask_rules()"
LBL = "public.my_period_labels()"


def member(subject, ord_):
    m = re.search(r"\('%s',\s*%d,[^\n]*?\)(?=,?\n)" % (re.escape(subject), ord_), MEMBERS_SRC)
    assert m, (subject, ord_)
    return m.group(0)


def hide(subject, ord_):
    """一行成员从"进审计记录"改成"垫脚石"(shown true → false)—— 等于把那张表从这条记录里拿掉"""
    row = member(subject, ord_)
    new = re.sub(r"'(down|up|all)',(\s*)true,", r"'\1',\2false,", row, count=1)
    assert new != row, row
    return patch(MEM, row, new)


def add_member(after_subject, after_ord, row):
    """在一行成员后面多挂一行(注入一个本不该在这条记录里的成员)"""
    anchor = member(after_subject, after_ord)
    return patch(MEM, anchor, anchor + ",\n        " + row)


def pre_line(table, kind, column):
    m = re.search(r"\n(        \('%s',\s*'%s',\s*'%s'[^\n]*)" % (re.escape(table), kind, re.escape(column)), PRE_SRC)
    assert m, (table, column)
    return m.group(1)


def pre_drop(table, kind, column):
    """把"之前"那一段的一行拿掉(连同它的逗号与换行 —— 最后一行没有逗号,取它前一行的逗号)"""
    line = pre_line(table, kind, column)
    if line.endswith(","):
        return patch(PRE, line + "\n", "")
    return patch(PRE, ",\n" + line, "")


def subject_row(subject):
    m = re.search(r"\('%s',[^\n]*?\)(?=,?\n)" % re.escape(subject), SUBJ_SRC)
    assert m, subject
    return m.group(0)


CASES = [
    # ── PP · 工资期 ──
    ("PP (Q11): the pay lines dropped from the period", hide("payroll_period", 1), "FIXTURE 246 PP (Q11: the changed line, deleted)"),
    ("PP: the journals found through journal_entry_id (the unpost clears it) instead of source_id",
     patch(MEM, member("payroll_period", 4),
           "('payroll_period',     4, 'journal_entries',  'payroll_periods',     'journal_entry_id',  '{}'::jsonb, 'up',   true, false)"),
     "FIXTURE 246 PP: expected the five journals"),
    ("PP (Q4): the pay figures no longer masked for a reader without data.view_pay",
     patch(MASK, "        ('payroll_lines', 'gross_pay', 'code_or_self:data.view_pay:employee_id'),\n", ""),
     "FIXTURE 246 PP: a reader without data.view_pay must see the gross pay as Restricted"),
    ("PP: the payroll requests dropped from the period", hide("payroll_period", 2), "FIXTURE 246 PP (Q12: the request withdrawn"),
    # ── PQ · Q12 ──
    ("PQ (Q12): the request's withdrawal stamp not registered", pre_drop("payroll_requests", "stamp", "withdrawn_at"),
     "FIXTURE 246 PQ (Q12: withdrawn, before the log)"),
    ("PQ (Q12): the withdrawal stamp loses its person",
     patch(PRE, pre_line("payroll_requests", "stamp", "withdrawn_at"),
           pre_line("payroll_requests", "stamp", "withdrawn_at").replace("'withdrawn_by',", "NULL,", 1)),
     "FIXTURE 246 PQ (Q12): the withdrawal stamp names who withdrew"),
    # ── RV · 评审 ──
    ("RV: the approval rows dropped from the review", hide("performance_review", 2), "FIXTURE 246 RV (the submit approval row)"),
    ("RV (Q7): the employee row hung on the review",
     add_member("performance_review", 2, "('performance_review', 3, 'employees', 'performance_reviews', 'employee_id', '{}'::jsonb, 'up', true, false)"),
     "FIXTURE 246 RV (Q7): the employee row"),
    ("RV (Q7): the new salary no longer masked",
     patch(MASK, "        ('performance_reviews', 'new_monthly_salary', 'code_or_self:data.view_pay:employee_id'),\n", ""),
     "FIXTURE 246 RV (Q7): the outcome reads from the review"),
    # ── MR · M12(Q5)──
    ("MR (M12): the reviewer gate switched off (the table's rule alone admits the reviewed employee)",
     patch(SUBJ, subject_row("my_review"), subject_row("my_review").replace("'gate:reviewer'", "'table'")),
     "FIXTURE 246 MR (M12: the reviewed employee"),
    ("MR: the goals dropped from the reviewer's page", hide("my_review", 1), "FIXTURE 246 MR (the reviewer reads the goals)"),
    # ── CY · Q6 ──
    ("CY (Q6): the reviews a cycle creates hung on the cycle",
     add_member("my_review", 2, "('review_cycle', 1, 'performance_reviews', 'review_cycles', 'cycle_id', '{}'::jsonb, 'down', true, false)"),
     "FIXTURE 246 CY (Q6): the reviews the cycle created"),
    # ── RX · Q12 ──
    ("RX (Q12): the void stamp not registered", pre_drop("performance_reviews", "stamp", "voided_at"),
     "FIXTURE 246 RX (Q12: voided before the log"),
    # ── SC · M11 ──
    ("SC (M11): the rating scale no longer a collection",
     patch(SUBJ, subject_row("review_rating_scale"), subject_row("review_rating_scale").replace("'collection'", "'table'")),
     "FIXTURE 246 SC: the reader was refused"),
    # ── KP · KPI ──
    ("KP (Q14 · Q16): the KPI entry opened to its own employee (no page code)",
     patch(SUBJ, subject_row("kpi_entry"), subject_row("kpi_entry").replace("ARRAY['module.hr.view'],          'kpi_entries'", "ARRAY[]::text[],                  'kpi_entries'")),
     "FIXTURE 246 KP (Q14 · Q16"),
    ("KP (Q12): the scoring stamp not registered", pre_drop("kpi_entries", "stamp", "scored_at"),
     "FIXTURE 246 KP (scored before the log"),
    # ── Q · Q19 ──
    ("Q (Q19): the labels reach periods with none of the caller's lines",
     patch(LBL, "WHERE pl.payroll_period_id = pp.id AND pl.employee_id = current_user_employee())", "WHERE pl.payroll_period_id = pp.id)"),
     "FIXTURE 246 Q19: expected exactly the two periods"),
    ("Q (Q19): the labels carry more than the code and the month",
     "DROP FUNCTION public.my_period_labels();\n"
     "CREATE FUNCTION public.my_period_labels() RETURNS TABLE(kind text, period_id uuid, code text, period_month date, status text)\n"
     " LANGUAGE sql STABLE SECURITY DEFINER SET search_path TO 'public', 'pg_temp' AS $f$\n"
     "    SELECT 'attendance'::text, ap.id, ap.code, ap.period_month, ap.status FROM attendance_periods ap\n"
     "     WHERE EXISTS (SELECT 1 FROM attendance_lines al WHERE al.period_id = ap.id AND al.employee_id = current_user_employee())\n"
     "    UNION ALL\n"
     "    SELECT 'payroll'::text, pp.id, pp.code, pp.period_month, pp.status FROM payroll_periods pp\n"
     "     WHERE EXISTS (SELECT 1 FROM payroll_lines pl WHERE pl.payroll_period_id = pp.id AND pl.employee_id = current_user_employee())\n"
     "$f$;\nGRANT EXECUTE ON FUNCTION public.my_period_labels() TO authenticated;\nREVOKE EXECUTE ON FUNCTION public.my_period_labels() FROM PUBLIC, anon;\n",
     "FIXTURE 246 Q19: nothing else of the period"),
    ("Q (Q19): the employee cannot call it",
     "REVOKE EXECUTE ON FUNCTION public.my_period_labels() FROM authenticated;\n", "FIXTURE 246 Q19: my_period_labels() refused the employee"),
    # ── R · 登记 ──
    ("R (Q10): a payroll request named with its raw kind",
     patch(LAB, "    ELSIF p_table = 'payroll_requests' THEN\n", "    ELSIF p_table = 'payroll_requests' AND false THEN\n"),
     "FIXTURE 246 R (Q10)"),
    ("R: a goal loses its review's link",
     patch(REC, "        v_dkey := 'performance_review'; v_route := '/hr/reviews'; v_mode := 'detail';\n", ""),
     "FIXTURE 246 R: a goal belongs to its review"),
]


def run(injection):
    src = F246.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    TMPDIR.mkdir(parents=True, exist_ok=True)
    tmp = TMPDIR / "inj246.sql"
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
code, out = run("")
ok = code == 0 and "全部通过" in out
print(f"{'✓' if ok else '✗'} clean 246 → {'green' if ok else out[-400:]}")
bad += 0 if ok else 1
for name, inj, expect in CASES:
    code, out = run(inj)
    err = next((l for l in out.splitlines() if "ERROR" in l), "")
    if "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {name}: the injection did not apply — fix the injection, not the fixture")
        bad += 1
    elif code != 0 and expect in out:
        print(f"✓ {name}: red in its arm")
    else:
        print(f"✗ {name}: expected red in «{expect}», got exit {code}: {err[:300]}")
        bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
