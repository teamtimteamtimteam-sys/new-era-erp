#!/usr/bin/env python3
"""AUDIT-TRAIL-1d-2:fixture 245 的故障注入 —— 每一格注入一处缺陷,fixture 245 必须在【它点名的那一臂】红。

做法照 1d-1 的 db/scripts/2026-10-04-at1d1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;
注入随 ROLLBACK 消失。函数的注入用 pg_get_functiondef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
成员行与"之前"那一段的原文从镜像里按前缀取出来(手抄一行的空格一错,注入就静悄悄地没换上)。

跑法:python3 db/scripts/2026-10-04-at1d2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一格都红在它的那一臂、干净跑绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F245 = next(ROOT.glob("db/fixtures/245-*.sql"))
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


RT = "public.record_trail(text, text, integer)"
SUBJ = "public.trail_subjects()"
MEM = "public.trail_subject_members()"
PRE = "public.trail_prelog_sources()"
REC = "public.trail_row_record(text, jsonb, jsonb, jsonb)"
ACT = "public.trail_actor(text, uuid, uuid)"


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
    # ── L · 请假 ──
    ("L: the approval rows dropped from the leave request", hide("leave_request", 2), "FIXTURE 245 L (the approval row)"),
    # ── P · Q12:决定那一对戳没有登记 ──
    ("P (Q12): the leave decision stamp not registered", pre_drop("leave_requests", "stamp", "decided_at"),
     "FIXTURE 245 P (the decision stamp"),
    # ── X · 那一对戳不记人:本人取消读不出是谁 ──
    ("X (Q12): the decision stamp loses its person",
     patch(PRE, pre_line("leave_requests", "stamp", "decided_at"),
           pre_line("leave_requests", "stamp", "decided_at").replace("'decided_by',", "NULL,", 1)),
     "FIXTURE 245 X: the cancellation should read as the employee"),
    # ── M · ActorName(Q15):不持 hr.view 的本人读得出决定人的名字 ──
    ("M (Q15): the ActorName rule switched off",
     patch(ACT, "    v_hide boolean := NOT has_permission('module.hr.view');", "    v_hide boolean := false;"),
     "FIXTURE 245 M (Q15, the ActorName rule)"),
    # ── G · 发放的建立没有登记(一次结转在"之前"那一段里不见了)──
    ("G: leave grants' creation not registered", pre_drop("leave_grants", "created", "created_at"),
     "FIXTURE 245 G (carried forward, before the log)"),
    # ── T · M11:假别不再是集合(根键 code 配 'all' —— 一条都对不上,被拒)──
    ("T (M11): leave types no longer a collection",
     patch(SUBJ, subject_row("leave_types"), subject_row("leave_types").replace("'collection'", "'table'")),
     "FIXTURE 245 T: the reader was refused"),
    # ── H · 硬删:集合不从变更记录里找已经不在的行 ──
    ("H: a collection ignores rows that are only in the change log",
     patch(RT, "FROM change_log c WHERE c.table_name = s.root_table AND c.row_key IS NOT NULL;",
               "FROM change_log c WHERE c.table_name = s.root_table AND c.row_key IS NOT NULL AND false;"),
     "FIXTURE 245 H (added)"),
    # ── C · Q37:费用页够不到医疗报销 ──
    ("C (Q37): the medical claim dropped from the expense", hide("expense", 12), "FIXTURE 245 C · Q37"),
    # ── C · Q12:撤回拿 updated_by 猜人 ──
    ("C (Q12): the withdrawal guesses its person from updated_by",
     patch(PRE, pre_line("medical_claims", "stamp", "withdrawn_at"),
           pre_line("medical_claims", "stamp", "withdrawn_at").replace("NULL,", "'updated_by',", 1)),
     "FIXTURE 245 C (Q12): a withdrawal records no person"),
    # ── O · M1:仓库(只持 overtime_approve)进不来 ──
    ("O (M1): the overtime batch admits hr.view only",
     patch(SUBJ, "ARRAY['module.hr.view', 'action.overtime_enter', 'action.overtime_approve']", "ARRAY['module.hr.view']"),
     "FIXTURE 245 O (M1: the approver)"),
    # ── O · 硬删的加班行:行不再是这一批的成员 ──
    ("O: overtime lines dropped from the batch", hide("overtime_batch", 1), "FIXTURE 245 O (line added)"),
    # ── D · Q12:作废那一戳没有登记(丢弃与它的行不再是一次操作)──
    ("D (Q12): the voided-line stamp not registered", pre_drop("overtime_lines", "stamp", "voided_at"),
     "FIXTURE 245 D (the voided line"),
    # ── A · Q12:重开那一戳没有登记 ──
    ("A (Q12): the reopen stamp not registered", pre_drop("attendance_periods", "stamp", "reopened_at"),
     "FIXTURE 245 A (Q12): before the log only the latest reopening"),
    # ── A · 冻结那一戳没有登记(完成与它的行不再是一次操作)──
    ("A: the frozen-line stamp not registered", pre_drop("attendance_lines", "stamp", "frozen_at"),
     "FIXTURE 245 A: the completion and the two frozen lines"),
    # ── R · Q36 ──
    ("R (Q36): the medical claim links to its list again",
     "UPDATE document_types SET link_mode = 'list' WHERE key = 'medical_claim';\n", "FIXTURE 245 R (Q36): medical_claim"),
    ("R (Q36): overtime lines lose their batch link",
     patch(REC, "        v_dkey := 'overtime_batch'; v_route := '/hr/overtime'; v_mode := 'detail';\n", ""),
     "FIXTURE 245 R (Q36): an overtime line"),
]


def run(injection):
    src = F245.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    tmp = pathlib.Path("/tmp/claude-501/inj245.sql")
    tmp.parent.mkdir(parents=True, exist_ok=True)
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
code, out = run("")
ok = code == 0 and "全部通过" in out
print(f"{'✓' if ok else '✗'} clean 245 → {'green' if ok else out[-400:]}")
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
