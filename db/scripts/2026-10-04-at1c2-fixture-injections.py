#!/usr/bin/env python3
"""AUDIT-TRAIL-1c-2:fixture 242 的故障注入 —— 每一格注入一处缺陷,fixture 242 必须在【它点名的那一臂】红。

做法照 1c-1 的 db/scripts/2026-10-03-at1c1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后
(fixture 随后把登记表改名、套上它的临时主语 —— 注入改的是被套的那一份,所以照样生效);注入随 ROLLBACK 消失。
函数的注入用 pg_get_functiondef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
成员行的原文从镜像里按前缀取出来(手抄一行的空格一错,注入就静悄悄地没换上)。

跑法:python3 db/scripts/2026-10-04-at1c2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一格都红在它的那一臂、干净跑绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F242 = next(ROOT.glob("db/fixtures/242-*.sql"))
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




def view_patch(old, new):
    """deleted_records 是一张视图:按 pg_get_viewdef 取它此刻的定义、替换、重建(并先断言替换真的发生了)"""
    o = old.replace("'", "''")
    n = new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_viewdef('public.deleted_records'::regclass);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|deleted_records'; END IF;
    EXECUTE 'CREATE OR REPLACE VIEW public.deleted_records AS ' || d2;
END $inj$;
"""


PRE_ROW = lambda line: patch(PRE, line + "\n", "")


def pre_line(table, column):
    m = re.search(r"\n(        \('%s',\s*'stamp',\s*'%s'[^\n]*)" % (re.escape(table), re.escape(column)),
                  (ROOT / "db/functions/trail_prelog_sources.sql").read_text())
    assert m, (table, column)
    return m.group(1)


def pre_created(table):
    m = re.search(r"\n(        \('%s',\s*'created'[^\n]*)" % re.escape(table), (ROOT / "db/functions/trail_prelog_sources.sql").read_text())
    assert m, table
    return m.group(1)


CASES = [
    ("sale: the stock movement of the sale dropped", hide("sale", 1), "FIXTURE 242 S (child: the stock movement"),
    ("sale: the attribution log dropped", hide("sale", 2), "FIXTURE 242 S (child: the attribution log)"),
    ("Q14: the sale's Record no longer links to its receivable page",
     patch(REC, "v_dkey := 'sale'; v_route := '/finance/receivables'; v_mode := 'detail';", "NULL;"),
     "FIXTURE 242 S (Q14): the sale's Record"),
    ("Q14: the sale is a home under the output batch again (its children walk past it)",
     patch(MEM, member("output_batch", 12), member("output_batch", 12).replace("'down', true,  false)", "'down', true,  true)")),
     "FIXTURE 242 S (Q14): the attribution log should home to the sale"),
    ("freight: its apportionment dropped", hide("freight", 1), "FIXTURE 242 F (child: the apportionment)"),
    ("freight: the reversal journal unreachable (both hops)",
     hide("freight", 4) + hide("freight", 5), "FIXTURE 242 F: the reversal journal is not on the freight document"),
    # 只拿掉运费单那一条的 home 咬不到:trail_row_record 的第 ③ 步(第一列指着单据的外键)恰好也落到运费单上 ——
    #   所以注入要同时把【竞争的那一条】(批次的成员)抬成 home,证 fixture 认的确实是"家在运费单",不是"碰巧走到运费单"
    ("freight: an allocation homes to the batch instead of its freight document",
     patch(MEM, member("freight", 1), member("freight", 1).replace("'down', true, true)", "'down', true, false)"))
     + patch(MEM, member("inbound_batch", 21), member("inbound_batch", 21).replace("'down', true,  false)", "'down', true,  true)")),
     "FIXTURE 242 F: a freight allocation should home"),
    ("Q9: the freight reversal stamp not registered", PRE_ROW(pre_line("freight_documents", "reversed_at")), "FIXTURE 242 F (Q9)"),
    ("asset: its cost entries dropped", hide("fixed_asset", 2), "FIXTURE 242 A (child: the cost entry)"),
    ("asset: its disposal requests dropped", hide("fixed_asset", 5), "FIXTURE 242 A (key event: the disposal request)"),
    ("Q10: the asset history before the log not registered", PRE_ROW(pre_created("fixed_asset_history")), "FIXTURE 242 A (Q10)"),
    ("statement: its lines dropped", hide("bank_statement", 1), "FIXTURE 242 B (child: its lines)"),
    ("statement: its reconciliation records dropped", hide("bank_statement", 3), "FIXTURE 242 B (the reconciliation record)"),
    ("Q6: deleted statements no longer listed in deleted_records",
     view_patch("'bank_statement'::text", "'bank_statement_x'::text"), "FIXTURE 242 B (Q6): a deleted statement should be listed"),
    ("Q9: the statement's reconciled stamp not registered", PRE_ROW(pre_line("bank_statements", "reconciled_at")), "FIXTURE 242 B (Q9)"),
    ("GST: the locked boxes dropped", hide("gst_period", 1), "FIXTURE 242 G (the boxes locked)"),
    ("GST: the filing requests dropped", hide("gst_period", 2), "FIXTURE 242 G (child: the filing request)"),
    ("Q22: the correction self-linked onto the original",
     patch(MEM, member("gst_period", 3), member("gst_period", 3) + ",\n        ('gst_period', 4, 'gst_periods', 'gst_periods', 'corrects_period_id', '{}'::jsonb, 'down', true, false)"),
     "FIXTURE 242 G (Q22)"),
    ("FX: its history dropped", hide("fx_rate", 1), "FIXTURE 242 X (child: its history"),
    ("Q7: a withdrawn rate needs more than the page's own code",
     patch(SUBJ, "('fx_rate',           ARRAY['module.finance.view'],", "('fx_rate',           ARRAY['data.view_deleted'],"),
     "FIXTURE 242 X (Q7"),
    ("pack: the newer pack self-linked onto the older (through superseded_by, upward)",
     patch(MEM, member("contract", 10), member("contract", 10) + ",\n        ('management_pack', 1, 'management_packs', 'management_packs', 'superseded_by', '{}'::jsonb, 'up', true, false)"),
     "FIXTURE 242 K: the newer pack's creation leaked"),
    ("contract: its grade specifications dropped", hide("contract", 1), "FIXTURE 242 C (child: a grade specification)"),
    # 拿掉审批那一行会先让"持全部码的人看得见那次决定"那一臂红 —— 注入要打在【每一行再过一次它自己那张表的读规则】上:
    #   一律看得见 → 不持 pricing.view 的合同读者读到了 CFO 的决定
    ("Q21: every row visible to every reader (the per-row read rule bypassed)",
     patch(RT, "COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false)", "true"),
     "FIXTURE 242 C (Q21): the CFO's decision should read Restricted"),
    ("payment request: a reader may edit it directly",
     'CREATE POLICY f242_inj ON public.payment_requests FOR UPDATE TO authenticated USING (true) WITH CHECK (true);\n'
     'GRANT UPDATE ON public.payment_requests TO authenticated;\n',
     "FIXTURE 242 P: a reader's direct edit of a payment request landed"),
    ("credit note: edits are no longer refused",
     'ALTER TABLE public.credit_notes DISABLE TRIGGER trg_credit_notes_append_only;\n',
     "FIXTURE 242 P: a credit note could be edited"),
]


def run(injection):
    src = F242.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    tmp = pathlib.Path("/tmp/claude-501/inj242.sql")
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
code, out = run("")
ok = code == 0 and "全部通过" in out
print(f"{'✓' if ok else '✗'} clean 242 → {'green' if ok else out[-400:]}")
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
