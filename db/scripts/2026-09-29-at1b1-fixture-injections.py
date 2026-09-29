#!/usr/bin/env python3
"""AUDIT-TRAIL-1b-1:fixture 237 / 238 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。

做法照 AT-1a 的 fixture 236 注入(db/scripts/2026-09-29-at1a-fixture236-injections.py):每一格是一段 SQL,插在 fixture 自己的
BEGIN 之后 —— 于是注入随 fixture 的 ROLLBACK 一起消失,不需要手写 restore()(AGENTS.md「故障注入的还原完整性」那一节的病根)。
函数的注入用 pg_get_functiondef + replace + EXECUTE,并且【先断言替换真的发生了】:一处没替换上的注入会让 fixture 照常变绿,
读起来像"这一臂没有咬人",而实际是"我根本没注入" —— 那一格因此自己先红(INJECTION_DID_NOT_APPLY)。

跑法:python3 db/scripts/2026-09-29-at1b1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一格都红在它的那一臂、两支干净跑都绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1] if len(sys.argv) > 1 else "host=/tmp/claude-501/pgs port=55439 user=postgres dbname=at1b"
ROOT = pathlib.Path(".")
F237 = next(ROOT.glob("db/fixtures/237-*.sql"))
F238 = next(ROOT.glob("db/fixtures/238-*.sql"))


def patch(fn_sig, old, new):
    """把一个函数的定义里的 old 换成 new,再建回去;换不上就先红。"""
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
CASES = [
    # (名字, fixture, 注入, 必须出现在报错里的那一臂)
    ("M1 any-of → first code only", F237, patch(RT, "has_any_permission(s.view_codes)", "has_permission(s.view_codes[1])"), "FIXTURE 237 M1"),
    ("M2 employee actor read as account", F237, patch(RT, "p.by_kind = 'employee'", "false"), "FIXTURE 237 M2"),
    ("M3 page rule ignored (root must pass its table rule)", F237,
     patch(RT, "(s.root_rule = 'table' AND NOT trail_row_visible", "(NOT trail_row_visible"), "FIXTURE 237 M3"),
    ("M4 stepping stones shown", F237, patch(RT, "v_shown := array_append(v_shown, m.shown);", "v_shown := array_append(v_shown, true);"), "FIXTURE 237 M4"),
    ("M4 no upward hop", F237, patch(RT, "IF m.hop = 'up' THEN", "IF false THEN"), "FIXTURE 237 M4"),
    ("M5 root key kept as text", F237,
     patch(RT, "v_root := jsonb_build_object(s.root_key, v_img.image -> s.root_key);", "NULL;"), "FIXTURE 237 M5"),
    ("M6 root columns ignored", F237, patch(RT, "v_rcols := s.root_columns;", "v_rcols := NULL;"), "FIXTURE 237 M5/M6"),
    ("A  names never restricted", F237,
     patch("public.trail_actor(text, uuid, uuid)", "v_hide boolean := NOT has_permission('module.hr.view');", "v_hide boolean := false;"),
     "FIXTURE 237 A (PO)"),
    ("A  own name restricted too", F237,
     patch("public.trail_actor(text, uuid, uuid)", "v_id IS DISTINCT FROM current_user_employee()", "true"),
     "the reader should still see his own name"),
    ("B  no upward hop (old rows lost)", F238, patch(RT, "IF m.hop = 'up' THEN", "IF false THEN"), "FIXTURE 238 B1"),
    ("B6 stepping stones shown", F238, patch(RT, "v_shown := array_append(v_shown, m.shown);", "v_shown := array_append(v_shown, true);"),
     "FIXTURE 238 B6"),
    ("J  reversal member dropped", F238,
     patch("public.trail_subject_members()", "('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false)",
           "('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  false, false)"),
     "FIXTURE 238 B1"),
    ("K  assays not shown", F238,
     patch("public.trail_subject_members()", "('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true)",
           "('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', false, true)"),
     "FIXTURE 238 K1-K3/K5"),
    ("K6 stocktake counts dropped", F238,
     patch("public.trail_subject_members()", "('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false)",
           "('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', false, false)"),
     "FIXTURE 238 K6"),
    ("H  every row visible", F238, patch(RT, "OR COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false)", "OR true"),
     "FIXTURE 238 H"),
    ("N  run never ended", F238,
     patch("public.trail_ref_label(text, text, text)", "'ended', v_img ->> 'deleted_at' IS NOT NULL", "'ended', false"),
     "FIXTURE 238 N: the input of a rolled-back run"),
    ("Q  written-off root refused", F238,
     patch(RT, "    IF v_img.image IS NULL\n       OR (s.root_rule", "    IF v_img.image IS NULL OR v_img.image ->> 'deleted_at' IS NOT NULL\n       OR (s.root_rule"),
     # 注销了的批次第一次被读是在 B3(它的逐行对照),所以这一格红在 B3 —— 那正是它该红的第一处
     "FIXTURE 238 B3: {\"error\": \"TRAIL_NOT_PERMITTED"),
    ("S  posted_at stamp not registered", F238,
     patch("public.trail_prelog_sources()", "('stocktakes',                     'stamp',   'posted_at',    NULL,           ARRAY['status'], 'account'),", ""),
     "FIXTURE 238 S: a pre-22/09 posting"),
    ("W  amount not masked", F238,
     patch("public.change_log_mask_rules()", "        ('warehouse_requests', 'amount_base', 'code:data.view_prices'),\n", ""),
     "FIXTURE 238 W: the amount should be Restricted"),
    ("W  read rule back to finance only", F238,
     """DROP POLICY "warehouse_requests select by permission" ON public.warehouse_requests;
CREATE POLICY "warehouse_requests select by permission" ON public.warehouse_requests AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
""", "FIXTURE 238 W: an inventory reader was refused"),
]


def run(fixture, injection):
    src = fixture.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    tmp = pathlib.Path("/tmp/claude-501/inj.sql")
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
for f in (F237, F238):
    code, out = run(f, "")
    ok = code == 0 and "全部通过" in out
    print(f"{'✓' if ok else '✗'} clean {f.name[:3]} → {'green' if ok else out[-400:]}")
    bad += 0 if ok else 1
for name, f, inj, expect in CASES:
    code, out = run(f, inj)
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
