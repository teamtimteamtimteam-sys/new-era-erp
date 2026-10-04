#!/usr/bin/env python3
"""AUDIT-TRAIL-1d-1:fixture 244 的故障注入 —— 每一格注入一处缺陷,fixture 244 必须在【它点名的那一臂】红。

做法照 1c-3 的 db/scripts/2026-10-04-at1c3-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后
(fixture 随后把登记表改名、套上它的临时主语 —— 注入改的是被套的那一份,所以照样生效);注入随 ROLLBACK 消失。
函数的注入用 pg_get_functiondef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
成员行的原文从镜像里按前缀取出来(手抄一行的空格一错,注入就静悄悄地没换上)。

跑法:python3 db/scripts/2026-10-04-at1d1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一格都红在它的那一臂、干净跑绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F244 = next(ROOT.glob("db/fixtures/244-*.sql"))
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

LOT = "public.trail_log_only_tables()"
MCOL = "public.trail_member_columns()"
GATE = "public.trail_root_gate(text, text, jsonb)"
VIS = "public.trail_row_visible(text, jsonb, jsonb)"
CLR = "public.change_log_rows(date, date, text, text, uuid, boolean, bigint, integer, text[], boolean, boolean, text[])"
SAVE = "public.save_employee(uuid, jsonb, jsonb)"
ACT = "public.trail_actor(text, uuid, uuid)"

CASES = [
    # ── A · M9 ──
    ("M9: the safe projection widened (a column outside it reaches the trail)",
     patch(LOT, "ARRAY['id', 'email', 'created_at', 'banned_until']", "ARRAY['id', 'email', 'created_at', 'banned_until', 'last_sign_in_at']"),
     "FIXTURE 244 A (M9): the account's context"),
    ("M9: the declared read rule ignored (account events readable without manage_permissions)",
     patch(VIS, "RETURN p_key IS NOT NULL AND has_permission(v_code);", "RETURN p_key IS NOT NULL;"),
     "FIXTURE 244 E: account events should be Restricted"),
    ("M9: the pre-log creation said again beside ACCOUNT_CREATE",
     patch(RT, "c.op IN ('INSERT', 'ACCOUNT_CREATE')", "c.op = 'INSERT'"),
     "FIXTURE 244 A (M9): the creation appears twice"),
    # ── C · M10 ──
    ("M10: the account's employee member no longer limited to user_id",
     patch(MCOL, "('account', 4, ARRAY['user_id'])", "('account', 99, ARRAY['user_id'])"),
     "FIXTURE 244 C (M10): an HR edit"),
    # ── K · M11 ──
    ("M11: collections not expanded (a dictionary has no root row)",
     patch(RT, "v_coll := s.root_rule = 'collection';", "v_coll := false;"),
     "FIXTURE 244 K: the reader was refused"),
    # ── G · M12 ──
    ("M12: the gate not consulted (the reviewed employee reads the drafts)",
     patch(RT, "           OR (v_gate IS NOT NULL AND NOT trail_root_gate(v_gate, s.root_table, v_img.image)) THEN", "           THEN"),
     "FIXTURE 244 G (M12: the reviewed employee)"),
    ("M12: an unknown gate admits everyone",
     patch(GATE, "        ELSE false", "        ELSE true"),
     "FIXTURE 244 G (M12: an unknown gate"),
    # ── Q · Q13 ──
    ("Q13: the summary reader no longer re-checks row rules",
     patch(CLR, "        IF NOT v_vis AND NOT row_restricted THEN", "        IF false THEN"),
     "FIXTURE 244 Q (Q13): a reader without view_pay"),
    # ── S · save_employee ──
    ("save_employee: the history row no longer written in the same call",
     patch(SAVE, "    IF p_history IS NOT NULL AND jsonb_typeof(p_history) = 'object' THEN", "    IF false THEN"),
     "FIXTURE 244 S: a hire must write"),
    # 两道都拿掉才咬得到:employees 自己还有一道语句级的写守卫(enforce_write_permission,FOR EACH STATEMENT)按名拒 ——
    #   第一版只拿掉 require_permission,这一格没有红(实测),那一臂其实被两道守着。拿掉两道,一次被 RLS 挡住的编辑就是一次
    #   成功的空操作,而那一臂必须红。
    ("save_employee: no permission check and no table write guard (an RLS-blocked edit is a silent no-op)",
     patch(SAVE, "    PERFORM require_permission('module.hr.edit');\n", "")
     + "ALTER TABLE public.employees DISABLE TRIGGER enforce_write_permission;\n",
     "FIXTURE 244 S: without module.hr.edit"),
    # ── R · Q22 ──
    ("Q22: grants no longer a member of the role page", hide("role", 2), "FIXTURE 244 R (granted to the account)"),
    ("Q22: a grant's home no longer the account",
     patch(MEM, member("account", 1), member("account", 1).replace("true, true)", "true, false)")),
     "FIXTURE 244 R (Q22): a grant's home"),
    # ── E · 员工页的镜像 ──
    ("mirror: grants under the employee's account dropped", hide("employee", 9), "FIXTURE 244 E (grant visible to HR)"),
    # ── P · 审批方针 ──
    ("M6: the approval-policy panel sees the whole settings row",
     patch(SUBJ, "ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']", "NULL"),
     "FIXTURE 244 P (M6)"),
    ("M7: the policy history no longer a whole-table member", hide("approval_policy", 1), "FIXTURE 244 P (M7"),
    # ── I · 导入批次 ──
    # 同样两道:主语的页面码,与 import_batches 自己的读规则('table')。第一版只换了页面码,读规则照样把人事读者挡在外面,
    #   这一格没有红(实测)—— 换码、同时把根规则改成 'page'(不再问表的规则),那一臂必须红。
    ("import batch: gated by the wrong code and the table rule skipped",
     patch(SUBJ, "('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table'",
           "('import_batch',      ARRAY['module.hr.view'],        'import_batches',     'id', 'page'"),
     "FIXTURE 244 I (no bulk_import)"),
    # ── D · 删掉的记录 ──
    ("Q25: deleted roles missing from deleted_records",
     view_patch("'role'::text", "'rolex'::text"),
     "FIXTURE 244 D: four deleted kinds"),
    # ── N · 匿名化 ──
    ("Q30: an anonymised person read by name",
     patch(ACT, "        RETURN jsonb_build_object('state', 'anonymised');", "        RETURN jsonb_build_object('state', 'person', 'name', 'x');"),
     "FIXTURE 244 N: an anonymised person"),
]


def run(injection):
    src = F244.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    tmp = pathlib.Path("/tmp/claude-501/inj244.sql")
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
code, out = run("")
ok = code == 0 and "全部通过" in out
print(f"{'✓' if ok else '✗'} clean 244 → {'green' if ok else out[-400:]}")
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
