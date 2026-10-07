#!/usr/bin/env python3
"""MES-3a:fixture 251 的故障注入 —— 每一格注入一处缺陷,fixture 251 必须在【它点名的那一臂】红。

做法照 MES-2 的 db/scripts/2026-10-06-mes2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;
注入随 ROLLBACK 消失。函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】
(INJECTION_DID_NOT_APPLY)—— 一格悄悄没换上的注入,会被读成"这一臂没咬人"。

跑法:python3 db/scripts/2026-10-06-mes3a-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 干净跑绿、每一格都红在它的那一臂;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F251 = next(ROOT.glob("db/fixtures/251-*.sql")).read_text()
assert F251.count("\nBEGIN;\n") == 1 and F251.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F251.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]

CEIL = "public.receipt_ceiling_check_internal(uuid, uuid)"
QUAR = "public.assert_quarantine_landing(text[], uuid)"
SET_IN = "public.set_inbound_safety_states(uuid, text[], text)"
SET_OUT = "public.set_output_safety_states(uuid, text[], text)"
GUARD = "public.guard_safety_state_rows()"
COMMIT = ("public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text)")
ROLLBACK = "public.rollback_processing_run_internal(uuid, text, uuid)"
TRANSFER = "public.create_stock_transfer(numeric, uuid, uuid, uuid, uuid, text, text)"
CREATE_IB = ("public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], "
             "text, text, text, text, uuid, numeric, text)")
RECV = ("public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, "
        "text, text, uuid, numeric, text)")
OUT_B = "public.create_output_batch(uuid, numeric, text, date, text, uuid, text, text, uuid)"


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
    ("PV", "V29 forgets the empty category list",
     patch_view("pending_values", "'nea_waste_categories'::text AS item_code", "'nea_waste_categories_x'::text AS item_code")),
    ("PV", "V34 stays after a quarantine location is marked",
     patch_view("pending_values", "WHERE (l.is_active AND l.is_quarantine)", "WHERE false")),
    ("PV", "V2 keeps listing a category whose ceiling was given",
     patch_view("pending_values", "WHERE ((l.licence_id = cc.id) AND (l.category_code = c.code))", "WHERE false")),
    ("PV", "pending values stop asking for each arm's code",
     patch_view("pending_values", "WHERE has_permission(permission);", "WHERE true;")),
    ("CEIL", "a receipt with no licence in force is judged against nothing and recorded as ceiling_not_set",
     patch_fn(CEIL, "v_outcome := 'licence_not_in_force';", "v_outcome := 'ceiling_not_set';")),
    ("CEIL", "an expired licence still counts",
     patch_fn("public.storage_licence_in_force(date)", "AND p_on BETWEEN cc.valid_from AND cc.valid_until", "")),
    ("CEIL", "the ceiling is never refused",
     patch_fn(CEIL, "IF v_lim IS NOT NULL AND v_cat_t > v_lim THEN", "IF false THEN")),
    ("CEIL", "the batch's own tonnes are not added before judging",
     patch_fn(CEIL, "IF v_lim IS NOT NULL AND v_cat_t > v_lim THEN", "IF v_lim IS NOT NULL AND v_cat_t - v_qt > v_lim THEN")),
    ("CEIL", "the field receipt skips the ceiling",
     patch_fn(RECV, "v_ceiling := receipt_ceiling_check_internal(v_id, NULL);", "")),
    ("CEIL", "a manual output batch skips the ceiling",
     patch_fn(OUT_B, "v_ceiling := receipt_ceiling_check_internal(NULL, v_id);", "")),
    ("CEIL", "a ceiling record can be changed",
     "DROP TRIGGER trg_receipt_ceiling_checks_append_only ON public.receipt_ceiling_checks;"),
    ("TOTAL", "the licence total is never judged",
     patch_fn(CEIL, "IF v_tot_lim IS NOT NULL AND v_tot_t > v_tot_lim THEN", "IF false THEN")),
    ("UNIT", "pieces read as kilograms",
     patch_fn("public.quantity_in_tonnes(numeric, text)", "WHEN 'kg' THEN p_qty / 1000", "WHEN 'kg' THEN p_qty / 1000 WHEN '件' THEN p_qty / 1000")),
    ("UNIT", "an unconvertible unit under a ceiling is let through",
     patch_fn(CEIL, "RAISE EXCEPTION 'STORAGE_CEILING_UNIT_NOT_CONVERTIBLE|%|%', v_code, v_cat;", "NULL;")),
    ("EXCEEDED", "an exceeded ceiling never shows",
     patch_view("storage_ceiling_status", "WHEN (COALESCE(on_hand_t, (0)::numeric) > limit_tonnes) THEN 'exceeded'::text",
                "WHEN false THEN 'exceeded'::text")),
    ("EXCEEDED", "the ceiling reminder reaches readers without inventory view",
     patch_view("operations_now", "'storage_ceiling_exceeded'::text AS item_type,\n            'module.inventory.view'::text AS permission",
                "'storage_ceiling_exceeded'::text AS item_type,\n            'module.inbound.view'::text AS permission")),
    ("DWELL", "every save restarts the clock (the old delete-and-reinsert)",
     patch_fn(SET_IN, """    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT p_inbound_batch_id, c FROM unnest(v_codes) c
     WHERE NOT EXISTS (SELECT 1 FROM inbound_batch_safety_states s
                        WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
                          AND s.safety_state_code = c);""",
              """    UPDATE inbound_batch_safety_states s SET ended_at = now(), end_reason = 'resave'
     WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL;
    INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code)
    SELECT p_inbound_batch_id, c FROM unnest(v_codes) c;""")),
    ("DWELL", "a state with no dwell period reads within",
     patch_view("safety_state_dwell", "WHEN (d.dwell_warning_days IS NULL) THEN 'not_set'::text", "WHEN (d.dwell_warning_days IS NULL) THEN 'within'::text")),
    ("DWELL", "a batch no longer on site is still reminded",
     patch_view("operations_now", "WHERE ((dw.dwell_status = 'past'::text) AND dw.on_site)", "WHERE (dw.dwell_status = 'past'::text)")),
    ("DWELL", "the dwell reminder asks the wrong code of an inbound batch",
     patch_view("safety_state_dwell", "has_permission('module.inbound.view'::text)", "true")
     + patch_view("operations_now", "FROM safety_state_dwell dw\n          WHERE ((dw.dwell_status = 'past'::text) AND dw.on_site)",
                  "FROM safety_state_dwell dw\n          WHERE ((dw.dwell_status = 'past'::text) AND dw.on_site AND false)")
     + patch_view("operations_now", "'safety_state_dwell'::text AS item_type,\n                CASE dw.batch_kind",
                  "'safety_state_dwell'::text AS item_type,\n                CASE 'never'::text")
     + patch_view("operations_now", "FROM safety_state_dwell dw\n          WHERE ((dw.dwell_status = 'past'::text) AND dw.on_site AND false)",
                  "FROM safety_state_dwell dw\n          WHERE ((dw.dwell_status = 'past'::text) AND dw.on_site)")),
    ("QUAR", "receipts ignore the quarantine rule",
     patch_fn(CREATE_IB, "PERFORM assert_quarantine_landing(p_safety_states, p_location_id);", "")),
    ("QUAR", "an unspecified location counts as quarantine",
     patch_fn(QUAR, "IF p_location_id IS NOT NULL\n       AND EXISTS", "IF p_location_id IS NULL OR EXISTS")),
    ("QUAR", "transfers ignore the quarantine rule",
     patch_fn(TRANSFER, "        p_to_location_id);\n", "        (SELECT l.id FROM storage_locations l WHERE l.is_quarantine LIMIT 1));\n")),
    ("QUAR", "a hazard on placed stock is refused instead of flagged",
     patch_fn(SET_IN, "    SELECT count(*) INTO v_n FROM inbound_batch_safety_states\n     WHERE inbound_batch_id = p_inbound_batch_id AND ended_at IS NULL;",
              "    IF EXISTS (SELECT 1 FROM unnest(v_codes) c WHERE c = 'swollen_leaking') AND EXISTS (SELECT 1 FROM inventory_movements mv JOIN storage_locations l ON l.id = mv.location_id WHERE mv.inbound_batch_id = p_inbound_batch_id AND NOT l.is_quarantine) THEN RAISE EXCEPTION 'QUARANTINE_LOCATION_REQUIRED|on-record'; END IF;\n    SELECT count(*) INTO v_n FROM inbound_batch_safety_states\n     WHERE inbound_batch_id = p_inbound_batch_id AND ended_at IS NULL;")),
    ("QUAR", "exposed stock is never listed",
     patch_view("quarantine_exposure", "AND (sd.requires_quarantine IS TRUE)", "AND false")),
    ("QUAR", "saving a location without the flag clears it",
     patch_fn("public.save_storage_location(text, text, text[], uuid, text, text, boolean)",
              "is_quarantine = COALESCE(p_is_quarantine, is_quarantine)", "is_quarantine = COALESCE(p_is_quarantine, false)")),
    ("HIST", "un-ticking needs no reason",
     patch_fn(SET_IN, "IF v_ending IS NOT NULL AND btrim(COALESCE(p_end_reason, '')) = '' THEN", "IF false THEN")
     + patch_fn(SET_IN, "SET ended_at = now(), ended_by = auth.uid(), end_reason = btrim(p_end_reason)",
                "SET ended_at = now(), ended_by = auth.uid(), end_reason = COALESCE(NULLIF(btrim(p_end_reason), ''), 'n/a')")),
    ("HIST", "an un-ticked state is deleted, not ended",
     patch_fn(SET_IN, """    UPDATE inbound_batch_safety_states s
       SET ended_at = now(), ended_by = auth.uid(), end_reason = btrim(p_end_reason)
     WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));""",
              """    UPDATE inbound_batch_safety_states s
       SET ended_at = now(), ended_by = NULL, end_reason = btrim(p_end_reason)
     WHERE s.inbound_batch_id = p_inbound_batch_id AND s.ended_at IS NULL
       AND NOT (s.safety_state_code = ANY (v_codes));""")),
    ("HIST", "direct writes are let through",
     patch_fn(GUARD, "IF row_security_active(TG_RELID) THEN", "IF false THEN")
     + 'CREATE POLICY "f251 inj insert" ON public.inbound_batch_safety_states AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);'),
    ("HIST", "a state can be deleted",
     patch_fn(GUARD, "IF TG_OP IN ('DELETE', 'TRUNCATE') THEN", "IF false THEN")
     + 'CREATE POLICY "f251 inj delete" ON public.inbound_batch_safety_states AS PERMISSIVE FOR DELETE TO authenticated USING (true);'),
    ("HIST", "a state can be ended twice",
     patch_fn(GUARD, "IF OLD.ended_at IS NOT NULL THEN", "IF false THEN")),
    ("HIST", "an open state can be rewritten",
     patch_fn(GUARD, "IF NEW.ended_at IS NULL\n           OR (to_jsonb(NEW)", "IF NEW.ended_at IS NULL\n           OR false AND (to_jsonb(NEW)")),
    ("HIST", "an output state needs no edit code",
     patch_fn(SET_OUT, "PERFORM require_permission('module.output.edit');", "")),
    ("RUN", "a discharge deletes what it resolves (no history)",
     patch_fn(COMMIT, """                UPDATE inbound_batch_safety_states s
                   SET ended_at = now(), ended_by = v_user_id, ended_by_run_id = v_run_id,""",
              """                UPDATE inbound_batch_safety_states s
                   SET ended_at = now(), ended_by = v_user_id, ended_by_run_id = NULL,""")),
    ("RUN", "the rollback leaves the batch discharged",
     patch_fn(ROLLBACK, """     WHERE s.created_by_run_id = p_run_id AND s.ended_at IS NULL;
    INSERT INTO inbound_batch_safety_states""", """     WHERE false;
    INSERT INTO inbound_batch_safety_states""")),
    ("RUN", "the rollback does not reopen what the run resolved",
     patch_fn(ROLLBACK, """      FROM inbound_batch_safety_states s
     WHERE s.ended_by_run_id = p_run_id""", """      FROM inbound_batch_safety_states s
     WHERE false AND s.ended_by_run_id = p_run_id""")),
    ("RUN", "the rollback ends a discharged state the run did not write",
     patch_fn(ROLLBACK, """     WHERE s.created_by_run_id = p_run_id AND s.ended_at IS NULL;
    INSERT INTO inbound_batch_safety_states""", """     WHERE s.inbound_batch_id IN (SELECT pi.inbound_batch_id FROM processing_inputs pi WHERE pi.run_id = p_run_id)
       AND s.safety_state_code = 'discharged_verified' AND s.ended_at IS NULL;
    INSERT INTO inbound_batch_safety_states""")),
    ("MOVE", "a direct movement insert is let through",
     "DROP TRIGGER trg_inventory_movements_through_function ON public.inventory_movements;\n"
     'CREATE POLICY "f251 inj movement" ON public.inventory_movements AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);'),
    ("TICKET", "the ticket's net reads the original gross, not the newest",
     patch_view("weighbridge_ticket_weights",
                "WHERE ((w.ticket_id = t.id) AND (w.role = 'gross'::text) AND (NOT (EXISTS ( SELECT 1\n                   FROM weighings x\n                  WHERE (x.corrects_id = w.id)))))",
                "WHERE ((w.ticket_id = t.id) AND (w.role = 'gross'::text) AND (w.corrects_id IS NULL))")),
]


def run(injection):
    sql = "BEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 251 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 251 全部通过")
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
    elif f"FIXTURE 251 {arm}" not in first:
        print(f"✗ {arm} · {name}: red in the wrong place — {first[:300]}")
        bad += 1
    else:
        arms.add(arm)
        print(f"✓ {arm} · {name}: {first[first.index('FIXTURE 251'):][:200]}")
missing = {"PV", "CEIL", "TOTAL", "UNIT", "EXCEEDED", "DWELL", "QUAR", "HIST", "RUN", "MOVE", "TICKET"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
