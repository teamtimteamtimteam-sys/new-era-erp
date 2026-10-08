#!/usr/bin/env python3
"""MES-5a-2:fixture 256 的故障注入 —— 每一格注入一处缺陷,fixture 256 必须在【它点名的那一臂】红。
外加 MES-5a-1 close-out 的裁定第 4 条:fixture 255 MC 那一句(进料批的模组数在列级授权【与】遮蔽视图里)的【遮蔽视图那一半】
此前只被断言、没被注入过 —— 这里补一格,并照样要求它红在 MC。

做法照 db/scripts/2026-10-08-mes5a1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 256 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 256 <臂>",
或者它发生时最后打出的那一臂就是 <臂>。一格可以点名两臂(A|B):例如"估计冲多了"在预览(SPLIT)里就先露头。
fixture 256 不断言任何取号序列的值(编号都是读出来再比的),所以这里不必在格与格之间放回序列。
跑法:python3 db/scripts/2026-10-08-mes5a2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
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


def body_of(num):
    src = next(ROOT.glob(f"db/fixtures/{num}-*.sql")).read_text()
    assert src.count("\nBEGIN;\n") == 1 and src.rstrip().endswith("ROLLBACK;"), f"fixture {num} shape changed"
    return src.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]


BODY = body_of("256")

EAC = "public.electricity_allocation_compute(date, date, numeric, numeric, text, text, text)"
PREV = "public.preview_electricity_allocation(date, date, numeric, numeric, text, text, text)"
POST = ("public.post_electricity_allocation(date, date, date, text, numeric, numeric, text, text, text, uuid, text, text)")
MRI = "public.meter_reading_internal(uuid, timestamp with time zone, numeric, boolean, text, text, boolean, bigint, text)"
RMR = "public.record_meter_reading(uuid, timestamp with time zone, numeric, boolean, text, text)"
CMR = "public.correct_meter_reading(bigint, text, timestamp with time zone, numeric, boolean, text, boolean, text)"
SSR = "public.set_electricity_shared_pool_rule(text)"
REVX = "public.reverse_expense(uuid, text)"
SAVE = "public.save_device(jsonb, uuid)"
TSM = "public.trail_subject_members()"


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
    # ── METER ──
    ("METER", "a processing viewer registers a meter",
     patch_fn(SAVE, "require_permission('action.manage_devices')", "require_permission('module.processing.view')")),
    ("METER", "the device page forgets the machine",
     patch_fn(SAVE, "IF p_id IS NULL OR f ? 'equipment_id' THEN v_row.equipment_id := NULLIF(f ->> 'equipment_id', '')::uuid; END IF;",
              "NULL;")),
    # ── READ ──
    ("READ", "a processing viewer records a reading",
     patch_fn(RMR, "require_permission('action.confirm_capture')", "require_permission('module.processing.view')")),
    ("READ", "a lower reading is taken",
     patch_fn(MRI, "IF FOUND AND p_register_kwh < v_prev.register_kwh AND NOT v_reset THEN", "IF false THEN")),
    ("READ", "a register reset needs no reason", patch_fn(MRI, "IF v_reset AND v_reason IS NULL THEN", "IF false THEN")),
    ("READ", "a back-dated reading may exceed the next one",
     patch_fn(MRI, "IF FOUND AND p_register_kwh > v_next.register_kwh AND NOT v_next.is_register_reset THEN", "IF false THEN")),
    ("READ", "two readings at one moment",
     patch_fn(MRI, "RAISE EXCEPTION 'METER_READING_TIME_TAKEN|%|%', v_dev.code, p_read_at;", "NULL;")),
    ("READ", "a reading in the future is taken", patch_fn(MRI, "IF p_read_at > now() THEN", "IF false THEN")),
    ("READ", "a correction needs no reason", patch_fn(CMR, "IF v_reason IS NULL THEN", "IF false THEN")),
    ("READ", "a superseded reading may be corrected again",
     patch_fn(CMR, "IF v_orig.withdrawn OR EXISTS (SELECT 1 FROM meter_readings x WHERE x.corrects_id = v_orig.id) THEN", "IF false THEN")),
    ("READ", "the delta counts across a register reset",
     patch_view("meter_readings_current", "WHEN ((previous_kwh IS NULL) OR is_register_reset) THEN NULL::numeric",
                "WHEN (previous_kwh IS NULL) THEN NULL::numeric")),
    ("READ", "readings can be edited in place", "DROP TRIGGER trg_meter_readings_append_only ON public.meter_readings;"),
    # ── RUNE ──
    ("RUNE", "the allocated share beats the run's own value",
     patch_view("processing_run_energy", "COALESCE(own.value_number, l.kwh)", "COALESCE(l.kwh, own.value_number)")),
    ("RUNE", "energy recovered is not shown",
     patch_view("processing_run_energy", "    rec.recovered_kwh\n", "    NULL::numeric AS recovered_kwh\n")),
    # ── SPLIT ──
    ("SPLIT", "every machine splits by run time", patch_fn(EAC, "IF v_all_own AND v_sum_w > 0 THEN", "IF false THEN")),
    ("SPLIT", "one recorded run is enough for the energy basis (per-run mixing)",
     patch_fn(EAC, "SELECT bool_and(x ->> 'own_kwh' IS NOT NULL)", "SELECT bool_or(x ->> 'own_kwh' IS NOT NULL)")),
    ("SPLIT", "the basis is not printed on the line",
     patch_fn(EAC, "'equipment_code', v_mach.equipment_code, 'basis', v_basis, 'own_kwh'", "'equipment_code', v_mach.equipment_code, 'basis', NULL, 'own_kwh'")),
    ("SPLIT", "an unmeasured machine is treated as measured",
     patch_fn(EAC, "bool_and((e ->> 'measured')::boolean) AS measured", "true AS measured")),
    ("SPLIT", "runs outside the period are split too",
     patch_fn(EAC, "               AND r.process_date BETWEEN p_period_from AND p_period_to;", "               ;")),
    ("SPLIT|ALLOC", "estimates on uncovered runs are relieved too",
     patch_fn(EAC, "WHERE e.run_id IN (SELECT (x ->> 'run_id')::uuid FROM jsonb_array_elements(v_runs) x)", "WHERE true")),
    # ── TONNE ──
    ("TONNE", "per tonne divides by kilograms",
     patch_view("processing_run_energy", "(r.total_input / (1000)::numeric)", "r.total_input")),
    # ── ALLOC ──
    ("ALLOC", "the posting differs from the preview",
     patch_fn(POST, "(v_run ->> 'amount')::numeric, v_entry);", "(v_run ->> 'amount')::numeric + 0.01, v_entry);")),
    ("ALLOC", "the estimate stays on the run", patch_fn(POST, "deleted_at = now(), ", "")),
    ("ALLOC", "the remainder goes to 5110 instead of 6200",
     patch_fn(EAC, "jsonb_build_object('account_code', '6200'", "jsonb_build_object('account_code', '5110'")),
    ("ALLOC", "the share lines are left unsettled",
     patch_fn(POST, "auth.uid(), auth.uid(), p_bill_date, v_je_id)", "auth.uid(), auth.uid(), NULL, NULL)")),
    ("ALLOC", "the expense document disagrees with the bill",
     patch_fn(POST, "p_bill_amount, v_base, 1, p_bill_amount, p_payment_status", "p_bill_amount + 1, v_base, 1, p_bill_amount + 1, p_payment_status")),
    # ── CCY ──
    ("CCY", "a foreign-currency bill is taken", patch_fn(EAC, "IF upper(btrim(p_currency)) <> v_base THEN", "IF false THEN")),
    ("CCY|SPLIT", "the base currency is a literal, not data",
     patch_fn(EAC, "v_base      text := base_currency_code();", "v_base      text := 'XXX';")),
    ("CCY", "more metered than billed is taken", patch_fn(EAC, "IF v_metered > p_bill_kwh THEN", "IF false THEN")),
    ("CCY|REV", "an overlapping period is taken",
     patch_fn(EAC, "WHERE daterange(a.period_from, a.period_to, '[]') && daterange(p_period_from, p_period_to, '[]')", "WHERE false")),
    # ── PERM ──
    ("PERM", "a preview without finance view",
     patch_fn(PREV, "PERFORM require_permission('module.finance.view');", "NULL;")),
    ("PERM", "posting without finance edit",
     patch_fn(POST, "require_permission('module.finance.edit')", "require_permission('module.finance.view')")),
    ("PERM", "V25 set without finance edit",
     patch_fn(SSR, "require_permission('module.finance.edit')", "require_permission('module.finance.view')")),
    # ── MASK ──
    ("MASK", "the bill amount leaks through the masked view",
     patch_view("electricity_allocations_masked", "WHEN has_permission('data.view_prices'::text) THEN bill_amount", "WHEN true THEN bill_amount")),
    ("MASK", "a line amount leaks through the masked view",
     patch_view("electricity_allocation_lines_masked", "WHEN has_permission('data.view_prices'::text) THEN amount", "WHEN true THEN amount")),
    ("MASK", "the bill amount is in the column grant", "GRANT SELECT (bill_amount) ON public.electricity_allocations TO authenticated;"),
    # ── LOG ──
    ("LOG", "a new table is not change-logged", "DROP TRIGGER zzz_change_log ON public.meter_readings;"),
    ("LOG", "the run's trail does not carry its allocation line",
     patch_fn(TSM, "('processing_run',    17, 'electricity_allocation_lines'", "('processing_run_x',  17, 'electricity_allocation_lines'")),
    # ── V25 ──
    ("V25", "the V25 arm is missing",
     patch_view("pending_values", "WHERE (es.id AND (es.shared_pool_rule IS NULL) AND", "WHERE (false AND (es.shared_pool_rule IS NULL) AND")),
    ("V25", "the rule is not saved",
     patch_fn(SSR, "UPDATE electricity_settings SET shared_pool_rule = v_rule", "UPDATE electricity_settings SET shared_pool_rule = NULL")),
    # ── REV ──
    ("REV", "the allocation's expense can be reversed alone",
     patch_fn(REVX, "IF EXISTS (SELECT 1 FROM electricity_allocations ea WHERE ea.expense_id = p_expense_id) THEN", "IF false THEN")),
]


def run(body, injection):
    sql = "BEGIN;\n" + injection + "\n" + body + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def where_red(out, num):
    """(第一条 ERROR, 它之前最后一次进到的那一臂)。"""
    last_arm, first_err = None, None
    for ln in out.splitlines():
        m = re.search(rf"fixture {num} · ([A-Z0-9]+)", ln)
        if m:
            last_arm = m.group(1)
        if "ERROR" in ln:
            first_err = ln
            break
    return first_err or "(no error)", last_arm


bad = 0
rc, out = run(BODY, "")
if rc != 0 or "FIXTURE 256 全部通过" not in out:
    print("✗ the clean fixture is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 256 全部通过")
arms = set()
for arm, name, inj in CASES:
    rc, out = run(BODY, inj)
    first, last_arm = where_red(out, 256)
    named = arm.split("|")
    if rc == 0:
        print(f"✗ {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif any(f"FIXTURE 256 {a}" in first for a in named) or last_arm in named:
        arms.update(named)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1

# ── MES-5a-1 close-out 裁定第 4 条:fixture 255 MC 的【遮蔽视图那一半】——
#    把 module_count 从 inbound_batches_masked 里拿掉(改名,列就不在了),255 必须红在 MC 那一句上
B255 = body_of("255")
inj = "ALTER VIEW public.inbound_batches_masked RENAME COLUMN module_count TO module_count_hidden;"
rc, out = run(B255, inj)
first, last_arm = where_red(out, 255)
if rc != 0 and "FIXTURE 255 MC: inbound_batches.module_count must be in the column grant and in inbound_batches_masked" in first:
    print(f"✓ fixture 255 MC · the column leaves the masked view: [{last_arm}] {first[first.index('ERROR'):][:200]}")
else:
    print(f"✗ fixture 255 MC · the column leaves the masked view: expected the grant/masked-view sentence, got [{last_arm}] {first[:300]}")
    bad += 1

missing = {"METER", "READ", "RUNE", "SPLIT", "TONNE", "ALLOC", "CCY", "PERM", "MASK", "LOG", "V25", "REV"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections on 256 + 1 on 255, {bad} wrong)")
sys.exit(1 if bad else 0)
