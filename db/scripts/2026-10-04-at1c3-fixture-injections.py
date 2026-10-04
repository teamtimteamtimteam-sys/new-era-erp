#!/usr/bin/env python3
"""AUDIT-TRAIL-1c-3:fixture 243 的故障注入 —— 每一格注入一处缺陷,fixture 243 必须在【它点名的那一臂】红。

做法照 1c-2 的 db/scripts/2026-10-04-at1c2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后
(fixture 随后把登记表改名、套上它的临时主语 —— 注入改的是被套的那一份,所以照样生效);注入随 ROLLBACK 消失。
函数的注入用 pg_get_functiondef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
成员行的原文从镜像里按前缀取出来(手抄一行的空格一错,注入就静悄悄地没换上)。

跑法:python3 db/scripts/2026-10-04-at1c3-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一格都红在它的那一臂、干净跑绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F243 = next(ROOT.glob("db/fixtures/243-*.sql"))
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
    new = re.sub(r"'(down|up|all)',(\s*)true,", r"'\1',\2false,", row, count=1)
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


MASKR = "public.change_log_mask_rules()"

CASES = [
    # ── M6 · M7(锁期与 GST 两块面板)──
    ("M6: the lock panel sees the whole settings row",
     patch(SUBJ, "'finance_settings',   'id', 'table', ARRAY['locked_before']),", "'finance_settings',   'id', 'table', NULL),"),
     "FIXTURE 243 L (M6 · Q4)"),
    ("M6: the GST panel sees the whole settings row",
     patch(SUBJ, "ARRAY['gst_registered', 'gst_registration_no']),", "NULL),"),
     "FIXTURE 243 G (M6)"),
    ("M7: period_closes no longer a whole-table member of the lock", hide("finance_lock", 1), "FIXTURE 243 L (key event: month closed — the close row)"),
    ("M7: the reader no longer expands 'all' members",
     patch(RT, "CONTINUE WHEN m.parent_table IS DISTINCT FROM s.root_table;", "CONTINUE WHEN true;"),
     "FIXTURE 243 L (key event: month closed — the close row)"),
    ("prelog: a close before the log not registered", PRE_ROW(pre_created("period_closes")), "FIXTURE 243 L (Q9-style"),
    ("op_key: one operation split per row (Q16)",
     patch(RT, "SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid AS a_g,", "SELECT c.seq AS a_seq, c.occurred_at AS a_at, 'L' || c.txid || c.row_key::text AS a_g,"),
     "FIXTURE 243 L: the close row and its lock move should be one operation"),
    ("Record: a month close no longer named \"Finance settings\"",
     patch(REF, "        v_label := 'Finance settings';", "        v_label := NULL;"),
     "FIXTURE 243 L: the summary page's Record for a month close"),
    # ── O · 公司资料 ──
    ("company profile: the bank account number no longer masked",
     patch(MASKR, "('company_profile', 'bank_account_no', 'code:data.view_banking'),", ""),
     "FIXTURE 243 O: a reader without data.view_banking saw the bank account number"),
    # ── Y · 年结 ──
    ("year close: its closing journal unreachable", hide("year_close", 1), "FIXTURE 243 Y (the closing journal"),
    ("year close: edits are no longer refused",
     'ALTER TABLE public.year_closes DISABLE TRIGGER trg_year_closes_immutable;\n', "FIXTURE 243 Y: a year close could be edited"),
    # ── J · 人工分录申请 ──
    ("journal request: the journal it posted dropped", hide("journal_request", 2), "FIXTURE 243 J (the journal it posted"),
    ("journal request: its approval homes elsewhere (not on the request)",
     patch(MEM, member("journal_request", 1), member("journal_request", 1).replace("'down', true, true)", "'down', true, false)")),
     "FIXTURE 243 J: the approval's Record should be the request"),
    ("journal request: a reader may edit it directly",
     'CREATE POLICY f243_inj ON public.journal_requests FOR UPDATE TO authenticated USING (true) WITH CHECK (true);\n'
     'GRANT UPDATE ON public.journal_requests TO authenticated;\n',
     "FIXTURE 243 J: a reader's direct edit of a journal request landed"),
    # ── E · 报销单与 M8 ──
    ("claim: the expense it recorded dropped", hide("expense_claim", 3), "FIXTURE 243 E (the expense it recorded"),
    ("M8: an empty code list treated as 'no code held' (the claimant refused)",
     patch(RT, "    IF cardinality(s.view_codes) = 0 THEN", "    IF false THEN"),
     "FIXTURE 243 E (the claimant, M8): the reader was refused"),
    ("M8: the 'page' edge no longer refused (a subject with no code opens to everyone)",
     patch(RT, "        IF s.root_rule IS DISTINCT FROM 'table' THEN\n            RAISE EXCEPTION 'TRAIL_NOT_PERMITTED|%', p_subject;\n        END IF;", "        NULL;"),
     "FIXTURE 243 E (M8): a subject with no page code and root rule 'page'"),
    ("Q4: the per-row read rule bypassed (the claimant sees the approval)",
     patch(RT, "COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false)", "true"),
     "FIXTURE 243 E (Q4)"),
    # ── T · 行内转账 ──
    ("transfer: its reversal journal unreachable", hide("bank_transfer", 2), "FIXTURE 243 T (the reversal journal"),
    ("transfer: the Record no longer names the transfer",
     patch(REF, "        v_label := 'Transfer ' || to_char((v_img ->> 'transfer_date')::date, 'DD/MM/YYYY') || ' · '", "        v_label := NULL || ' · '"),
     "FIXTURE 243 T: the summary page's Record for a transfer"),
    # ── W · 代扣税缴纳(Q30)──
    ("WHT: the reversal journal unreachable (reversed_by not followed)", hide("wht_remittance", 2), "FIXTURE 243 W (Q30: the reversal journal"),
    ("WHT: edits are no longer refused",
     'ALTER TABLE public.wht_remittances DISABLE TRIGGER trg_wht_remittances_append_only;\n', "FIXTURE 243 W: a WHT remittance could be edited"),
    # ── F · 现金预测(Q16)──
    ("Q16 before the log: the supersede stamp not registered", PRE_ROW(pre_line("cash_forecasts", "superseded_at")), "FIXTURE 243 F (Q16, before the log)"),
    ("forecast: a reader may edit it directly",
     'CREATE POLICY f243_inj2 ON public.cash_forecasts FOR UPDATE TO authenticated USING (true) WITH CHECK (true);\n'
     'GRANT UPDATE ON public.cash_forecasts TO authenticated;\n',
     "FIXTURE 243 F: a reader's direct edit of a frozen forecast landed"),
    # ── D · 折旧的分录 ──
    ("depreciation: the charges dropped from the run's journal", hide("journal_entry", 7), "FIXTURE 243 D: the depreciation journal should carry both"),
]


def run(injection):
    src = F243.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    tmp = pathlib.Path("/tmp/claude-501/inj243.sql")
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
code, out = run("")
ok = code == 0 and "全部通过" in out
print(f"{'✓' if ok else '✗'} clean 243 → {'green' if ok else out[-400:]}")
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
