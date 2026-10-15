#!/usr/bin/env python3
"""MES-7a-1:fixture 265 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。
外加本刀给既有 fixture 加的两臂:264 的 ISSUER(F9)与 195 的 E2b(F10)。

做法照 db/scripts/2026-10-15-mes6b2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 265 每进一臂先打一行 NOTICE "fixture 265 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着
"FIXTURE 265 <臂>",或者它发生时最后打出的那一臂就是 <臂>。别的 fixture 以它们自己的那一句(needle)认。
措辞臂 ㉚ 的两格(wording-drift-mes7a1 · wording-part-mes7a1)是 scripts/check-trail-wording.mjs 的 TRAIL_WORDING_FAULT;
路由的九格在 scripts/check-pdf-routes.mjs 里每一次都跑 —— 两者都不碰库,不在这里。
跑法:python3 db/scripts/2026-10-15-mes7a1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
退出码:0 = 每一支 fixture 干净跑绿、每一格都红在它的那一臂、265 的每一臂都至少红过一次;1 = 否则。
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


OPEN = "public.open_equipment_downtime(uuid, timestamp with time zone, text, text, text)"
CLOSE = "public.close_equipment_downtime(uuid, timestamp with time zone)"
CORR = "public.correct_equipment_downtime(uuid, timestamp with time zone, timestamp with time zone, text, text)"
MAINT = "public.record_equipment_maintenance(uuid, date, text, text, uuid, uuid, text, uuid, uuid, boolean, text, text)"
SAVE = "public.save_equipment_service_interval(uuid, uuid, text, numeric, numeric, integer, integer, text, text)"
REL = "public.equipment_reliability(uuid, timestamp with time zone, timestamp with time zone)"
TARGET = "public.equipment_record_target(uuid)"
CHECK = "public.downtime_cause_check(text)"
GCAUSE = "public.guard_downtime_cause()"
GCLASS = "public.guard_downtime_cause_class()"
TS = "public.trail_subjects()"
ISSUER = "public.coa_issuer()"
ISSUE = "public.issue_coa(uuid, uuid)"
ICOD = "public.issue_cod(uuid)"


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


CASES_265 = [
    # ── CAUSE ──
    ("CAUSE", "the seeded breakdown cause is not a failure",
     "UPDATE public.downtime_causes SET class = 'planned' WHERE code = 'breakdown';\n"),
    ("CAUSE", "a cause may be called other",
     "ALTER TABLE public.downtime_causes DROP CONSTRAINT downtime_causes_code_check;\n"),
    ("CAUSE", "a cited cause's class can change",
     patch_fn(GCLASS, "IF v_n > 0 THEN", "IF v_n > 999999 THEN")),
    ("CAUSE", "a processing viewer writes the dictionary",
     "ALTER POLICY \"downtime_causes write by permission\" ON public.downtime_causes USING (true) WITH CHECK (true);\n"),
    # ── REQUIRE / SOURCE ──
    ("REQUIRE", "a new downtime needs no cause at insert",
     patch_fn(GCAUSE, "        IF NEW.cause_code IS NULL THEN\n            RAISE EXCEPTION 'DOWNTIME_CAUSE_REQUIRED';\n        END IF;\n        IF NEW.source",
              "        IF NEW.source")),
    ("REQUIRE", "a correction needs no cause",
     patch_fn(CHECK, "        RAISE EXCEPTION 'DOWNTIME_CAUSE_REQUIRED';\n", "        RETURN NULL;\n")),
    ("REQUIRE", "a device-sourced row is accepted",
     patch_fn(GCAUSE, "IF NEW.source IS DISTINCT FROM 'manual' THEN", "IF false THEN")),
    # ── OPEN ──
    ("OPEN", "anyone may open a downtime (the code check is gone)",
     patch_fn(OPEN, "    PERFORM require_permission('module.processing.edit');\n", "")),
    ("OPEN", "a van can take downtime",
     patch_fn(TARGET, "IF v_fa.category IS DISTINCT FROM 'equipment' THEN", "IF false THEN")),
    ("OPEN", "a retired cause is accepted",
     patch_fn(CHECK, "IF NOT v_c.is_active THEN", "IF false THEN") + patch_fn(GCAUSE, "AND NOT EXISTS (SELECT 1 FROM downtime_causes c WHERE c.code = NEW.cause_code AND c.is_active)",
                                                                           "AND NOT EXISTS (SELECT 1 FROM downtime_causes c WHERE c.code = NEW.cause_code)")),
    ("OPEN", "a second open period is not named as such",
     patch_fn(OPEN, "    IF FOUND THEN\n        RAISE EXCEPTION 'DOWNTIME_ALREADY_OPEN|%'", "    IF false THEN\n        RAISE EXCEPTION 'DOWNTIME_ALREADY_OPEN|%'")),
    # ── CLOSE ──
    ("CLOSE", "an end before the start is refused by constraint name only",
     patch_fn(CLOSE, "IF p_ended_at < v_d.started_at THEN", "IF false THEN")),
    ("CLOSE", "a closed period can be closed again",
     patch_fn(CLOSE, "IF v_d.ended_at IS NOT NULL THEN", "IF false THEN")),
    # ── CORRECT ──
    ("CORRECT", "a correction closes an open period",
     patch_fn(CORR, "IF v_d.ended_at IS NULL AND p_ended_at IS NOT NULL THEN", "IF false THEN")),
    ("CORRECT", "a correction that changes nothing is accepted",
     patch_fn(CORR, "        RAISE EXCEPTION 'DOWNTIME_NOTHING_CHANGED|%', v_s;\n", "        NULL;\n")),
    # ── MAINT ──
    ("MAINT", "maintenance may cite another machine's downtime",
     patch_fn(MAINT, "IF v_dt.equipment_id <> p_equipment_id THEN", "IF false THEN")),
    ("MAINT", "maintenance may cite a voided downtime",
     patch_fn(MAINT, "IF v_dt.voided_at IS NOT NULL THEN", "IF false THEN")),
    ("MAINT", "a capitalised record with no reason is refused by constraint name only",
     patch_fn(MAINT, "IF COALESCE(p_capitalised, false) AND (p_capitalisation_reason IS NULL OR btrim(p_capitalisation_reason) = '') THEN", "IF false THEN")),
    # ── INTERVAL ──
    ("INTERVAL", "the early warning is not checked against the interval",
     patch_fn(SAVE, "IF v_ldy IS NOT NULL AND (v_ldy < 0 OR v_ldy >= p_interval_days) THEN", "IF false THEN")),
    ("INTERVAL", "a cleared measure keeps its old early warning",
     patch_fn(SAVE, "v_lkg  numeric := CASE WHEN p_interval_kg IS NULL THEN NULL ELSE p_lead_kg END;", "v_lkg  numeric := p_lead_kg;")),
    ("INTERVAL", "another machine's interval can be edited",
     patch_fn(SAVE, "IF v_cur.equipment_id <> p_equipment_id THEN", "IF false THEN")),
    # ── DIRECT ──
    ("DIRECT", "a direct downtime insert is let through",
     "DROP TRIGGER trg_equipment_downtime_direct ON public.equipment_downtime;\n"
     "CREATE POLICY \"inj insert\" ON public.equipment_downtime FOR INSERT TO authenticated WITH CHECK (true);\n"),
    ("DIRECT", "a direct maintenance update is a silent no-op",
     "DROP TRIGGER trg_equipment_maintenance_direct ON public.equipment_maintenance;\n"),
    ("DIRECT", "the interval delete policy is gone",
     "DROP POLICY \"equipment_service_intervals delete by permission\" ON public.equipment_service_intervals;\n"),
    # ── REL ──
    ("REL", "operating hours are a sum, not a union",
     patch_fn(REL, "FROM unnest((SELECT range_agg(tstzrange(pr.started_at, pr.ended_at, '[)') * w.win)",
              "FROM unnest((SELECT array_agg(tstzrange(pr.started_at, pr.ended_at, '[)') * w.win)")),
    ("REL", "a reversed run counts towards operating hours",
     patch_fn(REL, "WHERE pr.equipment_id = w.id AND pr.status = 'committed' AND pr.deleted_at IS NULL\n                                           AND pr.started_at IS NOT NULL",
              "WHERE pr.equipment_id = w.id\n                                           AND pr.started_at IS NOT NULL")),
    ("REL", "a voided downtime counts as a failure",
     patch_fn(REL, "LEFT JOIN equipment_downtime d ON d.equipment_id = w.id AND d.voided_at IS NULL", "LEFT JOIN equipment_downtime d ON d.equipment_id = w.id")),
    ("REL", "a planned stop counts as a failure",
     patch_fn(REL, "count(*) FILTER (WHERE c.class = 'failure')::int AS n_fail,", "count(*) FILTER (WHERE c.class IN ('failure', 'planned'))::int AS n_fail,")),
    ("REL", "an open failure enters MTTR",
     patch_fn(REL, "avg(EXTRACT(EPOCH FROM (d.ended_at - d.started_at))) FILTER (WHERE c.class = 'failure' AND d.ended_at IS NOT NULL)",
              "avg(EXTRACT(EPOCH FROM (COALESCE(d.ended_at, now()) - d.started_at))) FILTER (WHERE c.class = 'failure')")),
    ("REL", "zero failures gives a number",
     patch_fn(REL, "CASE WHEN h.op_h > 0 AND dt.n_fail > 0 THEN round(h.op_h / dt.n_fail, 2) END", "CASE WHEN h.op_h > 0 THEN round(h.op_h / GREATEST(dt.n_fail, 1), 2) END")),
    ("REL", "zero hours is not said",
     patch_fn(REL, "CASE WHEN h.op_h = 0 THEN 'no_hours' WHEN", "CASE WHEN false THEN 'no_hours' WHEN")),
    ("REL", "runs with no machine are not counted",
     patch_fn(REL, "WHERE pr.equipment_id IS NULL AND pr.status = 'committed'", "WHERE false AND pr.equipment_id IS NULL AND pr.status = 'committed'")),
    ("REL", "a van is listed",
     patch_fn(REL, "WHERE fa.category = 'equipment' AND", "WHERE true AND")),
    ("REL", "anyone may read reliability",
     patch_fn(REL, "    PERFORM require_permission('module.processing.view');\n", "")),
    # ── LIST ──
    ("LIST", "equipment_usage hides the category",
     patch_view("equipment_usage", "fa.category AS equipment_category", "'equipment'::text AS equipment_category")),
    # ── TRAIL ──
    ("TRAIL", "the dictionary has no trail block",
     patch_fn(TS, "('dictionary_downtime_causes',", "('dictionary_downtime_causesx',")),
    ("TRAIL", "downtime causes are not change-logged",
     "DROP TRIGGER zzz_change_log ON public.downtime_causes;\n"),
]

# 本刀给既有 fixture 加的臂:(号, 文件名前缀, 该红的那一句, 名字, 注入)
OTHER = [
    ("264", "a-certificate-of-analysis", "FIXTURE 264 ISSUER", "issue_coa resolves the issuer on its own, and the shared lookup drifts",
     patch_fn(ISSUE, "    v_issuer := coa_issuer();\n",
              "    IF current_user_employee() IS NULL THEN RAISE EXCEPTION 'COA_ISSUER_NOT_AN_EMPLOYEE'; END IF;\n"
              "    v_issuer := (SELECT jsonb_build_object('name', COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name), 'position', NULLIF(btrim(p.title), ''))"
              " FROM employees e LEFT JOIN positions p ON p.id = e.position_id WHERE e.id = current_user_employee());\n"
              "    IF v_issuer ->> 'position' IS NULL THEN RAISE EXCEPTION 'COA_ISSUER_POSITION_MISSING|%', v_issuer ->> 'name'; END IF;\n")
     + patch_fn(ISSUER, "SELECT COALESCE(NULLIF(btrim(e.preferred_name), ''), e.legal_name), NULLIF(btrim(p.title), '')",
                "SELECT e.legal_name, NULLIF(btrim(p.title), '')")),
    ("264", "a-certificate-of-analysis", "FIXTURE 264 ISSUER", "the issuer lookup has no code check",
     patch_fn(ISSUER, "    PERFORM require_permission('action.issue_coa');\n", "")),
    ("195", "a-certificate-that-cannot-lie", "E2b", "issue_cod returns a fresh assembly instead of the stored snapshot",
     patch_fn(ICOD, "'snapshot', v_data);", "'snapshot', cod_certificate_data(v_cod.inbound_batch_id));")),
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
rc, out = run(body_of("265"), "")
if rc != 0 or "FIXTURE 265 全部通过" not in out:
    print("✗ the clean fixture 265 is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 265 全部通过")
for num, stem in sorted({(o[0], o[1]) for o in OTHER}, key=lambda x: (int(x[0]), x[1] or '')):
    rc, out = run(body_of(num, stem), "")
    if rc != 0:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: fixture {num} (exit 0)")

B = body_of("265")
arms = set()
for arm, name, inj in CASES_265:
    rc, out = run(B, inj)
    first, last_arm = where_red(out, "265")
    if rc == 0:
        print(f"✗ 265 {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ 265 {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 265 {arm}" in first or last_arm == arm:
        arms.add(arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ 265 {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ 265 {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
missing = {"CAUSE", "REQUIRE", "OPEN", "CLOSE", "CORRECT", "MAINT", "INTERVAL", "DIRECT", "REL", "LIST", "TRAIL"} - arms
if missing:
    print(f"✗ fixture 265: arms never made red: {sorted(missing)}")
    bad += 1

for num, stem, needle, name, inj in OTHER:
    rc, out = run(body_of(num, stem), inj)
    first, last_arm = where_red(out, num)
    if rc != 0 and "INJECTION_DID_NOT_APPLY" not in out and needle in first:
        print(f"✓ fixture {num} · {name}: {first[first.index('ERROR'):][:200]}")
    else:
        print(f"✗ fixture {num} · {name}: expected '{needle}', got [{last_arm}] {first[:300]}")
        bad += 1

print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_265)} injections on 265 + {len(OTHER)} on 264 / 195, {bad} wrong)")
sys.exit(1 if bad else 0)
