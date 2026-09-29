#!/usr/bin/env python3
"""AUDIT-TRAIL-1b-2:fixture 239 的故障注入 —— 每一格注入一处缺陷,fixture 239 必须在【它点名的那一臂】红。

做法照 1b-1 的 db/scripts/2026-09-29-at1b1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后 ——
注入随 fixture 的 ROLLBACK 一起消失,不需要 restore()。函数的注入用 pg_get_functiondef + replace + EXECUTE,并且
【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY):一处没换上的注入会让 fixture 照常变绿,读起来像"这一臂没有咬人"。

跑法:python3 db/scripts/2026-09-30-at1b2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一格都红在它的那一臂、干净跑绿;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1] if len(sys.argv) > 1 else "host=/tmp/claude-501/p2/s port=55439 user=postgres dbname=at1b"
ROOT = pathlib.Path(".")
F239 = next(ROOT.glob("db/fixtures/239-*.sql"))


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
SUBJ = "public.trail_subjects()"
MEM = "public.trail_subject_members()"
PRE = "public.trail_prelog_sources()"


def hide(row):
    """一行成员从"进审计记录"改成"垫脚石"(shown true → false)—— 等于把那张表从这条记录里拿掉"""
    assert row.endswith("'down', true, true)") or row.endswith("'down', true, false)"), row
    return patch(MEM, row, row.replace("'down', true,", "'down', false,"))


CASES = [
    # (名字, 注入, 必须出现在报错里的那一臂)
    ("M1 any-of → first code only (shipment)", patch(RT, "has_any_permission(s.view_codes)", "has_permission(s.view_codes[1])"),
     "FIXTURE 239 H (ship_goods only, M1)"),
    ("M3 page rule ignored (forwarder root must pass suppliers.view)",
     patch(RT, "(s.root_rule = 'table' AND NOT trail_row_visible", "(NOT trail_row_visible"), "FIXTURE 239 F (logistics only, M3)"),
    ("shipment: delivery-note issues not part of it",
     hide("('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true)"), "FIXTURE 239 H:"),
    ("quote: its history dropped",
     hide("('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true)"), "FIXTURE 239 Q:"),
    ("sales order: its history dropped",
     hide("('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 239 S:"),
    ("customer: contacts dropped",
     hide("('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 239 C:"),
    ("customer: every row visible (statement not Restricted)",
     patch(RT, "OR COALESCE(trail_row_visible(v_tabs[i], v_keys[i], v_img.image), false)", "OR true"),
     "FIXTURE 239 C: a statement must be a Restricted row"),
    ("supplier: approvals dropped",
     hide("('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{\"subject_type\": \"supplier\"}'::jsonb, 'down', true, true)"),
     "FIXTURE 239 P: the review / approval steps"),
    ("forwarder: rate quotes dropped",
     hide("('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 239 F: the logistics reader should see the details change and the rate quote"),
    ("container: milestones dropped",
     hide("('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true)"), "FIXTURE 239 T:"),
    ("lane: requirements dropped",
     hide("('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true)"),
     "FIXTURE 239 L: the lane"),
    ("port: lanes arriving at it dropped",
     hide("('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false)"),
     "FIXTURE 239 L: the destination port"),
    ("licence: gated on the logistics code",
     patch(SUBJ, "('company_licence',   ARRAY['module.suppliers.view']", "('company_licence',   ARRAY['module.logistics.view']"),
     "FIXTURE 239 L (licence)"),
    ("pre-log: order creation stamp not registered",
     patch(PRE, "        ('sales_orders',                   'created', 'created_at',   'created_by',   NULL, 'account'),\n", ""),
     "FIXTURE 239 D: the pre-log order creation"),
    ("pre-log: order history not registered",
     patch(PRE, "        ('sales_order_history',            'created', 'changed_at',   'changed_by',   NULL, 'account'),\n", ""),
     "FIXTURE 239 D: the pre-log order creation"),
    ("pre-log: so_issues registered too (shown twice)",
     patch(PRE, "        ('sales_orders',                   'created', 'created_at',   'created_by',   NULL, 'account'),\n",
           "        ('sales_orders',                   'created', 'created_at',   'created_by',   NULL, 'account'),\n"
           "        ('so_issues',                      'created', 'issued_at',    'issued_by',    NULL, 'account'),\n"),
     "FIXTURE 239 D: so_issues must not be rebuilt"),
    ("pre-log: supplier approval stamp not registered",
     patch(PRE, "        ('suppliers',                      'stamp',   'approved_at',  'approved_by',  NULL, 'account'),\n", ""),
     "FIXTURE 239 D: a supplier approved before the log"),
]


def run(injection):
    src = F239.read_text()
    i = src.index("BEGIN;\n") + len("BEGIN;\n")
    tmp = pathlib.Path("/tmp/claude-501/inj239.sql")
    tmp.write_text(src[:i] + injection + src[i:])
    p = subprocess.run(["psql", DSN, "-X", "-q", "-v", "ON_ERROR_STOP=1", "-f", str(tmp)], capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
code, out = run("")
ok = code == 0 and "全部通过" in out
print(f"{'✓' if ok else '✗'} clean 239 → {'green' if ok else out[-400:]}")
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
