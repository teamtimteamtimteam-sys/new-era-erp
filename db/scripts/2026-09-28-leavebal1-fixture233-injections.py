#!/usr/bin/env python3
"""LEAVE-BAL-1:fixture 233 的逐臂故障注入(db/scripts/2026-09-28-leavebal1-fixture233-injections.py)。
形状照 2026-09-28-overtime1-fixture232-injections.py。
跑法:先建一个【空的本地】重建库(python3 db/verify_rebuild.py --target "<dsn>" --skip-diff,见 AGENTS.md),
再 INJECT_DSN="<那个 dsn>" python3 db/scripts/2026-09-28-leavebal1-fixture233-injections.py。★ 绝不要指向线上。
每一格:从镜像取出被测函数的定义 → 做一处替换(注入)→ 把 CREATE OR REPLACE(或一句授权)插进 fixture 的事务开头 →
在本地重建库上跑 → 必须失败,而且失败的必须是【点名的那一臂】。fixture 自己以 ROLLBACK 收尾,
psql 在第一个错误处停下,连接一断整笔事务就回滚,所以每一格都跑在同一个干净的重建库上。
先跑一格【不注入】的对照:它必须绿,否则后面的红没有意义。"""
import os
import pathlib
import re
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parents[2]
FIX = (REPO / "db/fixtures/233-leave-cannot-be-booked-beyond-the-balance-and-a-name-has-a-first-part.sql").read_text()
DSN = os.environ["INJECT_DSN"]
if "supabase" in DSN:
    sys.exit("INJECT_DSN points at live — refusing")
TMP = pathlib.Path(tempfile.gettempdir()) / "inj233.sql"


def fn(name):
    txt = (REPO / f"db/functions/{name}.sql").read_text()
    m = re.search(r"CREATE OR REPLACE FUNCTION.*?AS \$function\$.*?\$function\$\s*;?", txt, re.S)
    body = m.group(0)
    if not body.rstrip().endswith(";"):
        body += ";"
    return body


def inj(name, old, new):
    body = fn(name)
    assert body.count(old) == 1, f"{name}: injection anchor must occur exactly once: {old!r} ({body.count(old)})"
    return body.replace(old, new)


SUBMIT_GATE = "IF (v_bal->>'balance_checked')::boolean THEN\n        v_avail := (v_bal->>'bookable')::numeric;"
DECIDE_GATE = "IF (v_bal->>'balance_checked')::boolean THEN\n        v_avail := (v_bal->>'available')::numeric;"
CHECKED = "v_checked := COALESCE(v_type.is_accrued, false) OR v_type.default_days_per_year IS NOT NULL;"

CASES = [
    ("A0 annual not checked at submit", "233A0",
     inj("submit_leave_request", SUBMIT_GATE, SUBMIT_GATE.replace("::boolean THEN", "::boolean AND NOT v_type.is_accrued THEN"))),
    ("A2 submit ignores pending (compares available)", "233A2",
     inj("submit_leave_request", "v_avail := (v_bal->>'bookable')::numeric;", "v_avail := (v_bal->>'available')::numeric;")),
    ("A3 exactly-equal refused (<= instead of <)", "233A3",
     inj("submit_leave_request", "        IF v_avail < v_days THEN", "        IF v_avail <= v_days THEN")),
    ("A4 HR record not checked", "233A4",
     inj("submit_leave_request", SUBMIT_GATE, SUBMIT_GATE.replace("::boolean THEN", "::boolean AND NOT has_permission('module.hr.edit') THEN"))),
    ("B1 half day counted as a full day", "233B1",
     inj("calculate_leave_days", "- CASE WHEN p_start_half THEN 0.5 ELSE 0 END", "- CASE WHEN p_start_half THEN 0 ELSE 0 END")),
    ("B3 non-annual not checked at submit", "233B3",
     inj("submit_leave_request", SUBMIT_GATE, SUBMIT_GATE.replace("::boolean THEN", "::boolean AND v_type.is_accrued THEN"))),
    ("B4 HR record of a non-annual type not checked", "233B4",
     inj("submit_leave_request", SUBMIT_GATE,
         SUBMIT_GATE.replace("::boolean THEN", "::boolean AND (v_type.is_accrued OR NOT has_permission('module.hr.edit')) THEN"))),
    ("B5 HR exception bypasses the balance", "233B5",
     inj("submit_leave_request", SUBMIT_GATE, SUBMIT_GATE.replace("::boolean THEN", "::boolean AND NOT p_is_exception THEN"))),
    ("C1 unpaid leave checked", "233C1",
     inj("leave_balance_internal", CHECKED, "v_checked := true;")),
    ("C2 infant care (unpaid, has entitlement) not checked", "233C2",
     inj("leave_balance_internal", CHECKED,
         "v_checked := COALESCE(v_type.is_accrued, false) OR (v_type.default_days_per_year IS NOT NULL AND p_leave_type_code <> 'infant_care');")),
    ("D1 approval counts the other pending request (literal rule)", "233D1",
     inj("decide_leave_request", "v_avail := (v_bal->>'available')::numeric;", "v_avail := (v_bal->>'bookable')::numeric + v_req.days;")),
    # 审批时的检查拿掉 —— 年假那一张还有第二道(扣授予与累积的循环,末尾 v_need > 0 照样拒),
    # 所以这一格红在【非年假】那一臂 D4,不是 D2。这是一次查过的"没有在 D2 咬人",不是一格失效的注入。
    ("D4 approval re-check removed (annual still held by the draw loop)", "233D4",
     inj("decide_leave_request", DECIDE_GATE, DECIDE_GATE.replace("::boolean THEN", "::boolean AND false THEN"))),
    ("D2 approval re-check AND the draw-loop guard both removed", "233D2",
     inj("decide_leave_request", DECIDE_GATE, DECIDE_GATE.replace("::boolean THEN", "::boolean AND false THEN"))
     .replace("        IF v_need > 0 THEN\n            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE",
              "        IF false THEN\n            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE")),
    ("W1 direct INSERT granted back", "233W1",
     "GRANT INSERT ON public.leave_requests TO authenticated;\n"
     "CREATE POLICY \"inj insert\" ON public.leave_requests FOR INSERT TO authenticated WITH CHECK (has_permission('module.hr.edit'));"),
    ("W2 direct UPDATE granted back", "233W2",
     "GRANT UPDATE ON public.leave_requests TO authenticated;\n"
     "CREATE POLICY \"inj update\" ON public.leave_requests FOR UPDATE TO authenticated "
     "USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));"),
    ("W3 direct DELETE granted back", "233W3",
     "GRANT DELETE ON public.leave_requests TO authenticated;\n"
     "CREATE POLICY \"inj delete\" ON public.leave_requests FOR DELETE TO authenticated USING (has_permission('module.hr.edit'));"),
    ("M1 first_name column grant missing", "233M1",
     "REVOKE SELECT (first_name) ON public.employees FROM authenticated;"),
    ("N1 export drops first/last name", "233N1",
     inj("export_my_personal_data", "            'first_name', v_emp.first_name, 'last_name', v_emp.last_name,\n", "")),
    ("N2 anonymise leaves first/last name", "233N2",
     inj("anonymise_employee", "        first_name           = NULL,\n        last_name            = NULL,\n", "")),
]

# D2 的那一格必须真的把两处都换掉了
assert CASES[12][2].count("IF false THEN\n            RAISE EXCEPTION 'INSUFFICIENT_ACCRUED_LEAVE") == 1


def run(inject_sql):
    anchor = "SET LOCAL statement_timeout = '180s';"
    assert FIX.count(anchor) == 1
    text = FIX.replace(anchor, anchor + "\n-- ★ INJECTION\n" + inject_sql + "\n", 1)
    TMP.write_text(text)
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(TMP)],
                       capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr)


rc, out = run("")
ok_control = rc == 0 and "FIXTURE 233 全部通过" in out
print(f"control (no injection): exit={rc} {'GREEN ✓' if ok_control else 'NOT GREEN ✗'}")
if not ok_control:
    print(out[-2000:])
    sys.exit(2)

bad = 0
for label, want, sql in CASES:
    rc, out = run(sql)
    hit = re.search(r"FIXTURE (233[A-Z]\d+)", out)
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
print(f"INJECT233_BAD={bad} of {len(CASES)}")
sys.exit(0 if bad == 0 else 1)
