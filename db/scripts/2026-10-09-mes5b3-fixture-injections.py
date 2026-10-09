#!/usr/bin/env python3
"""MES-5b-3:fixture 259 的故障注入 —— 每一格注入一处缺陷,fixture 259 必须在【它点名的那一臂】红。
外加 fixture 100(BLD 那一行没了)与 fixture 257 FCHECK(引导的 admin 少了 module.tasks.view_all)各一格。

做法照 db/scripts/2026-10-09-mes5b2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 259 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 259 <臂>",
或者它发生时最后打出的那一臂就是 <臂>。
跑法:python3 db/scripts/2026-10-09-mes5b3-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 三支 fixture 干净跑绿、每一格都红在它的那一臂、259 的每一臂都至少红过一次;1 = 否则。
【有一格是刻意不写的】"执行不再问 action.processing_commit" —— 引擎自己再问一次同一个码(commit_processing_run 的第一句),
所以那一格注入了也不会红:那不是 fixture 瞎了,是那道闸有两层。照直记在这里,不假装它被证过。
"""
import pathlib
import re
import subprocess
import sys

DSN = sys.argv[1]
if "supabase" in DSN or "pooler" in DSN:
    sys.exit("refusing a live DSN — run against a throwaway rebuild")
ROOT = pathlib.Path(".")


def body_of(num, stem=None):
    src = next(ROOT.glob(f"db/fixtures/{num}-{stem or ''}*.sql")).read_text()
    assert src.count("\nBEGIN;\n") == 1 and src.rstrip().endswith("ROLLBACK;"), f"fixture {num} shape changed"
    return src.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]


CREATE = "public.create_blending_plan(uuid, jsonb, jsonb, uuid, text)"
AMEND = "public.amend_blending_plan(uuid, uuid, jsonb, jsonb, uuid, text)"
RELEASE = "public.release_blending_plan(uuid)"
EXECUTE_ = "public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text)"
CHILDREN = "public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb)"
CODE = "public.next_blending_plan_code(date)"
GRUN = "public.guard_blending_run_from_plan()"
GMET = "public.guard_blended_batch_metals_from_assay()"
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
    EXECUTE format('CREATE OR REPLACE VIEW public.%I WITH (security_invoker = off) AS %s', '{name}', d2);
END $inj$;
"""


CASES_259 = [
    # ── PLAN ──
    ("PLAN", "codes are off by one (numbering no longer MAX+1)",
     patch_fn(CODE, "LPAD(v_seq::text, 4, '0')", "LPAD((v_seq + 1)::text, 4, '0')")),
    ("PLAN", "creating no longer asks action.wo_create",
     patch_fn(CREATE, "PERFORM require_permission('action.wo_create');", "PERFORM require_permission('module.processing.view');")),
    ("PLAN", "a plan is born with nobody else able to release it",
     patch_fn(CREATE, "    IF NOT EXISTS (SELECT 1\n                     FROM role_permissions rp", "    IF false AND NOT EXISTS (SELECT 1\n                     FROM role_permissions rp")),
    ("PLAN", "amending no longer asks action.wo_create",
     patch_fn(AMEND, "PERFORM require_permission('action.wo_create');", "PERFORM require_permission('module.processing.view');")),
    # ── SALE ──
    ("SALE", "a non-saleable output form is let through",
     patch_fn(CHILDREN, "IF v_mat.form_code IS NOT NULL AND v_mat.may_be_sold IS FALSE THEN", "IF false THEN")),
    ("SALE", "a line whose form blending does not take is let through",
     patch_fn(CHILDREN, "IF v_bform IS NULL OR NOT EXISTS (SELECT 1 FROM operation_type_input_forms i", "IF false AND NOT EXISTS (SELECT 1 FROM operation_type_input_forms i")),
    ("SALE", "a non-kg batch is let through",
     patch_fn(CHILDREN, "IF v_bunit IS DISTINCT FROM 'kg' THEN", "IF false THEN")),
    ("SALE", "the same batch can sit on two lines",
     patch_fn(CHILDREN, "IF v_bcode = ANY (v_batches) THEN", "IF false THEN")),
    # ── TGT ──
    ("TGT", "copying a contract also takes specs for other materials",
     patch_fn(CHILDREN, "AND (s.material_id IS NULL OR s.material_id = p_output_material_id)", "AND true")),
    ("TGT", "a spec for another material is accepted",
     patch_fn(CHILDREN, "IF v_spec.material_id IS NOT NULL AND v_spec.material_id <> p_output_material_id THEN", "IF false THEN")),
    ("TGT", "a spec from another contract is accepted",
     patch_fn(CHILDREN, "IF NOT FOUND OR p_source_contract_id IS NULL OR v_spec.contract_id <> p_source_contract_id THEN", "IF NOT FOUND THEN")),
    ("TGT", "a bound-less target is accepted (the refusal is gone; the table CHECK answers in its own words)",
     patch_fn(CHILDREN, "IF v_min IS NULL AND v_max IS NULL THEN", "IF false THEN")),
    # ── PRED ──
    ("PRED", "the prediction is the simple mean, not mass-weighted",
     patch_view("blending_plan_prediction", "sum((a.planned_kg * a.content_pct)) AS weighted_sum", "(avg(a.content_pct) * max(pl.planned_kg)) AS weighted_sum")),
    ("PRED", "a metal measured on only some lines still gets a prediction",
     patch_view("blending_plan_prediction", "(c.lines_measured = c.line_count)", "(c.lines_measured > 0)")),
    ("PRED", "a prediction above the max is not flagged",
     patch_view("blending_plan_prediction", "(p.predicted_pct > p.max_pct)) THEN 'above_max'::text", "(p.predicted_pct > (p.max_pct + 100))) THEN 'above_max'::text")),
    ("PRED", "the source of each line is not counted",
     patch_view("blending_plan_prediction", "(WHERE (a.content_source = 'assay'::text))", "(WHERE (a.content_source = 'unknown'::text))")),
    # ── REL ──
    ("REL", "releasing no longer asks action.wo_release",
     patch_fn(RELEASE, "PERFORM require_permission('action.wo_release');", "PERFORM require_permission('module.processing.view');")),
    ("REL", "the creator can release their own plan",
     patch_fn(RELEASE, "PERFORM forbid_self_approval(v_plan.created_by, NULL::uuid, 'blending_plan');", "")),
    ("REL", "a plan with no target is released",
     patch_fn(RELEASE, "IF NOT EXISTS (SELECT 1 FROM blending_plan_targets t WHERE t.plan_id = p_plan_id) THEN", "IF false THEN")),
    ("REL", "a released plan can still be amended",
     patch_fn(AMEND, "IF v_plan.status <> 'draft' THEN", "IF false THEN")),
    # ── EXEC ──
    ("EXEC", "a blending run can be committed outside a plan",
     patch_fn(GRUN, "IF NEW.operation_type_code = 'blending'", "IF false")),
    ("EXEC", "blending shows on the ordinary new-run form",
     "UPDATE operation_types SET started_from_run_page = false WHERE code = 'blending';\n"),
    ("EXEC", "a plan can be executed with lines left out",
     patch_fn(EXECUTE_, "IF cardinality(v_seen) <> v_n THEN", "IF false THEN")),
    ("EXEC", "the plan is not marked executed",
     patch_fn(EXECUTE_, "SET status = 'executed', executed_at = now(), executed_by = v_user, run_id = v_run,",
              "SET status = 'executed', executed_at = now(), executed_by = v_user, run_id = (SELECT id FROM processing_runs WHERE id <> v_run LIMIT 1),")),
    ("EXEC", "the difference is not shown (actual reads as planned)",
     patch_view("blending_plan_execution", "(COALESCE(fed.qty, (0)::numeric) - l.planned_kg)", "(0)::numeric")),
    ("EXEC", "a draft can be executed",
     patch_fn(EXECUTE_, "IF v_plan.status <> 'released' THEN", "IF v_plan.status = 'cancelled' THEN")),
    # ── ASSAY ──
    ("ASSAY", "content can be typed onto the blended batch",
     patch_fn(GMET, "IF NEW.content_source IS DISTINCT FROM 'assay'", "IF false")),
    ("ASSAY", "the outcome ignores the max bound",
     patch_view("blending_plan_outcome", "(m.content_pct > t.max_pct)) THEN 'above_max'::text", "(m.content_pct > (t.max_pct + 100))) THEN 'above_max'::text")),
    ("ASSAY", "the outcome does not notice a metal missing from the assay",
     patch_view("blending_plan_outcome", "WHEN (m.content_pct IS NULL) THEN 'metal_not_in_assay'::text", "WHEN false THEN 'metal_not_in_assay'::text")),
    # ── READ ──
    ("READ", "an inbound line's content shows without inbound view",
     patch_view("blending_plan_line_metals", "WHEN 'inbound'::text THEN has_permission('module.inbound.view'::text)", "WHEN 'inbound'::text THEN true")),
    ("READ", "the prediction shows when the reader cannot view every batch",
     patch_view("blending_plan_prediction", "OR has_permission('module.inbound.view'::text)", "OR true")),
    ("READ", "the blended batch's assay shows without output view",
     patch_view("blending_plan_outcome", "SELECT has_permission('module.output.view'::text) AS visible", "SELECT true AS visible")),
    ("READ", "the base view is readable",
     "GRANT SELECT ON public.blending_plan_line_metals_all TO authenticated;\n"),
    ("READ", "the plans are readable without processing view",
     "DROP POLICY \"blending_plans select by permission\" ON public.blending_plans;\n"
     "CREATE POLICY \"blending_plans select by permission\" ON public.blending_plans AS PERMISSIVE FOR SELECT TO authenticated USING (true);\n"),
    # ── LOG ──
    ("LOG", "blending_plans is not change-logged",
     "DROP TRIGGER zzz_change_log ON public.blending_plans;\n"),
    ("LOG", "the plan's targets are not on its trail",
     patch_fn(TSM, "('blending_plan',      1, 'blending_plan_targets',", "('blending_plan_x',    1, 'blending_plan_targets',")),
    # ── ADMIN ──
    ("ADMIN", "the bootstrap admin lacks module.tasks.view_all",
     "DELETE FROM role_permissions WHERE permission_code = 'module.tasks.view_all' AND role_id = (SELECT id FROM roles WHERE code = 'admin');\n"),
]

OTHER = [
    ("100", "every-document", "FIXTURE 100/1", "the BLD row is gone from the registry",
     "DELETE FROM document_types WHERE key = 'blending_plan';\n"),
    ("257", None, "FIXTURE 257 FCHECK", "the bootstrap admin lacks module.tasks.view_all",
     "DELETE FROM role_permissions WHERE permission_code = 'module.tasks.view_all' AND role_id = (SELECT id FROM roles WHERE code = 'admin');\n"),
]


def run(body, injection):
    sql = "BEGIN;\n" + injection + "\n" + body + "\nROLLBACK;\n"
    p = subprocess.run(["psql", DSN, "-X", "-v", "ON_ERROR_STOP=1", "-q"], input=sql, capture_output=True, text=True)
    return p.returncode, p.stdout + p.stderr


def where_red(out, num):
    last_arm, first_err = None, None
    for ln in out.splitlines():
        m = re.search(rf"fixture {num} · ([A-Z0-9-]+)", ln)
        if m:
            last_arm = m.group(1)
        if "ERROR" in ln:
            first_err = ln
            break
    return first_err or "(no error)", last_arm


bad = 0
for num, stem in (("259", None), ("100", "every-document"), ("257", None)):
    rc, out = run(body_of(num, stem), "")
    if rc != 0 or f"FIXTURE {num} 全部通过" not in out:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: FIXTURE {num} 全部通过")

B259 = body_of("259")
arms = set()
for arm, name, inj in CASES_259:
    rc, out = run(B259, inj)
    first, last_arm = where_red(out, 259)
    if rc == 0:
        print(f"✗ {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 259 {arm}" in first or last_arm == arm:
        arms.add(arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1

for num, stem, needle, name, inj in OTHER:
    rc, out = run(body_of(num, stem), inj)
    first, last_arm = where_red(out, num)
    if rc != 0 and "INJECTION_DID_NOT_APPLY" not in out and needle in first:
        print(f"✓ fixture {num} · {name}: {first[first.index('ERROR'):][:200]}")
    else:
        print(f"✗ fixture {num} · {name}: expected '{needle}', got [{last_arm}] {first[:300]}")
        bad += 1

missing = {"PLAN", "SALE", "TGT", "PRED", "REL", "EXEC", "ASSAY", "READ", "LOG", "ADMIN"} - arms
if missing:
    print(f"✗ arms never made red: {sorted(missing)}")
    bad += 1
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_259)} injections on 259 + {len(OTHER)} on 100 / 257, {bad} wrong)")
sys.exit(1 if bad else 0)
