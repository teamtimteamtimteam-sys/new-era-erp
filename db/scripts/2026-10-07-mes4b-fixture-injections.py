#!/usr/bin/env python3
"""MES-4b:fixture 254 的故障注入 —— 每一格注入一处缺陷,fixture 254 必须在【它点名的那一臂】红。

做法照 MES-4a 的 db/scripts/2026-10-07-mes4a-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 254 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 254 <臂>",
或者它发生时最后打出的那一臂就是 <臂>(注入让一句直接调用的函数当场抛出 —— 那一句就住在这一臂里)。
【序列】fixture 254 推 output_code_seq / inbound_code_seq 并在【跑绿时】放回原值;一格红了的注入会把它们留在推过之后的值 ——
所以本脚本在每一格开跑之前把两条序列放回它自己开跑时读到的值(只在这个一次性的重建库上)。
跑法:python3 db/scripts/2026-10-07-mes4b-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
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
F = next(ROOT.glob("db/fixtures/254-*.sql")).read_text()
assert F.count("\nBEGIN;\n") == 1 and F.rstrip().endswith("ROLLBACK;"), "fixture shape changed"
BODY = F.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]

COMMIT = ("public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, "
          "timestamp with time zone, text, uuid, jsonb, uuid)")
GUARD = "public.guard_batch_cell_construction()"
SETCC = "public.set_batch_cell_construction(text, uuid, text)"
CIB = ("public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, "
       "text, text, uuid, numeric, text, text)")
GOC = "public.generate_output_code()"
GIC = "public.generate_inbound_code()"
SDS = "public.search_documents_sql(text)"
RRL = "public.record_run_loss(uuid, text, numeric, text)"
CRL = "public.correct_run_loss(bigint, numeric, text)"
RDE = "public.record_derived_electrolyte_loss(uuid, text)"
RED = "public.rederive_electrolyte_loss(bigint, text)"
CCI = ("public.contamination_check_internal(uuid, text, text, uuid, numeric, numeric, timestamp with time zone, text, text, bigint, text)")
CCC = "public.correct_contamination_check(bigint, text, uuid, numeric, numeric, timestamp with time zone, text, text, text)"


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
    # ── CC ──
    ("CC", "a non-cell form may carry a construction", patch_fn(GUARD, "IF v_form IS NOT NULL AND NOT v_dismantles THEN", "IF false THEN")),
    ("CC", "the lock after a committed run is gone", patch_fn(GUARD, "IF v_run IS NOT NULL THEN", "IF false THEN")),
    ("CC", "separation takes inputs with no construction",
     patch_fn(COMMIT, "IF v_req_cc AND (v_cc IS NULL OR", "IF false AND (v_cc IS NULL OR")),
    ("CC", "unknown counts as determined", "UPDATE public.cell_constructions SET is_determined = true WHERE code = 'unknown';"),
    ("CC", "outputs never inherit", patch_fn(COMMIT, "CASE WHEN v_dismantles IS TRUE THEN v_cc_inherit END", "NULL")),
    ("CC", "outputs inherit even when inputs disagree",
     patch_fn(COMMIT, "IF NOT v_cc_any_null AND (SELECT count(DISTINCT x) FROM unnest(v_cc_vals) x) = 1 THEN",
              "IF cardinality(v_cc_vals) > 0 THEN")),
    ("CC", "the receipt drops the construction", patch_fn(CIB, "v_user, v_user, NULLIF(btrim(COALESCE(p_cell_construction, '')), ''))", "v_user, v_user, NULL)")),
    ("CC", "a processing viewer may set it",
     patch_fn(SETCC, "ARRAY['module.inbound.edit', 'action.processing_commit']", "ARRAY['module.inbound.edit', 'module.processing.view']")),
    # ── FORM ──
    ("FORM", "collected dust becomes saleable", "UPDATE public.material_forms SET may_be_sold = true WHERE code = 'collected_dust';"),
    ("FORM", "anode powder stays unsaleable (the Step 0 recommendation, not Tim's answer)",
     "UPDATE public.material_forms SET may_be_sold = false WHERE code = 'anode_powder';"),
    # ── NUM ──
    ("NUM", "the prefix ignores the material form", patch_fn(GOC, "v_key := COALESCE(v_key, 'output_batch');", "v_key := 'output_batch';")),
    ("NUM", "new prefixes pad to four digits", patch_fn(GOC, "CASE WHEN v_key = 'output_batch' THEN 4 ELSE 5 END", "4")),
    ("NUM", "the output number truncates again", patch_fn(GOC, "LPAD(v_n, GREATEST(v_width, length(v_n)), '0')", "LPAD(v_n, v_width, '0')")),
    ("NUM", "the inbound number truncates again",
     patch_fn(GIC, "(SELECT LPAD(n, GREATEST(4, length(n)), '0') FROM (SELECT nextval('inbound_code_seq')::TEXT AS n) s)",
              "LPAD(nextval('inbound_code_seq')::TEXT, 4, '0')")),
    ("NUM", "search stops separating the 13 output types", patch_fn(SDS, "IF v_shared THEN", "IF false THEN")),
    ("NUM|DUST", "collected dust loses its DST mapping", "UPDATE public.material_forms SET output_document_key = NULL WHERE code = 'collected_dust';"),
    # ── LOSS ──
    ("LOSS", "record_run_loss stops stating its basis", patch_fn(RRL, "NULLIF(btrim(COALESCE(p_notes, '')), ''), 'measured')", "NULLIF(btrim(COALESCE(p_notes, '')), ''), NULL)")),
    ("LOSS", "an operation without the flag may derive", patch_fn(RDE, "IF NOT v_ot.electrolyte_loss_applies THEN", "IF false THEN")),
    ("LOSS", "no share is not refused by name", patch_fn(RDE, "IF v_ot.electrolyte_share_pct IS NULL THEN", "IF false THEN")),
    ("LOSS", "a state-changing run may derive", patch_fn(RDE, "IF v_produce IS NOT TRUE THEN", "IF false THEN")),
    ("LOSS", "the derived loss is the remainder",
     patch_fn(RDE, "v_qty := round(v_ot.electrolyte_share_pct * v_run.total_input / 100, 3);",
              "v_qty := v_run.loss_qty - COALESCE((SELECT sum(quantity) FROM processing_run_losses WHERE run_id = p_run_id), 0);")),
    ("LOSS", "a processing viewer may derive", patch_fn(RDE, "require_permission('action.processing_aftercare')", "require_permission('module.processing.view')")),
    ("LOSS", "re-deriving ignores the share change",
     patch_fn(RED, "IF v_orig.basis = 'derived' AND v_qty = v_orig.quantity AND v_ot.electrolyte_share_pct = v_orig.derived_share_pct THEN",
              "IF v_orig.basis = 'derived' THEN")),
    ("LOSS", "switching to measured with the same number is refused",
     patch_fn(CRL, "IF p_quantity = v_orig.quantity AND v_orig.basis = 'measured' THEN", "IF p_quantity = v_orig.quantity THEN")),
    ("LOSS", "the balance hides the derived part",
     patch_view("processing_run_balance_all", "sum(l.quantity) FILTER (WHERE (l.basis = 'derived'::text)) AS derived_loss_qty",
                "(0)::numeric AS derived_loss_qty")),
    # ── CONT ──
    ("CONT", "a check clears every stream of the shift", patch_view("contamination_shift_status_all", "(c.stream_code = cl.stream_code)", "true")),
    ("CONT", "not sampled does not close the reminder",
     patch_view("contamination_shift_status_all", "WHEN (COALESCE(ck.not_sampled_count, (0)::bigint) > 0) THEN 'not_sampled'::text", "")),
    ("CONT", "the reminder points at the latest run",
     patch_view("contamination_shift_status_all", "(array_agg(sr.run_id ORDER BY sr.started_at, sr.run_code))[1] AS first_run_id",
                "(array_agg(sr.run_id ORDER BY sr.started_at DESC, sr.run_code DESC))[1] AS first_run_id")),
    ("CONT", "not sampled needs no reason",
     patch_fn(CCI, "IF NULLIF(btrim(COALESCE(p_not_sampled_reason, '')), '') IS NULL THEN\n            RAISE EXCEPTION 'CONTAMINATION_REASON_REQUIRED';",
              "IF false THEN\n            RAISE EXCEPTION 'CONTAMINATION_REASON_REQUIRED';")),
    ("CONT", "the warning level is not copied (nothing is ever flagged)", patch_fn(CCI, "            v_stream.warning_pct,\n", "            NULL,\n")),
    ("CONT", "any batch may be the sample",
     patch_fn(CCI, "WHERE po.run_id = p_run_id AND po.output_batch_id = p_output_batch_id AND m.form_code = v_stream.sheet_form_code;",
              "WHERE po.output_batch_id = p_output_batch_id;")),
    ("CONT", "a superseded check may be corrected again",
     patch_fn(CCC, "IF EXISTS (SELECT 1 FROM contamination_checks x WHERE x.corrects_id = v_orig.id) THEN", "IF false THEN")),
    ("CONT", "a pre-MES-4a run takes a check", patch_fn(CCI, "IF v_run.started_at IS NULL OR v_run.shift_code IS NULL THEN", "IF false THEN")),
    ("CONT", "an output reader sees no checks",
     patch_view("contamination_check_rows", "ARRAY['module.processing.view'::text, 'module.output.view'::text]", "ARRAY['module.processing.view'::text]")),
    # ── DUST ──
    ("DUST", "collected dust is born with a safety state",
     "CREATE FUNCTION pg_temp.inj_dust() RETURNS trigger LANGUAGE plpgsql AS $t$ BEGIN "
     "IF (SELECT m.form_code FROM materials m WHERE m.id = NEW.material_id) = 'collected_dust' THEN "
     "INSERT INTO output_batch_safety_states (output_batch_id, safety_state_code) VALUES (NEW.id, 'discharged_verified'); END IF; RETURN NULL; END $t$;\n"
     "CREATE TRIGGER inj_dust AFTER INSERT ON public.output_batches FOR EACH ROW EXECUTE FUNCTION pg_temp.inj_dust();"),
    # ── PV ──
    ("PV", "V10 lists unticked operations",
     patch_view("pending_values", "(ot.is_active AND ot.electrolyte_loss_applies AND (ot.electrolyte_share_pct IS NULL))",
                "(ot.is_active AND (ot.electrolyte_share_pct IS NULL))")),
    ("PV", "V11 never clears", patch_view("pending_values", "(cs.is_active AND (cs.warning_pct IS NULL))", "cs.is_active")),
]


def seq_state():
    q = ("SELECT 'SELECT setval(''output_code_seq'', ' || last_value || ', ' || is_called || '); ' FROM output_code_seq "
         "UNION ALL SELECT 'SELECT setval(''inbound_code_seq'', ' || last_value || ', ' || is_called || ');' FROM inbound_code_seq")
    p = subprocess.run(["psql", DSN, "-X", "-A", "-t", "-c", q], capture_output=True, text=True, check=True)
    return p.stdout.replace("\n", " ")


# 每一格开跑之前把两条序列放回本脚本开跑时的值 —— 一格红了的注入不会替 fixture 放回去,而下一格不该继承它推过的号
RESET = seq_state()


def run(injection):
    sql = RESET + "\nBEGIN;\n" + injection + "\n" + BODY + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def where_red(out):
    """(第一条 ERROR, 它之前最后一次进到的那一臂)。"""
    last_arm, first_err = None, None
    for ln in out.splitlines():
        m = re.search(r"fixture 254 · ([A-Z]+)", ln)
        if m:
            last_arm = m.group(1)
        if "ERROR" in ln:
            first_err = ln
            break
    return first_err or "(no error)", last_arm


bad = 0
rc, out = run("")
if rc != 0 or "FIXTURE 254 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 254 全部通过")
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
    elif any(f"FIXTURE 254 {a}" in first or last_arm == a for a in arm.split("|")):
        arms.add(arm.split("|")[0] if last_arm not in arm.split("|") else last_arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
missing = {"CC", "FORM", "NUM", "LOSS", "CONT", "DUST", "PV"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections, {bad} wrong)")
sys.exit(1 if bad else 0)
