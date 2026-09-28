#!/usr/bin/env python3
"""OVERTIME-1:fixture 232 的逐臂故障注入(db/scripts/2026-09-28-overtime1-fixture232-injections.py)。
跑法:先建一个【空的本地】重建库(python3 db/verify_rebuild.py --target "<dsn>" --skip-diff,见 AGENTS.md),
再 INJECT_DSN="<那个 dsn>" python3 db/scripts/2026-09-28-overtime1-fixture232-injections.py。★ 绝不要指向线上。
每一格:从镜像取出被测函数的定义 → 做一处替换(注入)→ 把 CREATE OR REPLACE 插进 fixture 的事务开头 →
在一个本地重建库上跑 → 必须失败,而且失败的必须是【点名的那一臂】。fixture 自己以 ROLLBACK 收尾,
psql 在第一个错误处停下,连接一断整笔事务就回滚,所以每一格都跑在同一个干净的重建库上。
先跑一格【不注入】的对照:它必须绿,否则后面的红没有意义。"""
import pathlib, re, subprocess, sys

import os
REPO = pathlib.Path(__file__).resolve().parents[2]
FIX = (REPO / "db/fixtures/232-site-staff-overtime-by-month.sql").read_text()
DSN = os.environ["INJECT_DSN"]
if "supabase" in DSN:
    sys.exit("INJECT_DSN points at live — refusing")
import tempfile
TMP = pathlib.Path(tempfile.gettempdir()) / "inj232.sql"


def fn(name):
    txt = (REPO / f"db/functions/{name}.sql").read_text()
    m = re.search(r"CREATE OR REPLACE FUNCTION.*?AS \$function\$.*?\$function\$\s*;?", txt, re.S)
    body = m.group(0)
    if not body.rstrip().endswith(";"):
        body += ";"
    return body


def inj(name, old, new):
    body = fn(name)
    assert body.count(old) >= 1, f"{name}: injection anchor not found: {old!r}"
    return body.replace(old, new)


CASES = [
    ("E  site-staff filter removed", "232E1",
     inj("overtime_site_staff", "WHERE e.is_site_staff AND e.deleted_at IS NULL", "WHERE e.deleted_at IS NULL")),
    ("A  enter code not required to create", "232A1",
     inj("create_overtime_batch", "PERFORM require_permission('action.overtime_enter');", "")),
    ("A  approve code not required to decide", "232A4",
     inj("decide_overtime_batch", "PERFORM require_permission('action.overtime_approve');", "")),
    ("O  other-approver check always true", "232O1",
     inj("overtime_other_approver_exists", "SELECT EXISTS (", "SELECT true OR EXISTS (")),
    ("S  add_overtime_line lets a non-site employee in", "232S1",
     inj("add_overtime_line", "IF NOT v_e.is_site_staff THEN", "IF false THEN")),
    ("S  submit does not re-check the flag", "232S2",
     inj("submit_overtime_batch", "(NOT e.is_site_staff OR e.deleted_at IS NOT NULL)", "(e.deleted_at IS NOT NULL)")),
    ("S  approval does not re-check the flag", "232S3",
     inj("decide_overtime_batch", "(NOT e.is_site_staff OR e.deleted_at IS NOT NULL)", "(e.deleted_at IS NOT NULL)")),
    ("K  Saturday counted as the rest day", "232K2",
     inj("overtime_day_kind", "EXTRACT(ISODOW FROM p_date) = 7", "EXTRACT(ISODOW FROM p_date) = 6")),
    ("V  three-decimal hours accepted (silently rounded)", "232V5",
     inj("add_overtime_line", " OR round(p_hours, 2) <> p_hours", "")),
    ("D  duplicate day not refused by name", "232D1",
     inj("add_overtime_line", "IF FOUND THEN\n        RAISE EXCEPTION 'OVERTIME_DUPLICATE_DAY", "IF false THEN\n        RAISE EXCEPTION 'OVERTIME_DUPLICATE_DAY")),
    ("M  second open batch not refused by name", "232M2",
     inj("create_overtime_batch", "IF FOUND THEN\n        RAISE EXCEPTION 'OVERTIME_BATCH_OPEN_EXISTS", "IF false THEN\n        RAISE EXCEPTION 'OVERTIME_BATCH_OPEN_EXISTS")),
    ("F  raiser leg dropped", "232F2",
     inj("decide_overtime_batch", "forbid_self_approval(v_b.submitted_by,", "forbid_self_approval(NULL::uuid,")),
    ("F  subject leg dropped", "232F1",
     inj("decide_overtime_batch", "PERFORM forbid_self_approval(v_b.submitted_by, v_emp, 'overtime_batch');",
         "PERFORM forbid_self_approval(v_b.submitted_by, NULL::uuid, 'overtime_batch');")),
    ("R  rejection without a note accepted", "232R1",
     inj("decide_overtime_batch", "IF p_decision = 'rejected' AND v_note IS NULL THEN", "IF false THEN")),
    ("R  withdraw accepts a draft", "232R6",
     inj("withdraw_overtime_batch", "IF v_b.status <> 'submitted' THEN", "IF v_b.status NOT IN ('submitted', 'draft') THEN")),
    ("X  reversal without a reason accepted", "232X1",
     inj("reverse_overtime_batch", "IF p_reason IS NULL OR btrim(p_reason) = '' THEN", "IF false THEN")),
    ("X  discard leaves the lines live", "232X5",
     inj("discard_overtime_batch", "UPDATE overtime_lines SET voided_at = now() WHERE batch_id = p_batch_id AND voided_at IS NULL;", "")),
    ("L  pending registry misses overtime", "232L1",
     inj("approval_pending_documents", "     WHERE ob.status = 'submitted'", "     WHERE false")),
    ("C  record_attendance takes hours again", "232C1",
     inj("record_attendance", "IF COALESCE(p_normal, 0) <> 0 OR COALESCE(p_rest_day, 0) <> 0 OR COALESCE(p_holiday, 0) <> 0 THEN", "IF false THEN")),
    ("C  completion not blocked by an open batch", "232C2",
     inj("complete_attendance_period", "    IF FOUND THEN\n        RAISE EXCEPTION 'OVERTIME_BATCH_OPEN_FOR_MONTH", "    IF false THEN\n        RAISE EXCEPTION 'OVERTIME_BATCH_OPEN_FOR_MONTH")),
    ("C  hours counted twice on re-completion (accumulate, not recompute)", "232C8",
     inj("complete_attendance_period", "SET ot_normal_hours         = COALESCE(o.weekday_hours, 0),",
         "SET ot_normal_hours         = al.ot_normal_hours + COALESCE(o.weekday_hours, 0),")),
    ("C  reversed batch still counted", "232C4",
     inj("overtime_approved_hours", "       AND l.voided_at IS NULL\n", "\n").replace("b.status = 'approved'", "b.status IN ('approved', 'reversed')")),
    ("C  completed month does not refuse changes", "232C7",
     inj("overtime_assert_month_open", "    IF FOUND THEN\n        RAISE EXCEPTION 'OVERTIME_MONTH_COMPLETE", "    IF false THEN\n        RAISE EXCEPTION 'OVERTIME_MONTH_COMPLETE")),
    ("P  open month screen reads the (unfrozen) sheet", "232P1",
     inj("overtime_month_hours", "IF EXISTS (SELECT 1 FROM attendance_periods ap WHERE ap.period_month = v_m AND ap.status = 'complete') THEN",
         "IF EXISTS (SELECT 1 FROM attendance_periods ap WHERE ap.period_month = v_m) THEN")),
    ("Y  my_overtime_lines not limited to the caller", "232Y1",
     inj("my_overtime_lines", "     WHERE l.employee_id = current_user_employee()\n       AND", "     WHERE")),
    ("Q  R2 flag lost on the self-service reader", "232Q4",
     inj("my_document_decisions", "COALESCE(account_person(d.decided_by) = d.employee_id, false)", "false")),
]


def run(inject_sql):
    text = FIX.replace("SET LOCAL statement_timeout = '180s';",
                       "SET LOCAL statement_timeout = '180s';\n-- ★ INJECTION\n" + inject_sql + "\n", 1)
    TMP.write_text(text)
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(TMP)],
                       capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr)


rc, out = run("")
ok_control = rc == 0 and "FIXTURE 232 全部通过" in out
print(f"control (no injection): exit={rc} {'GREEN ✓' if ok_control else 'NOT GREEN ✗'}")
if not ok_control:
    print(out[-2000:])
    sys.exit(2)

bad = 0
for label, want, sql in CASES:
    rc, out = run(sql)
    hit = re.search(r"FIXTURE (232[A-Z]\d+)", out)
    got = hit.group(1) if hit else None
    red = rc != 0
    named = got == want
    verdict = "RED on the named arm ✓" if (red and named) else ("RED on another arm ✗" if red else "STILL GREEN ✗")
    if not (red and named):
        bad += 1
    print(f"{label:<66} want {want:<6} got {str(got):<6} exit={rc}  {verdict}")
    if red and not named:
        err = [l for l in out.splitlines() if "ERROR" in l]
        print("      ", err[:1])
print(f"INJECT232_BAD={bad} of {len(CASES)}")
sys.exit(0 if bad == 0 else 1)
