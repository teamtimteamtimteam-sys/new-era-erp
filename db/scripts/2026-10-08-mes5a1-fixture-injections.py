#!/usr/bin/env python3
"""MES-5a-1:fixture 255 的故障注入 —— 每一格注入一处缺陷,fixture 255 必须在【它点名的那一臂】红。

做法照 MES-4b 的 db/scripts/2026-10-07-mes4b-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 255 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 255 <臂>",
或者它发生时最后打出的那一臂就是 <臂>。一格可以点名两臂(A|B):模组数的锁与下限写在 VER / P1 那两段里,拒绝的话却以 MC 开头。
【序列】fixture 255 推 inbound / output / processing 的取号序列;一格红了的注入会把它们留在推过之后的值 —— 所以本脚本在每一格开跑之前
把它们放回它自己开跑时读到的值(只在这个一次性的重建库上)。
跑法:python3 db/scripts/2026-10-08-mes5a1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
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
F = next(ROOT.glob("db/fixtures/255-*.sql")).read_text()
assert F.count("\nBEGIN;\n") == 1 and F.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]

COMMIT = ("public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, "
          "timestamp with time zone, text, uuid, jsonb, uuid)")
GBM = "public.guard_batch_module_count()"
SBM = "public.set_batch_module_count(text, uuid, integer)"
CIB = ("public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, "
       "text, text, uuid, numeric, text, text, integer)")
DRI = ("public.discharge_result_internal(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, numeric, "
       "numeric, uuid, text, text, bigint, text)")
DVB = "public.discharge_verify_batch(text, uuid, uuid, text)"
RDR = ("public.record_discharge_module_result(uuid, text, uuid, text, numeric, text, timestamp with time zone, text, integer, numeric, "
       "numeric, numeric, uuid, text, text)")
DCI = "public.discharge_channel_internal(uuid, text, uuid, integer, text, boolean, bigint, text)"
ADC = "public.assign_discharge_channel(uuid, text, uuid, integer, text)"
SPL = ("public.split_failed_modules_to_quarantine(uuid, text, uuid, text[], date, timestamp with time zone, timestamp with time zone, "
       "text, uuid, numeric, uuid, text)")
RB = "public.rollback_processing_run_internal(uuid, text, uuid)"


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
    # ── MC ──
    ("MC", "a non-cell form may carry a module count", patch_fn(GBM, "IF v_form IS NOT NULL AND NOT v_dismantles THEN", "IF false THEN")),
    ("MC", "the receipt drops the module count",
     patch_fn(CIB, "NULLIF(btrim(COALESCE(p_cell_construction, '')), ''), p_module_count)", "NULLIF(btrim(COALESCE(p_cell_construction, '')), ''), NULL)")),
    ("MC", "a processing viewer may set the count",
     patch_fn(SBM, "ARRAY['module.inbound.edit', 'action.processing_commit']", "ARRAY['module.inbound.edit', 'module.processing.view']")),
    ("MC", "a result is taken before the count", patch_fn(DRI, "IF v_count IS NULL THEN", "IF false THEN")),
    ("MC", "the column leaves the column grant", "REVOKE SELECT (module_count) ON public.inbound_batches FROM authenticated;"),
    ("MC|VER", "the count never locks",
     patch_fn(GBM, "IF EXISTS (SELECT 1 FROM discharge_batch_status_all s\n                    WHERE s.batch_id = NEW.id AND s.currently_verified) THEN",
              "IF false THEN")),
    ("MC|P1", "the count may drop below the results",
     patch_fn(GBM, "IF v_n > 0 AND (NEW.module_count IS NULL OR NEW.module_count < v_n) THEN", "IF false THEN")),
    # ── COMMIT ──
    ("COMMIT", "a commit verifies again (the old flip)",
     patch_fn(COMMIT, "AND NOT v_by_unit THEN\n                UPDATE inbound_batch_safety_states", "THEN\n                UPDATE inbound_batch_safety_states")),
    ("COMMIT", "the unverified reminder is gone",
     patch_view("operations_now", "WHERE ((ds.latest_run_id IS NOT NULL) AND (NOT ds.currently_verified))", "WHERE false")),
    # ── VER ──
    ("VER", "one pass verifies the batch", patch_fn(DVB, "IF v_s.rule_verified THEN", "IF v_s.passed > 0 THEN")),
    ("VER", "a fail needs no disposition", patch_fn(DRI, "IF p_verdict = 'fail' AND v_disp IS NULL THEN", "IF false THEN")),
    ("VER", "a module beyond the count is taken", patch_fn(DRI, "IF v_n >= v_count THEN", "IF false THEN")),
    ("VER", "the same module twice on one run",
     patch_fn(DRI, "RAISE EXCEPTION 'DISCHARGE_RESULT_ALREADY_RECORDED|%|%', v_ref, v_run.code\n              USING HINT = ", "RAISE NOTICE '%', ")),
    ("VER", "the earliest result wins",
     patch_view("discharge_module_current_all", "ORDER BY r.verdict_at DESC, r.id DESC", "ORDER BY r.verdict_at, r.id")),
    ("VER", "the verification does not name the run",
     patch_fn(DVB, "INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)\n            VALUES (p_batch_id, v_s.result_state, p_run_id)",
              "INSERT INTO inbound_batch_safety_states (inbound_batch_id, safety_state_code, created_by_run_id)\n            VALUES (p_batch_id, v_s.result_state, NULL)")),
    # ── CORR ──
    ("CORR", "a correction needs no reason",
     patch_fn(DRI, "IF NULLIF(btrim(COALESCE(p_correction_reason, '')), '') IS NULL THEN\n            RAISE EXCEPTION 'DISCHARGE_CORRECTION_REASON_REQUIRED';",
              "IF false THEN\n            RAISE EXCEPTION 'DISCHARGE_CORRECTION_REASON_REQUIRED';")),
    ("CORR", "a superseded row may be corrected again",
     patch_fn(DRI, "IF EXISTS (SELECT 1 FROM discharge_module_results x WHERE x.corrects_id = p_corrects_id) THEN", "IF false THEN")),
    ("CORR", "a failing correction leaves the batch verified",
     patch_fn(DVB, "IF NOT v_s.currently_verified THEN\n        RETURN false;\n    END IF;", "RETURN false;")),
    ("CORR", "a correction that changes nothing is taken", patch_fn(DRI, "RAISE EXCEPTION 'DISCHARGE_CORRECTION_SAME_VALUE';", "NULL;")),
    # ── REV ──
    ("REV", "a reversed run's results still count",
     patch_view("discharge_module_current_all", "WHERE ((pr.status = 'committed'::text) AND (pr.deleted_at IS NULL) AND (NOT", "WHERE ((NOT")),
    # ── P1 ──
    ("P1", "a partial discharge flips the whole batch (the old shape)",
     patch_fn(COMMIT, "AND NOT v_by_unit THEN\n                UPDATE inbound_batch_safety_states",
              "AND (NOT v_by_unit OR (v_consumed < (SELECT b.quantity FROM inbound_batches b WHERE b.id = v_inbound_id)\n"
              "     AND NOT EXISTS (SELECT 1 FROM discharge_module_results x WHERE x.inbound_batch_id = v_inbound_id))) THEN\n                UPDATE inbound_batch_safety_states")),
    # ── P2 ──
    ("P2", "a reversal restores stock a discharge never took (the old shape)",
     patch_fn(RB, "WHERE pi.run_id = p_run_id AND v_consumes", "WHERE pi.run_id = p_run_id")),
    # ── P3 ──
    ("P3", "discharging a self-produced batch drains it again (the old shape)",
     patch_fn(COMMIT, "            IF v_consumes THEN\n                SELECT remaining_qty INTO v_remaining\n                FROM output_batches",
              "            IF true THEN\n                SELECT remaining_qty INTO v_remaining\n                FROM output_batches")),
    # ── RES ──
    ("RES", "a verdict in the future is taken", patch_fn(DRI, "IF p_verdict_at > now() THEN", "IF false THEN")),
    ("RES", "a verdict before the run is taken", patch_fn(DRI, "IF v_run.started_at IS NOT NULL AND p_verdict_at < v_run.started_at THEN", "IF false THEN")),
    ("RES", "any operation takes module results", patch_fn(DRI, "IF v_by_unit IS NOT TRUE THEN", "IF false THEN")),
    ("RES", "a processing viewer may record a result",
     patch_fn(RDR, "require_permission('action.confirm_capture')", "require_permission('module.processing.view')")),
    # ── V9 ──
    ("V9", "the pass voltage is not copied", patch_fn(DRI, "SELECT m.discharge_pass_voltage_v INTO v_pass", "SELECT NULL::numeric INTO v_pass")),
    ("V9", "an empty line reads as no contradiction",
     patch_fn(DRI, "p_duration_min, p_energy_recovered_wh, v_pass,", "p_duration_min, p_energy_recovered_wh, COALESCE(v_pass, 0),")),
    ("V9", "V9 lists every cell material",
     patch_view("pending_values", "(m.discharge_pass_voltage_v IS NULL) AND (EXISTS ( SELECT 1", "(m.discharge_pass_voltage_v IS NULL) AND (true OR EXISTS ( SELECT 1")),
    ("V9", "a flagged pass does not count (the line decides)",
     patch_view("discharge_batch_status_all", "count(*) FILTER (WHERE ((NOT c.split_out) AND (c.verdict = 'pass'::text))) AS passed",
                "count(*) FILTER (WHERE ((NOT c.split_out) AND (c.verdict = 'pass'::text) AND (NOT COALESCE(c.contradicts_pass_voltage, false)))) AS passed")),
    # ── CHAN ──
    ("CHAN", "a channel may hold two modules",
     patch_fn(DCI, "IF v_other IS NOT NULL THEN\n            RAISE EXCEPTION 'DISCHARGE_CHANNEL_TAKEN", "IF false THEN\n            RAISE EXCEPTION 'DISCHARGE_CHANNEL_TAKEN")),
    ("CHAN", "a result may contradict its channel", patch_fn(DRI, "IF v_assigned IS NOT NULL AND v_assigned <> v_ref THEN", "IF false THEN")),
    ("CHAN", "a result recorder may assign channels",
     patch_fn(ADC, "require_permission('action.processing_aftercare')", "require_permission('module.processing.view')")),
    ("CHAN", "a withdrawal is not recorded as withdrawn",
     patch_fn(DCI, "p_channel_no, v_ref, COALESCE(p_withdraw, false), p_corrects_id", "p_channel_no, v_ref, false, p_corrects_id")),
    # ── SPLIT ──
    ("SPLIT", "a split needs no quarantine location",
     patch_fn(SPL, "WHERE l.id = p_location_id AND l.is_active AND l.is_quarantine", "WHERE l.id = p_location_id AND l.is_active")),
    ("SPLIT", "a passed module may be split",
     patch_fn(SPL, "IF NOT FOUND OR v_cur.split_out OR v_cur.verdict <> 'fail' OR v_cur.disposition IS DISTINCT FROM 'quarantine' THEN",
              "IF NOT FOUND OR v_cur.split_out THEN")),
    ("SPLIT", "a split needs no aftercare code",
     patch_fn(SPL, "require_permission('action.processing_aftercare')", "require_permission('module.processing.view')")),
    ("SPLIT", "the new batch is not placed in quarantine",
     patch_fn(SPL, "PERFORM create_stock_transfer_internal(v_qty, v_loc.id, NULL, v_new, NULL, 'available',", "PERFORM create_stock_transfer_internal(0.000001, v_loc.id, NULL, v_new, NULL, 'available',")),
    ("SPLIT", "the new batch carries no state",
     patch_fn(SPL, "WHERE s.inbound_batch_id = p_batch_id AND s.ended_at IS NULL;", "WHERE false;")),
    ("SPLIT", "split modules do not count toward verification",
     patch_view("discharge_batch_status_all", "count(*) FILTER (WHERE c.split_out) AS split_out", "(0)::bigint AS split_out")),
    ("SPLIT", "the pending-split reminder is gone",
     patch_view("operations_now", "WHERE ((ds.failed_quarantine > 0) AND (ds.latest_run_id IS NOT NULL))", "WHERE false")),
    ("SPLIT", "a split-out module may still get a result on the parent", patch_fn(DRI, "IF FOUND AND v_cur.split_out THEN", "IF false THEN")),
    # ── ING ──
    ("ING", "a discharge_module transform is registered",
     "UPDATE public.ingest_data_classes SET transform_function = 'transform_weighing_v1', creates_draft = true WHERE code = 'discharge_module';"),
]


def seq_state():
    q = ("SELECT 'SELECT setval(''' || s || ''', ' || last_value || ', ' || is_called || ');' FROM ("
         " SELECT 'output_code_seq' AS s, last_value, is_called FROM output_code_seq"
         " UNION ALL SELECT 'inbound_code_seq', last_value, is_called FROM inbound_code_seq"
         " UNION ALL SELECT 'processing_code_seq', last_value, is_called FROM processing_code_seq"
         " UNION ALL SELECT 'material_code_seq', last_value, is_called FROM material_code_seq) x")
    p = subprocess.run(["psql", DSN, "-X", "-A", "-t", "-c", q], capture_output=True, text=True, check=True)
    return p.stdout.replace("\n", " ")


RESET = seq_state()


def run(injection):
    sql = RESET + "\nBEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def where_red(out):
    """(第一条 ERROR, 它之前最后一次进到的那一臂)。"""
    last_arm, first_err = None, None
    for ln in out.splitlines():
        m = re.search(r"fixture 255 · ([A-Z0-9]+)", ln)
        if m:
            last_arm = m.group(1)
        if "ERROR" in ln:
            first_err = ln
            break
    return first_err or "(no error)", last_arm


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 255 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 255 全部通过")
arms = set()
for arm, name, inj in CASES:
    rc, out = run(inj)
    first, last_arm = where_red(out)
    named = arm.split("|")
    if rc == 0:
        print(f"✗ {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif any(f"FIXTURE 255 {a}" in first for a in named) or last_arm in named:
        arms.update(named)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
# ── 四支既有 fixture 新加的断言(MES-5a Step 0 Q34:状态断言挪到结果之后,并加上"提交本身不核实"那一条)——
#    把旧的毛病装回去,每一支必须红在它新加的那一句上(不是别的地方)
EXISTING = [
    ("158", patch_fn(COMMIT, "AND NOT v_by_unit THEN\n                UPDATE inbound_batch_safety_states", "THEN\n                UPDATE inbound_batch_safety_states"),
     "FIXTURE 158D4 失败(MES-5a-1)"),
    ("251", patch_fn(COMMIT, "AND NOT v_by_unit THEN\n                UPDATE inbound_batch_safety_states", "THEN\n                UPDATE inbound_batch_safety_states"),
     "FIXTURE 251 RUN: a discharge commit alone"),
    ("253", patch_fn(COMMIT, "AND NOT v_by_unit THEN\n                UPDATE inbound_batch_safety_states", "THEN\n                UPDATE inbound_batch_safety_states"),
     "FIXTURE 253 DISCH: a discharge commit alone"),
    ("165", patch_fn(COMMIT, "AND NOT v_by_unit THEN\n                UPDATE output_batch_safety_states", "THEN\n                UPDATE output_batch_safety_states"),
     "FIXTURE 165K7 失败(MES-5a-1)"),
    ("165", patch_fn(COMMIT, "            IF v_consumes THEN\n                SELECT remaining_qty INTO v_remaining\n                FROM output_batches",
                     "            IF true THEN\n                SELECT remaining_qty INTO v_remaining\n                FROM output_batches"),
     "FIXTURE 165K7 失败(P3)"),
]
for fx, inj, expect in EXISTING:
    src = next(ROOT.glob(f"db/fixtures/{fx}-*.sql")).read_text()
    body = src.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=RESET + "\nBEGIN;\n" + inj + body + "\nROLLBACK;\n",
                       capture_output=True, text=True)
    first = next((ln for ln in (p.stdout + p.stderr).splitlines() if "ERROR" in ln), "(no error)")
    if p.returncode != 0 and expect in first:
        print(f"✓ fixture {fx}: {first[first.index('ERROR'):][:180]}")
    else:
        print(f"✗ fixture {fx}: expected «{expect}», got {first[:240]}")
        bad += 1

missing = {"MC", "COMMIT", "VER", "CORR", "REV", "P1", "P2", "P3", "RES", "V9", "CHAN", "SPLIT", "ING"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections on 255 + {len(EXISTING)} on 158/165/251/253, {bad} wrong)")
sys.exit(1 if bad else 0)
