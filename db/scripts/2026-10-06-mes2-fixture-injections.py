#!/usr/bin/env python3
"""MES-2:fixture 250 的故障注入 —— 每一格注入一处缺陷,fixture 250 必须在【它点名的那一臂】红。

做法照 MES-1 的 db/scripts/2026-10-06-mes1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;
注入随 ROLLBACK 消失。函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】
(INJECTION_DID_NOT_APPLY)—— 一格悄悄没换上的注入,会被读成"这一臂没咬人"。

跑法:python3 db/scripts/2026-10-06-mes2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 干净跑绿、每一格都红在它的那一臂;1 = 有一格没咬人或咬错了地方。
"""
import pathlib
import subprocess
import sys

DSN = sys.argv[1]
ROOT = pathlib.Path(".")
F250 = next(ROOT.glob("db/fixtures/250-*.sql")).read_text()
assert F250.count("\nBEGIN;\n") == 1 and F250.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F250.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]

CONFIRM_INTERNAL = "public.capture_confirm_internal(uuid, jsonb, jsonb, jsonb, uuid, text)"
SHARE_INTERNAL = "public.weighbridge_share_internal(uuid, uuid, uuid, numeric, text)"
GATE = "public.assert_receipt_reading_calibrated(uuid)"
CREATE_IB = ("public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], "
             "text, text, text, text, uuid, numeric, text)")


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
    ("DRAFT", "the dispatcher stops writing drafts",
     patch_fn("public.ingest_transform_row(bigint)", "IF v_state = 'transformed' AND v_draft THEN", "IF false THEN")),
    ("DRAFT", "connection_test starts producing drafts",
     "UPDATE public.ingest_data_classes SET creates_draft = true WHERE code = 'connection_test';"),
    ("AWAIT", "Process received ignores waiting rows whose class now has a transformer",
     patch_fn("public.ingest_process_pending(integer)", "OR (b.status = 'awaiting_transform'", "OR (false")),
    ("AWAIT", "Process received keeps re-handing rows of classes with no transformer",
     patch_fn("public.ingest_process_pending(integer)", "AND c.transform_function IS NOT NULL", "")),
    ("CONFIRM", "a changed value needs no reason",
     patch_fn(CONFIRM_INTERNAL, "AND btrim(COALESCE(p_reasons ->> k, '')) = '' THEN", "AND false THEN")),
    ("CONFIRM", "the device becomes changeable",
     patch_fn(CONFIRM_INTERNAL, "ARRAY['device', 'device_id',", "ARRAY['device_id', 'weight_kg_x',")),
    ("CONFIRM", "a changed value is not re-validated by the transformer",
     patch_fn(CONFIRM_INTERNAL, "EXECUTE format('SELECT public.%I($1)', v_fn) INTO v_out USING (d.proposed || v_ov);",
              "v_out := d.proposed || v_ov;")),
    ("CONFIRM", "anyone may confirm",
     patch_fn("public.confirm_capture_draft(uuid, jsonb, jsonb, jsonb)", "PERFORM require_permission('action.confirm_capture');", "")),
    ("CONFIRM", "a confirmed weighing can be changed by its owner",
     "DROP TRIGGER trg_weighings_append_only ON public.weighings;"),
    ("REJECT", "a rejection needs no reason",
     patch_fn("public.reject_capture_draft(uuid, text)", "IF p_reason IS NULL OR btrim(p_reason) = '' THEN", "IF false THEN")
     + "ALTER TABLE public.capture_drafts DROP CONSTRAINT capture_drafts_rejected_shape;"),
    ("REJECT", "a draft can be deleted",
     "DROP TRIGGER trg_capture_drafts_no_delete ON public.capture_drafts;"),
    ("CORRECT", "a superseded row can be corrected again",
     patch_fn("public.correct_weighing(uuid, numeric, text)", "IF EXISTS (SELECT 1 FROM weighings x WHERE x.corrects_id = v_orig.id) THEN",
              "IF false THEN") + "ALTER TABLE public.weighings DROP CONSTRAINT weighings_corrects_id_key;"),
    # 【一格没咬人的注入,记下来】"更正忘了读数的时刻"(v_captured := NULL)在这里咬不到:更正那一行也照抄了原行的现场时间范围,
    #   captured_at 经另一条路照样对;而原行没有现场时间时,它的 captured_at 是确认时的 now() —— 同一笔事务里 now() 不变,
    #   fixture 分不出两者。所以换成一格 fixture 看得见的:更正丢了读数的仪器。
    ("CORRECT", "a correction loses the reading's instrument",
     patch_fn("public.correct_weighing(uuid, numeric, text)", "VALUES ('manual', auth.uid(), v_orig.device_id,", "VALUES ('manual', auth.uid(), NULL::uuid,")),
    ("MANUAL", "a failed manual transform is kept instead of refused",
     patch_fn("public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb)",
              "RAISE EXCEPTION '%', COALESCE(v_err, 'CAPTURE_NOT_TRANSFORMED|' || v_state);",
              "RETURN jsonb_build_object('failed', v_err);")),
    ("MANUAL", "manual entry stops asking for the class's code",
     patch_fn("public.submit_manual_capture(text, jsonb, uuid, timestamp with time zone, timestamp with time zone, jsonb)",
              "PERFORM require_permission(v_class.manual_entry_code);", "")),
    ("CAP", "capacity is never checked",
     patch_fn(CONFIRM_INTERNAL, "IF v_cap IS NOT NULL AND", "IF false AND")),
    ("CAP", "the device's unit is ignored (t read as kg)",
     patch_fn(CONFIRM_INTERNAL, "WHEN 't' THEN 1000", "WHEN 't' THEN 1")),
    ("TICKET", "a net of zero or less is accepted",
     patch_fn(CONFIRM_INTERNAL, "IF v_gross - v_tare <= 0 THEN", "IF false THEN")),
    ("TICKET", "a third weighing lands on a complete ticket",
     patch_fn(CONFIRM_INTERNAL, "IF v_tk.completed_at IS NOT NULL THEN", "IF false THEN")),
    ("TICKET", "a shared ticket can be voided",
     patch_fn("public.void_weighbridge_ticket(uuid, text)",
              "IF EXISTS (SELECT 1 FROM weighbridge_ticket_shares s WHERE s.ticket_id = p_ticket_id) THEN", "IF false THEN")),
    ("SHARE", "an open ticket can be shared",
     patch_fn(SHARE_INTERNAL, "IF v_tk.completed_at IS NULL THEN", "IF false THEN")),
    ("SHARE", "direction is not checked",
     patch_fn(SHARE_INTERNAL, "IF p_inbound_batch_id IS NOT NULL AND v_tk.direction <> 'inbound' THEN", "IF false THEN")),
    ("SHARE", "shares are forced not to exceed net",
     patch_fn(SHARE_INTERNAL, "    INSERT INTO weighbridge_ticket_shares",
              "    IF (SELECT COALESCE(sum(s.kg), 0) FROM weighbridge_ticket_shares s WHERE s.ticket_id = p_ticket_id) + p_kg >\n"
              "       (SELECT w.net_kg FROM weighbridge_ticket_weights w WHERE w.ticket_id = p_ticket_id) THEN\n"
              "        RAISE EXCEPTION 'TICKET_OVER_SHARED';\n    END IF;\n    INSERT INTO weighbridge_ticket_shares")),
    ("RECEIPT", "a different receipt quantity needs no reason",
     patch_fn(CREATE_IB, "IF p_quantity IS DISTINCT FROM p_ticket_share_kg AND btrim(COALESCE(p_quantity_reason, '')) = '' THEN", "IF false THEN")),
    ("RECEIPT", "the reason is stored even when the quantity equals the share",
     patch_fn(CREATE_IB, "CASE WHEN p_quantity IS DISTINCT FROM p_ticket_share_kg THEN p_quantity_reason END", "p_quantity_reason")),
    ("CAL", "a voided calibration still counts",
     patch_view("weighing_calibration_all", " AND (ic.voided_at IS NULL)", "")),
    ("CAL", "a late-entered certificate does not count",
     patch_view("weighing_calibration_all", " AND (ic.calibrated_on <= ((w.captured_at AT TIME ZONE 'Asia/Singapore'::text))::date)",
                " AND (ic.calibrated_on <= ((w.captured_at AT TIME ZONE 'Asia/Singapore'::text))::date) AND (ic.recorded_at <= w.captured_at)")),
    ("CAL", "a failed calibration reads as in calibration",
     patch_fn("public.calibration_status_from(text, date, date)", "WHEN p_result = 'failed' THEN 'failed'", "WHEN p_result = 'failed' THEN 'in_calibration'")),
    ("GATE", "the gate refuses even with the switch empty",
     patch_fn(GATE, "IF v_since IS NULL THEN\n        RETURN;\n    END IF;", "v_since := COALESCE(v_since, DATE '2000-01-01');")),
    ("GATE", "a reading with no instrument passes",
     patch_fn(GATE, "IF r.status = 'not_recorded' THEN", "IF r.status = 'not_recorded' AND false THEN")
     + patch_fn(GATE, "ELSIF r.status <> 'in_calibration' THEN", "ELSIF r.status NOT IN ('in_calibration', 'not_recorded') THEN")),
    ("GATE", "a receipt with no weighing passes",
     patch_fn(GATE, "IF v_n = 0 THEN", "IF false THEN")),
    ("GATE", "the destruction certificate is not gated",
     patch_fn("public.issue_cod(uuid)", "PERFORM assert_receipt_reading_calibrated(v_cod.inbound_batch_id);", "")),
    ("GATE", "the pricing preview is not gated",
     patch_fn("public.preview_reprice_inbound_batch(uuid, numeric, text)", "PERFORM assert_receipt_reading_calibrated(p_inbound_batch_id);", "")),
    ("GATE", "receipts created before the switch date are refused too",
     patch_fn(GATE, "IF NOT FOUND OR (v_created AT TIME ZONE 'Asia/Singapore')::date < v_since THEN", "IF NOT FOUND THEN")),
    ("ARMS", "the pending-draft reminder reaches people who cannot confirm",
     patch_view("operations_now", "'action.confirm_capture'::text AS permission", "'module.processing.view'::text AS permission")),
    ("ARMS", "calibration-due also nags about reserved placeholders",
     patch_view("operations_now", "WHERE (ic.in_use AND (ic.status <> 'in_calibration'::text))", "WHERE (ic.status <> 'in_calibration'::text)")),
    ("PV", "V33 lists reserved placeholders",
     patch_view("pending_values", " AND (d.interface_status <> 'reserved'::text)", "")),
    ("PV", "pending values stop asking for each arm's code",
     patch_view("pending_values", "WHERE has_permission(permission);", "WHERE true;")),
    ("READ", "drafts readable without processing view",
     'DROP POLICY "capture_drafts select by permission" ON public.capture_drafts;\n'
     'CREATE POLICY "capture_drafts select by permission" ON public.capture_drafts AS PERMISSIVE FOR SELECT TO authenticated USING (true);'),
    ("READ", "the calibration base view becomes readable",
     "GRANT SELECT ON public.weighing_calibration_all TO authenticated;"),
    ("READ", "the inner confirm becomes callable",
     f"GRANT EXECUTE ON FUNCTION {CONFIRM_INTERNAL} TO authenticated;"),
]


def run(injection):
    sql = "BEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 250 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 250 全部通过")
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
    elif f"FIXTURE 250 {arm}" not in first:
        print(f"✗ {arm} · {name}: red in the wrong place — {first[:300]}")
        bad += 1
    else:
        arms.add(arm)
        print(f"✓ {arm} · {name}: {first[first.index('FIXTURE 250'):][:200]}")
missing = {"DRAFT", "AWAIT", "CONFIRM", "REJECT", "CORRECT", "MANUAL", "CAP", "TICKET", "SHARE", "RECEIPT", "CAL", "GATE",
           "ARMS", "PV", "READ"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
