#!/usr/bin/env python3
"""MES-3b:fixture 252 的故障注入 —— 每一格注入一处缺陷,fixture 252 必须在【它点名的那一臂】红。

做法照 MES-3a 的 db/scripts/2026-10-06-mes3a-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;
注入随 ROLLBACK 消失。函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】
(INJECTION_DID_NOT_APPLY)—— 一格悄悄没换上的注入,会被读成"这一臂没咬人"。
nea_waste_categories 在镜像检查两张清单里(Q3)那一格不在这里:它要的是一次 gate --offline,由 MES-3b 交回 §4 那一行记着。

跑法:python3 db/scripts/2026-10-07-mes3b-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 干净跑绿、每一格都红在它的那一臂;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1]
if "supabase" in DSN or "pooler" in DSN:
    sys.exit("refusing a live DSN — run against a throwaway rebuild")
ROOT = pathlib.Path(".")
F252 = next(ROOT.glob("db/fixtures/252-*.sql")).read_text()
assert F252.count("\nBEGIN;\n") == 1 and F252.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F252.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]

CTX = "public.label_print_context(text, uuid, text)"
OBJ = "public.label_object_data(text, uuid)"
PREVIEW = "public.label_print_preview(text, uuid, text)"
REC = "public.record_label_print(text, uuid, text, integer, text)"
RES = "public.resolve_scan_code(text, text, text)"
SHIP = "public.ship_order(uuid, date, jsonb)"
DOC = "public.shipment_document(uuid)"
QUEUE = "public.shipping_queue_rows()"
TRANSFER = "public.create_stock_transfer(numeric, uuid, uuid, uuid, uuid, text, text)"


def patch_fn(sig, old, new):
    o, n = old.replace("'", "''"), new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_functiondef('{sig}'::regprocedure);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{sig}'; END IF;
    EXECUTE d2;
END $inj$;
"""


def patch_view(name, old, new):
    o, n = old.replace("'", "''"), new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_viewdef('public.{name}'::regclass);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{name}'; END IF;
    EXECUTE format('CREATE OR REPLACE VIEW public.%I AS %s', '{name}', d2);
END $inj$;
"""


CASES = [
    # (臂, 名字, 注入 SQL)
    ("PRINT", "a reprint needs no reason",
     patch_fn(REC, "IF v_reprint AND NULLIF(btrim(p_reason), '') IS NULL THEN", "IF false THEN")),
    ("PRINT", "every print is recorded as a first print",
     patch_fn(REC, "v_reprint := v_n > 0;", "v_reprint := false;")),
    ("PRINT", "the default template is the last one, not the first",
     patch_fn(CTX, "ORDER BY t.sort_order, t.code", "ORDER BY t.sort_order DESC, t.code")),
    ("PRINT", "a template of another kind is accepted",
     patch_fn(CTX, "WHERE t.code = btrim(p_template) AND t.object_kind = p_kind AND t.is_active", "WHERE t.code = btrim(p_template)")),
    ("PRINT", "zero copies are let through to the table",
     patch_fn(REC, "IF v_copies < 1 THEN", "IF false THEN")),
    ("PRINT", "the snapshot drops what was printed",
     patch_fn(REC, "(v_ctx -> 'data') || jsonb_build_object('template', v_ctx -> 'template')",
              "jsonb_build_object('template', v_ctx -> 'template')")),
    ("PRINT", "a missing DG code refuses a print",
     patch_fn(REC, "    v_ctx := label_print_context(p_kind, p_id, p_template);",
              "    v_ctx := label_print_context(p_kind, p_id, p_template);\n"
              "    IF (v_ctx #>> '{data,dg_missing}')::boolean THEN RAISE EXCEPTION 'DG_REQUIRED'; END IF;")),
    ("GATE", "a location label asks for inbound view instead of inventory view",
     patch_fn(CTX, "WHEN 'storage_location' THEN 'module.inventory.view' END", "WHEN 'storage_location' THEN 'module.inbound.view' END")),
    ("GATE", "the object's own view code is never asked",
     patch_fn(CTX, "IF NOT has_permission(v_code) THEN", "IF false THEN")),
    ("NAME", "the label reads material and supplier names as the reader (the old RLS embed)",
     "ALTER FUNCTION " + PREVIEW + " SECURITY INVOKER;\n"
     "GRANT EXECUTE ON FUNCTION " + CTX + " TO authenticated;\n"
     "GRANT EXECUTE ON FUNCTION " + OBJ + " TO authenticated;\n"),
    ("LINK", "a restricted reader gets the id",
     patch_fn(RES, "v_outcome := 'restricted';\n                    v_id := NULL;", "v_outcome := 'restricted';")
     + patch_fn(RES, "'id', CASE WHEN v_outcome = 'found' THEN v_id END,", "'id', v_id,")),
    ("LINK", "a signed-out visit is logged (and fails on the missing person)",
     patch_fn(RES, "IF auth.uid() IS NULL THEN\n        RETURN jsonb_build_object('outcome', 'signed_out');\n    END IF;", "")),
    ("LINK", "/b/ also resolves locations",
     patch_fn(RES, "v_hint IS DISTINCT FROM 'b' THEN", "true THEN")),
    ("LINK", "old edit-page URLs on printed labels are no longer recognised",
     patch_fn(RES, "'/(inbound|output)/(", "'/(inboundx|outputx)/(")),
    ("RESOLVE", "whitespace and the scanner's return are not trimmed",
     patch_fn(RES, "btrim(COALESCE(p_value, ''), E' \\t\\r\\n')", "COALESCE(p_value, '')")
     + patch_fn(RES, "NULLIF(btrim(v_code, E' \\t\\r\\n'), '')", "NULLIF(v_code, '')")),
    ("RESOLVE", "percent-encoding is not decoded",
     patch_fn(RES, "decode(substr(t.tok, 2), 'hex')", "convert_to(t.tok, 'UTF8')")),
    ("RESOLVE", "a location code in another case is not found",
     patch_fn(RES, "WHERE lower(l.code) = lower(v_code)\n                       AND", "WHERE l.code = v_code\n                       AND")),
    ("LOG", "scan_events can be changed",
     "DROP TRIGGER trg_scan_events_append_only ON public.scan_events;"),
    ("LOG", "scan_events goes into the change log",
     "CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.scan_events "
     "FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');"),
    ("LOG", "a restricted scan row keeps the id",
     "ALTER TABLE public.scan_events DROP CONSTRAINT scan_events_id_only_when_found;\n"
     + patch_fn(RES, "v_outcome := 'restricted';\n                    v_id := NULL;", "v_outcome := 'restricted';")
     + patch_fn(RES, "CASE WHEN v_outcome = 'found' THEN v_id END, v_outcome)", "v_id, v_outcome)")),
    ("LOG", "label_prints is not change-logged",
     "DROP TRIGGER zzz_change_log ON public.label_prints;"),
    ("MOVE", "a transfer skips the bucket check",
     patch_fn(TRANSFER, "IF p_qty > v_have THEN", "IF false THEN")),
    ("MOVE", "a transfer skips the MES-3a quarantine gate",
     # 入腿那一批开着的状态读成空的(走 ELSE 那一支,进料批时 p_output_batch_id 为空)—— 闸照样调,但手里什么状态都没有
     patch_fn(TRANSFER, "CASE WHEN p_inbound_batch_id IS NOT NULL\n             THEN ARRAY(SELECT s.safety_state_code FROM inbound_batch_safety_states s",
              "CASE WHEN false\n             THEN ARRAY(SELECT s.safety_state_code FROM inbound_batch_safety_states s")),
    ("SHIP", "a mismatching scan is let through",
     patch_fn(SHIP, "IF upper(v_scanned) IS DISTINCT FROM upper(v_bcode) THEN", "IF false THEN")),
    ("SHIP", "a scan becomes required",
     patch_fn(SHIP, "IF v_scanned IS NOT NULL THEN", "IF true THEN")),
    ("SHIP", "the scan compares case-sensitively",
     patch_fn(SHIP, "IF upper(v_scanned) IS DISTINCT FROM upper(v_bcode) THEN", "IF v_scanned IS DISTINCT FROM v_bcode THEN")),
    ("SHIP", "a batch with an open quarantine-requiring state is refused at shipping",
     patch_fn(SHIP, "        v_scanned := NULLIF(", "        IF batch_quarantine_states(v_res.output_batch_id) IS NOT NULL THEN\n"
              "            RAISE EXCEPTION 'QUARANTINED';\n        END IF;\n        v_scanned := NULLIF(")),
    ("DG", "the label never says the DG code is missing",
     patch_fn(OBJ, "'dg_missing', r.battery AND r.dg_code IS NULL", "'dg_missing', false")),
    ("DG", "the shipment document never says the DG code is missing",
     patch_fn(DOC, "'dg_missing', COALESCE(mk.has_condition_axes, false) AND m.dg_code IS NULL,", "'dg_missing', false,")),
    ("HS", "the HS shape check is gone",
     "ALTER TABLE public.materials DROP CONSTRAINT materials_hs_code_shape;"),
    ("HS", "twelve digits are refused",
     "ALTER TABLE public.materials DROP CONSTRAINT materials_hs_code_shape;\n"
     "ALTER TABLE public.materials ADD CONSTRAINT materials_hs_code_shape CHECK "
     "(hs_code ~ '^[0-9]+(\\.[0-9]+)*$' AND length(replace(hs_code, '.', '')) BETWEEN 6 AND 11);"),
    ("QUAR", "the shipping queue drops the quarantine flag",
     patch_fn(QUEUE, "CASE WHEN ob.id IS NOT NULL THEN batch_quarantine_states(ob.id) END", "NULL::text")),
    ("QUAR", "the shipment document drops the quarantine flag",
     patch_fn(DOC, "'quarantine_states', batch_quarantine_states(ob.id))", "'quarantine_states', NULL::text)")),
    ("QUAR", "the shipment document drops the HS code",
     patch_fn(DOC, "'hs_code', m.hs_code,", "'hs_code', NULL::text,")),
    ("QUAR", "the shipping queue drops the DG code",
     patch_fn(QUEUE, "m.dg_code AS m_dg,", "NULL::text AS m_dg,")),
    ("PV", "V30 is gone",
     patch_view("pending_values", "'V30'::text AS value_code", "'V30x'::text AS value_code")),
    ("PV", "V31 never disappears",
     patch_view("pending_values", "mk.has_condition_axes AND (m.hs_code IS NULL))", "mk.has_condition_axes)")),
    ("PV", "V35 is shown to inventory readers",
     patch_view("pending_values", "'V35'::text AS value_code,\n            'module.materials.view'::text AS permission",
                "'V35'::text AS value_code,\n            'module.inventory.view'::text AS permission")),
]


def run(injection):
    sql = "BEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 252 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 252 全部通过")
arms = set()
for arm, name, inj in CASES:
    rc, out = run(inj)
    err = [ln for ln in out.splitlines() if "ERROR" in ln]
    first = err[0] if err else "(no error)"
    if rc == 0:
        print(f"✗ {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 252 {arm}" not in first:
        print(f"✗ {arm} · {name}: red in the wrong place — {first[:300]}")
        bad += 1
    else:
        arms.add(arm)
        print(f"✓ {arm} · {name}: {first[first.index('FIXTURE 252'):][:200]}")
missing = {"PRINT", "GATE", "NAME", "LINK", "RESOLVE", "LOG", "MOVE", "SHIP", "DG", "HS", "QUAR", "PV"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
