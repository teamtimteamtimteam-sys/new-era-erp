#!/usr/bin/env python3
"""MES-7b-2:fixture 268(与 fixture 263 新的两臂)的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。

做法照 db/scripts/2026-10-16-mes7b1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
视图重建时带回它自己的 reloptions(不假设 security_invoker = off)。
【红在哪一臂】fixture 268 每进一臂先打一行 NOTICE "fixture 268 · <臂>"("NUM · RUN" 与 "V18 · V20 (empty)" 两行,正则取到的是前一个);
一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 268 <臂>",或者它发生时最后打出的那一臂就是 <臂>。
措辞臂 ㉝ 的两格(TRAIL_WORDING_FAULT wording-drift-mes7b2 / wording-part-mes7b2)是 scripts/check-trail-wording.mjs 的,不碰库,不在这里;
gate 的 viewwrite 一行的那一格是 GATE_VIEWWRITE_FAULT=grant(db/gate.py),也不在这里 —— 这里的 F16 两格打的是 fixture 268 的 F16 臂。
【"不跟着清单改" 与 "不跟着字典改" 怎么注入】那两条断言说的是一件【不发生】的事(结果抄走了字 / 限值),所以那两格是往库里【加】一支
  会让它发生的触发器(并摘掉挡着它的那一支只追加守卫)。
跑法:python3 db/scripts/2026-10-16-mes7b2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
退出码:0 = 两支 fixture 干净跑绿、每一格都红在它的那一臂、268 的每一臂都至少红过一次;1 = 否则。
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


SIT = "public.save_inspection_template(uuid, text, text, text, jsonb, integer, boolean, text)"
RIR = "public.record_inspection_run(uuid, timestamp with time zone, uuid, jsonb, uuid, uuid, text, jsonb, uuid, text)"
RIF = "public.record_inspection_finding(uuid, integer, text, uuid, date)"
CIF = "public.close_inspection_finding(uuid, text)"
RFT = "public.raise_inspection_finding_task(uuid)"
RER = "public.record_environmental_result(text, text, date, text, text, numeric, boolean, text, uuid, text)"
NIS = "public.next_inspection_code(date)"
GTW = "public.guard_inspection_template_write()"
GRW = "public.guard_inspection_record_write()"
GEP = "public.guard_environmental_parameter_code()"
GER = "public.guard_environmental_result_write()"
NCR = "public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint, uuid, uuid)"
TSM = "public.trail_subject_members()"
TSU = "public.trail_subjects()"


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
    return f"""DO $inj$ DECLARE d text; d2 text; opts text; BEGIN
    d := pg_get_viewdef('public.{name}'::regclass);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{name}'; END IF;
    SELECT array_to_string(reloptions, ', ') INTO opts FROM pg_class WHERE oid = 'public.{name}'::regclass;
    EXECUTE format('CREATE OR REPLACE VIEW public.%I %s AS %s', '{name}',
                   CASE WHEN opts IS NULL THEN '' ELSE 'WITH (' || opts || ')' END, d2);
END $inj$;
"""


FOLLOW_TEMPLATE = """ALTER TABLE public.inspection_results DISABLE TRIGGER trg_inspection_results_immutable;
ALTER TABLE public.inspection_runs DISABLE TRIGGER trg_inspection_runs_immutable;
CREATE FUNCTION public.f268_inj_follow() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
    UPDATE public.inspection_results r SET item_text = NEW.item_text FROM public.inspection_runs x
     WHERE x.id = r.run_id AND x.template_id = NEW.template_id AND r.position = NEW.position;
    RETURN NEW;
END $f$;
CREATE TRIGGER f268_inj_follow AFTER UPDATE ON public.inspection_template_items FOR EACH ROW EXECUTE FUNCTION public.f268_inj_follow();
"""
FOLLOW_LIMIT = """ALTER TABLE public.environmental_results DISABLE TRIGGER trg_environmental_results_immutable;
CREATE FUNCTION public.f268_inj_limit() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
    UPDATE public.environmental_results r SET limit_value = NEW.limit_value, unit = NEW.unit,
           exceeds = CASE WHEN NEW.limit_basis = 'max' THEN r.value > NEW.limit_value ELSE r.value < NEW.limit_value END
     WHERE r.parameter_code = NEW.code;
    RETURN NEW;
END $f$;
CREATE TRIGGER f268_inj_limit AFTER UPDATE ON public.environmental_parameters FOR EACH ROW EXECUTE FUNCTION public.f268_inj_limit();
"""
TASK_CLOSES_FINDING = """CREATE FUNCTION public.f268_inj_task() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
    IF NEW.status = 'done' THEN
        INSERT INTO public.inspection_finding_closures (finding_id, what_was_done)
        SELECT f.id, 'closed with its task' FROM public.inspection_findings f
         WHERE f.task_id = NEW.id AND NOT EXISTS (SELECT 1 FROM public.inspection_finding_closures c WHERE c.finding_id = f.id);
    END IF;
    RETURN NEW;
END $f$;
CREATE TRIGGER f268_inj_task AFTER UPDATE ON public.tasks FOR EACH ROW EXECUTE FUNCTION public.f268_inj_task();
"""

CASES = [
    # ── REG ──
    ("REG", "a checklist is seeded",
     "INSERT INTO public.inspection_templates (code, name, area) VALUES ('SEEDED', 'seeded', 'x');\n"),
    ("REG", "a new table is not change-logged", "DROP TRIGGER zzz_change_log ON public.inspection_results;\n"),
    ("REG", "the inspection-source CHECK is gone",
     "ALTER TABLE public.nonconformance_reports DROP CONSTRAINT nonconformance_reports_inspection_source;\n"),
    ("REG", "the due base view is readable by staff", "GRANT SELECT ON public.inspection_template_due_all TO authenticated;\n"),
    # ── F16 ──
    ("F16", "a view is writable by staff again", "GRANT INSERT ON public.pending_values TO authenticated;\n"),
    ("F16", "anon may delete through a view", "GRANT DELETE ON public.inspection_run_rows TO anon;\n"),
    # ── TPL ──
    ("TPL", "anyone may save a checklist", patch_fn(SIT, "    PERFORM require_permission('module.safety.edit');\n", "")),
    ("TPL", "a blank item is not refused by name", patch_fn(SIT, "        IF v_text = '' THEN", "        IF false THEN")),
    ("TPL", "a direct checklist write is not refused by name", patch_fn(GTW, "    IF row_security_active(TG_RELID) THEN", "    IF false THEN")),
    ("TPL", "a checklist may be deleted",
     patch_fn(GTW, "IF TG_OP = 'DELETE' AND TG_TABLE_NAME = 'inspection_templates' THEN", "IF false THEN")),
    ("TPL", "every save rewrites every item row",
     patch_fn(SIT, "        UPDATE inspection_template_items SET item_text = v_text\n         WHERE template_id = v_id AND position = v_i AND item_text IS DISTINCT FROM v_text;",
                   "        DELETE FROM inspection_template_items WHERE template_id = v_id AND position = v_i;")),
    # ── NUM ──
    ("NUM", "the number is three digits wide", patch_fn(NIS, "GREATEST(4, length(v_seq::text))", "3")),
    ("NUM", "the numbering skips one", patch_fn(NIS, "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1",
                                              "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 2")),
    # ── RUN ──
    ("RUN", "a fail needs no note (by name)", patch_fn(RIR, "        IF v_res = 'fail' AND v_note IS NULL THEN", "        IF false THEN")),
    ("RUN", "a missing item is accepted", patch_fn(RIR, "    IF v_missing IS NOT NULL THEN", "    IF false THEN")),
    ("RUN", "a switched-off checklist can be inspected", patch_fn(RIR, "    IF NOT v_tpl.is_active THEN", "    IF false THEN")),
    ("RUN", "an inspection follows later edits of its checklist", FOLLOW_TEMPLATE),
    ("RUN", "the run row miscounts its fails",
     patch_view("inspection_run_rows", "WHERE ((s.run_id = r.id) AND (s.result = 'fail'::text))) AS fail_count",
                "WHERE (s.run_id = r.id)) AS fail_count")),
    # ── IMMUT ──
    ("IMMUT", "the owner may rewrite a result", "DROP TRIGGER trg_inspection_results_immutable ON public.inspection_results;\n"),
    ("IMMUT", "a direct run insert is not refused by name",
     patch_fn(GRW, "    IF row_security_active(TG_RELID) THEN\n        RAISE EXCEPTION 'INSPECTION_THROUGH_FUNCTION_ONLY';\n    END IF;\n    IF TG_TABLE_NAME = 'inspection_runs' THEN",
                   "    IF TG_TABLE_NAME = 'inspection_runs' THEN")),
    # ── FIND ──
    ("FIND", "a finding on a passed item is accepted", patch_fn(GRW, "        IF v_res.result <> 'fail' THEN", "        IF false THEN")),
    ("FIND", "a finding needs no owner (by name)",
     patch_fn(RIF, "    IF p_owner_employee_id IS NULL THEN\n        RAISE EXCEPTION 'INSPECTION_FINDING_OWNER_REQUIRED';\n    END IF;\n", "")),
    ("FIND", "a closed finding stays on the reminder",
     patch_view("operations_now", "WHERE (NOT (EXISTS ( SELECT 1\n                   FROM inspection_finding_closures c\n                  WHERE (c.finding_id = f.id))))) a",
                "WHERE true) a")),
    ("FIND", "the finding reminder is open to everyone",
     patch_view("operations_now", "'inspection_finding_open'::text AS item_type,\n            'module.safety.view'::text AS permission",
                "'inspection_finding_open'::text AS item_type,\n            'module.processing.view'::text AS permission")),
    ("FIND", "the owner may rewrite a finding",
     patch_fn(GRW, "        RAISE EXCEPTION 'INSPECTION_FINDING_IMMUTABLE'", "        RETURN NEW;\n        RAISE EXCEPTION 'INSPECTION_FINDING_IMMUTABLE'")),
    # ── TASK ──
    ("TASK", "the task goes to the finding's owner, not the presser",
     patch_fn(RFT, "'personal', v_emp)", "'personal', (SELECT owner_employee_id FROM inspection_findings WHERE id = p_finding_id))")),
    ("TASK", "closing the task closes the finding", TASK_CLOSES_FINDING),
    ("TASK", "a second task may be raised", patch_fn(RFT, "    IF v_f.task_id IS NOT NULL THEN", "    IF false THEN")),
    ("TASK", "a presser with no employee record is not refused by name", patch_fn(RFT, "    IF v_emp IS NULL THEN", "    IF false THEN")),
    ("TASK", "a presser with no task code may raise one",
     patch_fn(RFT, "    IF NOT (has_permission('module.tasks.edit') OR has_permission('module.tasks.view')) THEN", "    IF false THEN")),
    # ── CORR ──
    ("CORR", "a correction needs no reason (by name)",
     patch_fn(RIR, "        IF v_reason IS NULL THEN\n            RAISE EXCEPTION 'INSPECTION_CORRECTION_REASON_REQUIRED';\n        END IF;\n", "")),
    ("CORR", "a run may be corrected twice (by name)",
     patch_fn(RIR, "        IF v_by IS NOT NULL THEN\n            RAISE EXCEPTION 'INSPECTION_RUN_ALREADY_CORRECTED", "        IF false THEN\n            RAISE EXCEPTION 'INSPECTION_RUN_ALREADY_CORRECTED")),
    ("CORR", "a superseded run takes new findings",
     patch_fn(GRW, "        IF v_by IS NOT NULL THEN\n            RAISE EXCEPTION 'INSPECTION_RUN_SUPERSEDED", "        IF false THEN\n            RAISE EXCEPTION 'INSPECTION_RUN_SUPERSEDED")),
    ("CORR", "the run row does not name its correction",
     patch_view("inspection_run_rows", "sup.code AS corrected_by_run_code", "NULL::text AS corrected_by_run_code")),
    # ── DUE ──
    ("DUE", "the frequency is ignored (never due)",
     patch_view("inspection_template_due_all", "+ t.frequency_days) <= ((now() AT TIME ZONE", "+ t.frequency_days + 1000) <= ((now() AT TIME ZONE")),
    ("DUE", "a checklist without a frequency is due",
     patch_view("operations_now", "(d.due_state = ANY (ARRAY['due'::text, 'never_run'::text]))", "(d.due_state = ANY (ARRAY['due'::text, 'never_run'::text, 'not_set'::text]))")),
    ("DUE", "a switched-off checklist is due",
     patch_view("operations_now", "WHERE (t.is_active AND (d.due_state = ANY", "WHERE (true AND (d.due_state = ANY")),
    ("DUE", "a never-inspected checklist is not due",
     patch_view("operations_now", "ARRAY['due'::text, 'never_run'::text]", "ARRAY['due'::text]")),
    # ── V18 ──
    ("V18", "the empty-dictionary V18 row is missing",
     patch_view("pending_values", "WHERE (NOT (EXISTS ( SELECT 1\n                   FROM inspection_templates t\n                  WHERE t.is_active)))", "WHERE false")),
    ("V18", "a checklist with a frequency is still listed",
     patch_view("pending_values", "WHERE (t.is_active AND (t.frequency_days IS NULL))", "WHERE t.is_active")),
    ("V18", "V18 is open to everyone",
     patch_view("pending_values", "'V18'::text AS value_code,\n            'module.safety.view'::text AS permission,\n            NULL::uuid",
                "'V18'::text AS value_code,\n            'module.processing.view'::text AS permission,\n            NULL::uuid")),
    # ── ENV ──
    ("ENV", "an exceedance opens no incident", patch_fn(RER, "            v_incident := (v_j ->> 'incident_id')::uuid;", "            v_incident := NULL;")),
    ("ENV", "a result follows later limit changes", FOLLOW_LIMIT),
    ("ENV", "a result with no limit is judged within", patch_fn(RER, "CASE WHEN v_par.limit_value IS NULL THEN NULL", "CASE WHEN v_par.limit_value IS NULL THEN false")),
    ("ENV", "a minimum limit is never exceeded", patch_fn(RER, "ELSE p_value < v_par.limit_value END", "ELSE false END")),
    ("ENV", "an exceedance needs no NEA answer (by name)", patch_fn(RER, "            IF p_nea_reportable IS NULL THEN", "            IF false THEN")),
    ("ENV", "a still-exceeding correction opens a second incident",
     patch_fn(RER, "        IF p_corrects_result_id IS NOT NULL THEN\n            SELECT r.incident_id INTO v_incident", "        IF false THEN\n            SELECT r.incident_id INTO v_incident")),
    ("ENV", "results may be updated", "DROP TRIGGER trg_environmental_results_immutable ON public.environmental_results;\n"),
    ("ENV", "a used parameter code may change", patch_fn(GEP, "    IF v_n > 0 THEN", "    IF v_n > 999 THEN")),
    ("ENV", "a limit without its basis is not refused by name",
     patch_fn(GEP, "IF TG_OP IN ('INSERT', 'UPDATE') AND ((NEW.limit_value IS NULL) <> (NEW.limit_basis IS NULL)) THEN", "IF false THEN")),
    ("ENV", "a direct result insert is not refused by name", patch_fn(GER, "    IF row_security_active(TG_RELID) THEN", "    IF false THEN")),
    # ── V20 ──
    ("V20", "the empty-dictionary V20 row is missing",
     patch_view("pending_values", "WHERE (NOT (EXISTS ( SELECT 1\n                   FROM environmental_parameters ep)))", "WHERE false")),
    ("V20", "a parameter with a limit is still listed",
     patch_view("pending_values", "WHERE (ep.is_active AND (ep.limit_value IS NULL))", "WHERE ep.is_active")),
    # ── NCR ──
    ("NCR", "the finding does not count the NCRs citing it",
     patch_view("inspection_finding_rows", "WHERE (n.inspection_finding_id = f.id)) AS ncr_count", "WHERE false) AS ncr_count")),
    # ── TRAIL ──
    ("TRAIL", "the run trail joins the closures on the wrong column",
     patch_fn(TSM, "('inspection_run',      3, 'inspection_finding_closures',      'inspection_findings',          'finding_id'",
                   "('inspection_run',      3, 'inspection_finding_closures',      'inspection_findings',          'id'")),
    ("TRAIL", "the checklist trail joins its items on the wrong column",
     patch_fn(TSM, "('inspection_template', 1, 'inspection_template_items',        'inspection_templates',         'template_id'",
                   "('inspection_template', 1, 'inspection_template_items',        'inspection_templates',         'id'")),
    ("TRAIL", "the environment trail is open to everyone",
     patch_fn(TSU, "('safety_environment',     ARRAY['module.safety.view'],", "('safety_environment',     ARRAY['module.processing.view'],")),
]

ALL_ARMS = {"REG", "F16", "TPL", "NUM", "RUN", "IMMUT", "FIND", "TASK", "CORR", "DUE", "V18", "ENV", "V20", "NCR", "TRAIL"}

CASES_263 = [
    ("NCR", "an inspection-source NCR needs no finding (by name)",
     patch_fn(NCR, "IF p_source = 'inspection' AND p_inspection_finding_id IS NULL THEN", "IF false THEN")),
    ("NCR", "ncr_rows does not name the inspection run",
     patch_view("ncr_rows", "isr.code AS inspection_run_code", "NULL::text AS inspection_run_code")),
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


def sweep(num, stem, cases, all_arms):
    bad = 0
    B = body_of(num, stem)
    rc, out = run(B, "")
    if rc != 0 or f"FIXTURE {num} 全部通过" not in out:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        return 1
    print(f"✓ clean: FIXTURE {num} 全部通过")
    arms = set()
    for arm, name, inj in cases:
        rc, out = run(B, inj)
        first, last_arm = where_red(out, num)
        if rc == 0:
            print(f"✗ {num} {arm} · {name}: did NOT go red")
            bad += 1
        elif "INJECTION_DID_NOT_APPLY" in out:
            print(f"✗ {num} {arm} · {name}: the injection did not apply — {first}")
            bad += 1
        elif f"FIXTURE {num} {arm}" in first or last_arm == arm:
            arms.add(arm)
            shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
            print(f"✓ {num} {arm} · {name}: [{last_arm}] {shown}")
        else:
            print(f"✗ {num} {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
            bad += 1
    missing = all_arms - arms
    if missing:
        print(f"✗ fixture {num}: arms never made red: {sorted(missing)}")
        bad += 1
    return bad


bad = sweep("268", None, CASES, ALL_ARMS)
bad += sweep("263", None, CASES_263, {"NCR"})
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES)} injections on 268 + {len(CASES_263)} on 263, {bad} wrong)")
sys.exit(1 if bad else 0)
