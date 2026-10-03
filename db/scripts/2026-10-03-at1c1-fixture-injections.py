#!/usr/bin/env python3
"""AUDIT-TRAIL-1c-1:fixture 241 的故障注入 —— 每一格注入一处缺陷,fixture 241 必须在【它点名的那一臂】红。

做法照 1b-3 的 db/scripts/2026-10-03-at1b3-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后
(fixture 随后把登记表改名、套上它的临时主语 —— 注入改的是被套的那一份,所以照样生效);注入随 ROLLBACK 消失。
函数的注入用 pg_get_functiondef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
成员行的原文从镜像里按前缀取出来(手抄一行的空格一错,注入就静悄悄地没换上)。

跑法:python3 db/scripts/2026-10-03-at1c1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一格都红在它的那一臂、干净跑绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F241 = next(ROOT.glob("db/fixtures/241-*.sql"))
MEMBERS_SRC = (ROOT / "db/functions/trail_subject_members.sql").read_text()


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
REF = "public.trail_ref_label(text, text, text)"
REFS = "public.trail_refs(text, jsonb, jsonb, jsonb)"


def member(subject, ord_):
    """镜像里那一行成员的原文(到右括号为止)"""
    m = re.search(r"\('%s',\s*%d,[^\n]*?\)(?=,?\n)" % (re.escape(subject), ord_), MEMBERS_SRC)
    assert m, (subject, ord_)
    return m.group(0)


def hide(subject, ord_):
    """一行成员从"进审计记录"改成"垫脚石"(shown true → false)—— 等于把那张表从这条记录里拿掉"""
    row = member(subject, ord_)
    new = re.sub(r"'(down|up)',(\s*)true,", r"'\1',\2false,", row, count=1)
    assert new != row, row
    return patch(MEM, row, new)


CASES = [
    ("M7: an 'all' member never expands",
     patch(RT, "CONTINUE WHEN m.parent_table IS DISTINCT FROM s.root_table;", "CONTINUE;"),
     "FIXTURE 241 M: both period_closes inserts"),
    ("M7: rows known only from the log are not found",
     patch(RT, "WHERE c.table_name = m.table_name AND c.row_key IS NOT NULL AND COALESCE(c.new, c.old) @> m.match;", "WHERE false;"),
     "FIXTURE 241 M: both period_closes inserts"),
    ("M7: the summary page's home walk ignores 'all' members",
     patch(REC, "(tm.hop = 'all' AND EXISTS", "(false AND EXISTS"),
     "FIXTURE 241 M: the summary page's Record"),
    ("Q16: op_key is the entry number of one record, not the operation",
     patch(RT, "op_key := r.a_g;", "op_key := 'E' || r.e_n;"),
     "FIXTURE 241 P (Q16)"),
    ("Q12: employee references return the name to anyone",
     patch(REF, "IF p_table = 'employees' AND p_column = 'id' THEN", "IF false THEN"),
     "FIXTURE 241 E (Q12)"),
    ("Q33: the journal's lines expanded after its reversal (the reversal's lines leak)",
     patch(MEM, member("journal_entry", 1), member("journal_entry", 1).replace("('journal_entry', 1,", "('journal_entry', 9,")),
     "FIXTURE 241 J (Q33)"),
    ("journal: the reversal hop dropped",
     hide("journal_entry", 2),
     "FIXTURE 241 J: the reversal journal is not on the original"),
    ("Q32: the journal request's approval trail dropped",
     hide("journal_entry", 6),
     "FIXTURE 241 J (Q32: auto_approved"),
    ("invoice: its requests dropped",
     hide("invoice", 3),
     "FIXTURE 241 I (the void request)"),
    ("credit note: its lines dropped",
     hide("credit_note", 1),
     "FIXTURE 241 C (child"),
    ("payment: its allocations dropped",
     hide("payment", 1),
     "FIXTURE 241 P (child"),
    ("Q31: the mirror payment (one hop up) dropped",
     hide("payment", 3),
     "FIXTURE 241 P (Q31)"),
    ("Q13: the documents a request settles not resolved",
     patch(REFS, "IF p_table = 'payment_requests' THEN", "IF false THEN"),
     "FIXTURE 241 P (Q13)"),
    ("expense: its attachments dropped",
     hide("expense", 2),
     "FIXTURE 241 E (child"),
    ("Q31: the mirror expense (one hop up) dropped",
     hide("expense", 4),
     "FIXTURE 241 E (Q31)"),
    ("M3: the payable page checks the batch's own read rule",
     patch(SUBJ, "'inbound_batches',    'id', 'page',", "'inbound_batches',    'id', 'table',"),
     "FIXTURE 241 B (M3, finance-only reader): the reader was refused"),
    ("M6: the payable sees the whole batch row",
     patch(SUBJ, """ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']""", "NULL"),
     "FIXTURE 241 B (M6)"),
    ("payable: its price history dropped",
     hide("payable", 5),
     "FIXTURE 241 B (child: price history)"),
    ("Q15: the payable no longer reaches the reversal of its journal",
     hide("payable", 8),
     "FIXTURE 241 Q15: the reversal of the batch's purchase journal"),
    ("Q9: the invoice's void stamp not registered",
     patch(PRE, "        ('invoices',                       'stamp',   'voided_at',    'voided_by',    ARRAY['status', 'void_reason'], 'account'),\n", ""),
     "FIXTURE 241 S (Q9)"),
]


def run(injection):
    src = F241.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    tmp = pathlib.Path("/tmp/claude-501/inj241.sql")
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
code, out = run("")
ok = code == 0 and "全部通过" in out
print(f"{'✓' if ok else '✗'} clean 241 → {'green' if ok else out[-400:]}")
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
