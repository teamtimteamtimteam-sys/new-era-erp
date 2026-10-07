#!/usr/bin/env python3
"""MES-4a:fixture 253 的故障注入 —— 每一格注入一处缺陷,fixture 253 必须在【它点名的那一臂】红。

做法照 MES-3b 的 db/scripts/2026-10-07-mes3b-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 253 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 253 <臂>",
或者它发生时最后打出的那一臂就是 <臂>(注入让一句直接调用的函数当场抛出 —— 那一句就住在这一臂里)。
跑法:python3 db/scripts/2026-10-07-mes4a-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 干净跑绿、每一格都红在它的那一臂、每一臂都至少红过一次;1 = 否则。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
if "supabase" in DSN or "pooler" in DSN:
    sys.exit("refusing a live DSN — run against a throwaway rebuild")
ROOT = pathlib.Path(".")
F = next(ROOT.glob("db/fixtures/253-*.sql")).read_text()
assert F.count("\nBEGIN;\n") == 1 and F.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]

COMMIT = ("public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, "
          "timestamp with time zone, text, uuid, jsonb, uuid)")
HDR = "public.assert_run_header(date, timestamp with time zone, timestamp with time zone, text)"
EQ = "public.assert_run_equipment(text, uuid, date)"
RVI = "public.record_run_value_internal(uuid, text, jsonb, text, bigint, text)"
RRV = "public.record_run_value(uuid, text, jsonb)"
REC_CHK = "public.run_event_check(text, timestamp with time zone, numeric, text, text)"
COE = "public.correct_run_event(bigint, text, timestamp with time zone, numeric, text, text, text, boolean, text)"
CRL = "public.correct_run_loss(bigint, numeric, text)"
CRV = "public.create_recipe_version(uuid, jsonb, text)"
CRB = "public.close_run_balance(uuid, text)"
CRH = "public.correct_run_header(uuid, text, text, text)"
CW = "public.correct_weighing(uuid, numeric, text)"
GPL = "public.guard_processing_run_losses()"
GOE = "public.guard_operation_type_equipment()"
GOF = "public.guard_operation_type_field()"
UNCL = "public.processing_runs_unclosed_balance(date)"
ALLOC = "public.allocate_processing_costs(uuid, text)"
MEMB = "public.trail_subject_members()"
TRAIL = "public.record_trail(text, text, integer)"


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
    # ── HDR ──
    ("HDR", "the start time is not required",
     patch_fn(HDR, "IF p_started_at IS NULL OR p_ended_at IS NULL THEN", "IF p_started_at IS NULL AND p_ended_at IS NULL THEN")),
    ("HDR", "an end before the start is accepted", patch_fn(HDR, "IF p_ended_at <= p_started_at THEN", "IF false THEN")),
    ("HDR", "an end in the future is accepted", patch_fn(HDR, "IF p_ended_at > now() THEN", "IF false THEN")),
    ("HDR", "the process date may be any day",
     patch_fn(HDR, "IF p_process_date IS NOT NULL AND (p_process_date < v_from OR p_process_date > v_to) THEN", "IF false THEN")),
    ("HDR", "the table's insert gate is gone", "DROP TRIGGER trg_processing_runs_header ON public.processing_runs;"),
    ("HDR", "the header gate also watches UPDATE (old runs frozen)",
     "DROP TRIGGER trg_processing_runs_header ON public.processing_runs;\n"
     "CREATE TRIGGER trg_processing_runs_header BEFORE INSERT OR UPDATE ON public.processing_runs "
     "FOR EACH ROW EXECUTE FUNCTION public.guard_processing_run_header();"),
    # ── MACH ──
    ("MACH", "a vehicle can be linked", patch_fn(GOE, "IF v_cat IS DISTINCT FROM 'equipment' THEN", "IF false THEN")),
    ("MACH", "a linked operation does not require a machine",
     patch_fn(EQ, "RAISE EXCEPTION 'EQUIPMENT_REQUIRED_FOR_OPERATION|%', p_operation_type_code", "RAISE NOTICE 'inj %', p_operation_type_code")),
    ("MACH", "a disposed machine still counts as linked",
     patch_fn(EQ, "WHERE l.operation_type_code = p_operation_type_code AND fa.status <> 'disposed';",
              "WHERE l.operation_type_code = p_operation_type_code;")),
    ("MACH", "any machine is accepted",
     patch_fn(EQ, "RAISE EXCEPTION 'EQUIPMENT_NOT_LINKED_TO_OPERATION|%|%', v_eq.code, p_operation_type_code",
              "RAISE NOTICE 'inj % %', v_eq.code, p_operation_type_code")),
    # ── FIELD ──
    ("FIELD", "an out-of-range value is not flagged",
     patch_fn(RVI, "CASE WHEN v_f.has_range THEN v_f.range_min END, CASE WHEN v_f.has_range THEN v_f.range_max END", "NULL, NULL")),
    ("FIELD", "an out-of-range value is refused",
     patch_fn(RVI, "    INSERT INTO processing_run_values (run_id,",
              "    IF v_f.has_range AND (v_num < v_f.range_min OR v_num > v_f.range_max) THEN RAISE EXCEPTION 'RUN_VALUE_OUT_OF_RANGE'; END IF;\n"
              "    INSERT INTO processing_run_values (run_id,")),
    ("FIELD", "a retired field still takes values", patch_fn(RVI, "IF NOT v_f.is_active THEN", "IF false THEN")),
    ("FIELD", "a second value for a field is accepted",
     patch_fn(RVI, "RAISE EXCEPTION 'RUN_VALUE_ALREADY_RECORDED|%', p_field_code;", "NULL;")),
    ("FIELD", "values can be overwritten", "DROP TRIGGER trg_processing_run_values_append_only ON public.processing_run_values;"),
    ("FIELD", "a field can be deleted", patch_fn(GOF, "IF TG_OP = 'DELETE' THEN", "IF false THEN")),
    ("FIELD", "a used field can change type",
     patch_fn(GOF, "RAISE EXCEPTION 'OPERATION_FIELD_IN_USE|%|%', OLD.operation_type_code, OLD.field_code;", "NULL;")),
    ("FIELD", "recording later needs only the view code",
     patch_fn(RRV, "PERFORM require_permission('action.processing_aftercare');", "PERFORM require_permission('module.processing.view');")),
    # ── EVENT ──
    ("EVENT", "any event type is taken", patch_fn(REC_CHK, "IF NOT EXISTS (SELECT 1 FROM processing_event_types t WHERE t.code = p_event_type AND t.is_active) THEN", "IF false THEN")),
    ("EVENT", "the dictionary takes an other", "ALTER TABLE public.processing_event_types DROP CONSTRAINT processing_event_types_code_check;"),
    ("EVENT", "events can be deleted", "DROP TRIGGER trg_processing_run_events_append_only ON public.processing_run_events;"),
    ("EVENT", "a withdrawal is not marked", patch_fn(COE, "v_orig.responsible_person, v_orig.notes, true,", "v_orig.responsible_person, v_orig.notes, false,")),
    # ── RECIPE ──
    ("RECIPE", "an indicator is taken as a preset", patch_fn(CRV, "AND f.is_active AND f.kind = 'parameter';", "AND f.is_active;")),
    ("RECIPE", "a version can be edited", "DROP TRIGGER trg_process_recipe_versions_append_only ON public.process_recipe_versions;"),
    ("RECIPE", "the recipe does not pre-fill",
     patch_fn(COMMIT, "PERFORM record_run_value_internal(v_run_id, v_key, v_recipe.param_values -> v_key, 'recipe', NULL, NULL);", "PERFORM 1;")),
    ("RECIPE", "a recipe of another operation is taken", patch_fn(COMMIT, "IF v_recipe.operation_type_code <> v_op THEN", "IF false THEN")),
    ("RECIPE", "a retired recipe is taken", patch_fn(COMMIT, "IF NOT v_recipe.is_active THEN", "IF false THEN")),
    # ── LOSS ──
    ("LOSS", "a supplied loss is believed",
     patch_fn(COMMIT, "IF v_produces AND p_loss_qty IS NOT NULL AND p_loss_qty <> v_total_input - v_total_output THEN", "IF false THEN")),
    ("LOSS", "named losses may exceed the loss", patch_fn(GPL, "IF v_loss IS NOT NULL AND v_sum > v_loss THEN", "IF false THEN")),
    ("LOSS", "a withdrawal (correction to zero) is refused", patch_fn(CRL, "IF p_quantity IS NULL OR p_quantity < 0 THEN", "IF p_quantity IS NULL OR p_quantity <= 0 THEN")),
    ("LOSS", "losses can be overwritten", "DROP TRIGGER trg_processing_run_losses_append_only ON public.processing_run_losses;"),
    ("LOSS", "a direct write path is back",
     "GRANT INSERT ON public.processing_run_losses TO authenticated;\n"
     "CREATE POLICY \"inj loss insert\" ON public.processing_run_losses FOR INSERT TO authenticated WITH CHECK (true);"),
    # ── CLOSE ──
    ("CLOSE", "a missing required value does not block", patch_fn(CRB, "IF cardinality(b.required_missing) > 0 THEN", "IF false THEN")),
    ("CLOSE", "a missing weighing does not block", patch_fn(CRB, "IF b.outputs_unweighed > 0 THEN", "IF false THEN")),
    ("CLOSE", "no explanation is ever asked",
     patch_fn(CRB, "IF b.remainder_qty <> 0 AND b.within_tolerance IS NOT TRUE AND v_expl IS NULL THEN", "IF false THEN")),
    ("CLOSE", "a set tolerance is ignored",
     patch_fn(CRB, "IF b.remainder_qty <> 0 AND b.within_tolerance IS NOT TRUE AND v_expl IS NULL THEN", "IF b.remainder_qty <> 0 AND v_expl IS NULL THEN")),
    ("CLOSE", "a later correction does not reopen",
     patch_fn(CRB, "v_expl, b.max_loss_id, b.max_value_id)", "v_expl, 9223372036854775807, 9223372036854775807)")),
    ("CLOSE", "closing needs only the view code",
     patch_fn(CRB, "PERFORM require_permission('action.processing_aftercare');", "PERFORM require_permission('module.processing.view');")),
    ("CLOSE", "a closed run can be closed again", patch_fn(CRB, "IF b.balance_state = 'closed' THEN", "IF false THEN")),
    # ── WEIGH ──
    # 下面两格:敲重量是整份 fixture 记产出的默认方式,第一张这样提交的单在 HDR(跨午夜那一张)—— 所以它们红在 HDR 或 WEIGH 都算咬对了。
    ("WEIGH|HDR", "a typed weight records no weighing", patch_fn(COMMIT, "v_wid := record_manual_weighing_internal(v_qty, v_dev);", "v_wid := NULL;")),
    ("WEIGH", "a leg without a weighing is accepted",
     patch_fn(COMMIT, "RAISE EXCEPTION 'OUTPUT_WEIGHING_REQUIRED|%', v_n", "RAISE NOTICE 'inj %', v_n")),
    ("WEIGH", "an expired instrument is accepted", patch_fn(COMMIT, "ELSIF v_wcal.status <> 'in_calibration' THEN", "ELSIF false THEN")),
    ("WEIGH", "a superseded weighing is accepted", patch_fn(COMMIT, "RAISE EXCEPTION 'WEIGHING_SUPERSEDED|%', v_w.id;", "NULL;")),
    ("WEIGH", "a used weighing is accepted again",
     patch_fn(COMMIT, "IF EXISTS (SELECT 1 FROM processing_outputs po WHERE po.weighing_id = v_wid) THEN", "IF false THEN")),
    ("WEIGH", "a weighing in use can be corrected",
     patch_fn(CW, "IF EXISTS (SELECT 1 FROM processing_outputs po WHERE po.weighing_id = v_orig.id) THEN", "IF false THEN")),
    ("WEIGH|HDR", "no instrument is refused even with the switch off",
     patch_fn(COMMIT, "IF v_since IS NOT NULL AND v_process_date >= v_since THEN", "IF true THEN")),
    ("WEIGH", "a quantity off the weighing is accepted",
     patch_fn(COMMIT, "RAISE EXCEPTION 'OUTPUT_QTY_NOT_WEIGHING|%|%|%', v_n, v_output->>'quantity', v_qty;", "NULL;")),
    # ── DISCH ──
    ("DISCH", "a discharge run can be closed", patch_fn(CRB, "IF b.balance_state = 'not_applicable' THEN", "IF false THEN")),
    ("DISCH", "a discharge run without outputs is refused",
     patch_fn(COMMIT, "IF v_produces THEN\n        IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN",
              "IF true THEN\n        IF p_outputs IS NULL OR jsonb_array_length(p_outputs) = 0 THEN")),
    # ── NEWOPS ──
    ("NEWOPS", "casing removal takes damaged cells",
     "INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves) VALUES ('casing_removal', 'damaged_deformed', false);"),
    ("NEWOPS", "electrode separation takes charged material",
     "INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves) VALUES ('electrode_separation', 'charged_not_discharged', false);"),
    # ── CORR ──
    ("CORR", "any header field is correctable",
     patch_fn(CRH, "IF p_field IS NULL OR p_field NOT IN ('started_at', 'ended_at', 'shift_code', 'equipment_id', 'recipe_version_id', 'notes') THEN",
              "IF false THEN")),
    ("CORR", "a correction leaves no row",
     patch_fn(CRH, "    INSERT INTO processing_run_corrections (run_id, field, old_value, new_value, reason)\n    VALUES (p_run_id, p_field, v_old, v_val, btrim(p_reason))\n    RETURNING id INTO v_id;",
              "    v_id := 0;")),
    ("CORR", "a replacement may point at a live run", patch_fn(COMMIT, "IF v_corr.status <> 'reversed' THEN", "IF false THEN")),
    ("CORR", "a run can be corrected twice",
     patch_fn(COMMIT, "IF EXISTS (SELECT 1 FROM processing_runs r WHERE r.corrects_run_id = p_corrects_run_id) THEN", "IF false THEN")),
    # ── POL ──
    ("POL", "an UPDATE policy is back",
     "CREATE POLICY \"inj runs update\" ON public.processing_runs FOR UPDATE TO authenticated USING (true) WITH CHECK (true);"),
    ("POL", "the direct-change guard is gone", "DROP TRIGGER trg_processing_runs_direct_change ON public.processing_runs;"),
    # ── MONTH ──
    ("MONTH", "month-end counts closed runs too",
     patch_fn(UNCL, "WHERE b.balance_state = 'open'", "WHERE b.balance_state IN ('open', 'closed')")),
    ("MONTH", "the reminder also lists closed runs",
     patch_view("operations_now", "b.balance_state = 'open'::text", "b.balance_state = ANY (ARRAY['open'::text, 'closed'::text])")),
    # ── COST ──
    ("COST", "allocation waits for the closure",
     patch_fn(ALLOC, "PERFORM require_permission('module.finance.edit');",
              "PERFORM require_permission('module.finance.edit');\n"
              "    IF (SELECT balance_state FROM processing_run_balance_all WHERE run_id = p_run_id) = 'open' THEN RAISE EXCEPTION 'INJ_NOT_CLOSED'; END IF;")),
    ("COST", "closing moves the allocation",
     patch_fn(CRB, "    INSERT INTO processing_run_closures (run_id,",
              "    UPDATE processing_runs SET allocated_at = now() - interval '1 day' WHERE id = p_run_id;\n    INSERT INTO processing_run_closures (run_id,")),
    # ── PV ──
    ("PV", "V1 lists the discharge", patch_view("pending_values", "ot.is_active AND k.produces_outputs AND", "ot.is_active AND")),
    ("PV", "V36 never clears", patch_view("pending_values", "f.has_range AND (f.range_min IS NULL) AND (f.range_max IS NULL)", "f.has_range")),
    ("PV", "V6 still points at the handovers page",
     patch_view("pending_values", "'/settings/dictionaries'::text AS href", "'/operation/handovers'::text AS href")),
    # ── SHIFT ──
    ("SHIFT", "a start without an end is taken", "ALTER TABLE public.shifts DROP CONSTRAINT shifts_hours_paired;"),
    ("SHIFT", "a processing editor cannot write shift times",
     "DROP POLICY \"shifts write by permission\" ON public.shifts;"),
    # ── TRAIL ──
    ("TRAIL", "a run's trail drops its values",
     patch_fn(MEMB, "('processing_run',     9, 'processing_run_values',", "('processing_run_x',   9, 'processing_run_values',")),
    ("TRAIL", "a code-keyed root has no members again",
     patch_fn(TRAIL, "(u.k ? 'id' OR (SELECT count(*) FROM jsonb_object_keys(u.k)) = 1)", "u.k ? 'id'")),
]


def run(injection):
    sql = "BEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def where_red(out):
    """(第一条 ERROR, 它之前最后一次进到的那一臂)。"""
    last_arm, first_err = None, None
    for ln in out.splitlines():
        m = re.search(r"fixture 253 · ([A-Z]+)", ln)
        if m:
            last_arm = m.group(1)
        if "ERROR" in ln:
            first_err = ln
            break
    return first_err or "(no error)", last_arm


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 253 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 253 全部通过")
arms = set()
for arm, name, inj in CASES:
    rc, out = run(inj)
    first, last_arm = where_red(out)
    if rc == 0:
        print(f"✗ {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif any(f"FIXTURE 253 {a}" in first or last_arm == a for a in arm.split("|")):
        arms.add(arm.split("|")[0])
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
missing = {"HDR", "MACH", "FIELD", "EVENT", "RECIPE", "LOSS", "CLOSE", "WEIGH", "DISCH", "NEWOPS", "CORR", "POL", "MONTH",
           "COST", "PV", "SHIFT", "TRAIL"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
