#!/usr/bin/env python3
"""AUDIT-TRAIL-1b-3:fixture 240 的故障注入 —— 每一格注入一处缺陷,fixture 240 必须在【它点名的那一臂】红。

做法照 1b-2 的 db/scripts/2026-09-30-at1b2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后 ——
注入随 fixture 的 ROLLBACK 一起消失,不需要 restore()。函数的注入用 pg_get_functiondef + replace + EXECUTE,视图的用
pg_get_viewdef + replace + CREATE OR REPLACE VIEW,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY):
一处没换上的注入会让 fixture 照常变绿,读起来像"这一臂没有咬人"。

跑法:python3 db/scripts/2026-10-03-at1b3-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一格都红在它的那一臂、干净跑绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1] if len(sys.argv) > 1 else "host=/tmp/claude-501/p3/s port=55441 user=postgres dbname=at1b3"
ROOT = pathlib.Path(".")
F240 = next(ROOT.glob("db/fixtures/240-*.sql"))


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


def patch_view(view, old, new):
    o = old.replace("'", "''")
    n = new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_viewdef('{view}'::regclass);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{view}'; END IF;
    EXECUTE 'CREATE OR REPLACE VIEW {view} AS ' || d2;
END $inj$;
"""


RT = "public.record_trail(text, text, integer)"
SUBJ = "public.trail_subjects()"
MEM = "public.trail_subject_members()"
PRE = "public.trail_prelog_sources()"
SAVE = "public.save_storage_location(text, text, text[], uuid, text, text)"


def hide(row):
    """一行成员从"进审计记录"改成"垫脚石"(shown true → false)—— 等于把那张表从这条记录里拿掉"""
    assert row.endswith("'down', true, true)") or row.endswith("'down', true, false)"), row
    return patch(MEM, row, row.replace("'down', true,", "'down', false,"))


CASES = [
    # (名字, 注入, 必须出现在报错里的那一臂)
    ("material: attachments dropped",
     hide("('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 240 A: the attachment"),
    ("material: assay requirement dropped",
     hide("('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 240 A: the assay-requirement change"),
    ("location: allowed classes dropped",
     hide("('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 240 L: the class change"),
    ("Q13: classes back to delete-all + insert-all",
     patch(SAVE, "WHERE location_id = v_id AND NOT (classification_code = ANY (v_classes));",
           "WHERE location_id = v_id;"),
     "FIXTURE 240 L: a rename + one class swapped"),
    ("Q13: the location row written even when nothing changed",
     patch(SAVE, "\n           AND (code, name, zone, notes) IS DISTINCT FROM (p_code, p_name, p_zone, p_notes);", ";"),
     "FIXTURE 240 L: a save that changes nothing should write nothing (a row was rewritten)"),
    ("Q13: no permission check (a reader could save)",
     patch(SAVE, "    PERFORM require_permission('module.inventory.edit');\n", ""),
     "FIXTURE 240 L: a reader without module.inventory.edit saved a location"),
    ("metal price: gated on the pricing module instead of action.metal_prices",
     patch(SUBJ, "('metal_price',       ARRAY['action.metal_prices']", "('metal_price',       ARRAY['module.pricing.view']"),
     "FIXTURE 240 P (metal prices): the reader was refused"),
    ("formula: terms requests dropped",
     hide("('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 240 F: the two terms requests"),
    ("formula: every row visible (terms requests not Restricted)",
     patch(RT, "OR COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false)", "OR true"),
     "FIXTURE 240 F: terms requests must be Restricted rows"),
    ("task: its history dropped",
     hide("('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 240 T: task history rows missing"),
    ("task: participants dropped",
     hide("('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 240 T: the participant"),
    ("task: privacy ignored (anyone with the module reads a personal task)",
     patch(SUBJ, "('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL)",
           "('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'page', NULL)"),
     "FIXTURE 240 T (personal task, someone else)"),
    ("M2: task history actors read as accounts",
     patch(PRE, "('task_history',                   'created', 'changed_at',   'changed_by',   NULL, 'employee')",
           "('task_history',                   'created', 'changed_at',   'changed_by',   NULL, 'account')"),
     "FIXTURE 240 N: an employee id was read as an account"),
    ("pre-log: a step's creation not registered",
     patch(PRE, "        ('task_nodes',                     'created', 'created_at',   'created_by',   NULL, 'employee'),\n", ""),
     "FIXTURE 240 N: the task's creation, the step's creation or its tick stamp"),
    ("M6: the processing panel sees the whole row",
     patch(SUBJ, "ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']", "NULL"),
     "FIXTURE 240 S: processing_settings"),
    ("M5: the boolean root key not rebuilt from the row",
     patch(RT, "IF v_img.image ? s.root_key THEN", "IF false THEN"),
     "FIXTURE 240 S: processing_settings — the panel's own change is missing (M5"),
    # (曾经试过"收货面板的门换成加工的码":它不咬人 —— 那一块的码与 receiving_settings 自己的读规则是同一个码,
    #  第二道门照样拒;一个分不出两层的注入证不了什么,换成下面这一格)
    ("M6: the receiving panel sees the whole row",
     patch(SUBJ, "ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']", "NULL"),
     "FIXTURE 240 S: receiving_settings"),
    ("deleted records: the person not taken from the change log (customers)",
     patch_view("public.deleted_records", "l.table_name = 'customers'::text", "l.table_name = 'nothing'::text"),
     "FIXTURE 240 D: a deleted customer"),
    ("deleted records: a pre-log deletion given a person (a guess)",
     patch_view("public.deleted_records",
                "(l.table_name = 'suppliers'::text) AND (l.row_key = jsonb_build_object('id', s.id)) AND (l.op = 'UPDATE'::text) AND ('deleted_at'::text = ANY (l.changed_columns)) AND ((l.new ->> 'deleted_at'::text) IS NOT NULL)",
                "(l.table_name = 'suppliers'::text) AND (l.row_key = jsonb_build_object('id', s.id))"),
     "FIXTURE 240 D: a supplier deleted before the log"),
    ("deleted records: kinds no longer follow their own module",
     patch_view("public.deleted_records", "WHERE has_permission(permission)", "WHERE true"),
     "FIXTURE 240 D: each deleted kind must follow"),
]


def run(injection):
    src = F240.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    tmp = pathlib.Path("/tmp/claude-501/inj240.sql")
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
code, out = run("")
ok = code == 0 and "全部通过" in out
print(f"{'✓' if ok else '✗'} clean 240 → {'green' if ok else out[-400:]}")
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
