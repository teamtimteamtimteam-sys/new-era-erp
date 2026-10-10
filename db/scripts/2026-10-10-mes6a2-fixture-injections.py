#!/usr/bin/env python3
"""MES-6a-2:fixture 262 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。
外加本刀改过的 fixture 各自的那一臂:119 F2P(一个惩罚元素在定价的每一条路上按名拒)· 149(惩罚元素换成 f、化验带 f)·
230 E4(不持码的人加惩罚元素被拒 —— 换成 cl 之后拒的仍然是【码】)。

做法照 db/scripts/2026-10-09-mes6a1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 262 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 262 <臂>",
或者它发生时最后打出的那一臂就是 <臂>。别的 fixture 以它们自己的那一句(needle)认。
跑法:python3 db/scripts/2026-10-10-mes6a2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一支 fixture 干净跑绿、每一格都红在它的那一臂、262 的每一臂都至少红过一次;1 = 否则。

【刻意写成"两层一起拿掉"的格(层数),照直记下,不假装单层被证过】
  · 行情:upsert_metal_prices 自己判一次,metal_prices 上的守卫再判一次,说同一句话(SUBSTANCE_NOT_PAYABLE|<码>)。
    所以写成两格:只拿掉守卫(直插 / 别的写入路那一句仍由函数先拒 —— 本 fixture 只走函数,于是这一格【预期不红】,单独列在 LAYERED 里核对它确实不红),
    以及函数与守卫一起拿掉(PAY 红)。
  · 计价器:calculate_metal_price 把公式的条款与含量交给引擎;引擎对条款里的码与含量里的码各判一次。
    fixture 走的是"含量里有 f",所以拿掉【含量那一判】就红;条款那一判由 119 F2P 的公式路去咬。
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


UPSERT = "public.upsert_metal_prices(date, jsonb, text, text, text, boolean)"
ENGINE = "public.calculate_metal_price_from_terms(jsonb, jsonb, numeric, date)"
APPLY = "public.apply_assay_result(uuid, uuid, date)"
PREVIEW = "public.preview_assay_price(uuid, jsonb, date)"
COMMITTED = "public.committed_terms_price(uuid, date)"
QUOTE = "public.price_output_sale(uuid, uuid, text, numeric, date)"
SETTLE = "public.sale_settlement_compute(uuid, uuid, uuid)"
COST = "public.allocate_processing_costs(uuid, text)"
ONLY = "public.payable_metals_only(jsonb)"
GUARD = "public.guard_substance_role()"
REC = "public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb)"
TSM = "public.trail_subject_members()"
TS = "public.trail_subjects()"

ROLE_JOIN = "JOIN substances s ON s.code = m.metal AND s.role = 'payable_metal'"
COST_JOIN = "JOIN substances sx ON sx.code = obm.metal AND sx.role = 'payable_metal'"
ENGINE_METAL_CHECK = "        IF (SELECT role FROM substances WHERE code = v_metal) <> 'payable_metal' THEN\n            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_metal;"
UPSERT_CHECK = "        IF (SELECT role FROM substances WHERE code = v_metal) <> 'payable_metal' THEN\n            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_metal;"


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


def retarget(table, trig, role, col):
    return (f"DROP TRIGGER {trig} ON public.{table};\n"
            f"CREATE TRIGGER {trig} BEFORE INSERT OR UPDATE OF {col} ON public.{table} FOR EACH ROW "
            f"EXECUTE FUNCTION public.guard_substance_role('{role}', '{col}');\n")


def drop_trigger(table, trig):
    return f"DROP TRIGGER {trig} ON public.{table};\n"


CASES_262 = [
    # ── ROLE ──
    ("ROLE", "the role column gets a default (Q26 says none)",
     "ALTER TABLE public.substances ALTER COLUMN role SET DEFAULT 'payable_metal';\n"),
    ("ROLE", "fluorine is seeded as a payable metal",
     "UPDATE public.substances SET role = 'payable_metal' WHERE code = 'f';\n"),
    ("ROLE", "any role text is accepted (the CHECK is gone)",
     "ALTER TABLE public.substances DROP CONSTRAINT substances_role_check;\n"),
    # ── PAY ──
    ("PAY", "a metal price takes a penalty element (function check and table guard both gone)",
     patch_fn(UPSERT, UPSERT_CHECK, "        IF false THEN\n            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_metal;")
     + drop_trigger("metal_prices", "trg_metal_prices_substance_role")),
    ("PAY", "the engine prices a penalty element in the content list",
     patch_fn(ENGINE, ENGINE_METAL_CHECK, "        IF false THEN\n            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_metal;")),
    ("PAY", "a formula takes a penalty element (its guard is gone)",
     drop_trigger("pricing_formula_metals", "trg_pricing_formula_metals_substance_role")),
    ("PAY", "a contract pricing term takes a penalty element",
     drop_trigger("contract_pricing_terms", "trg_contract_pricing_terms_substance_role")),
    ("PAY", "a refining charge takes a penalty element",
     drop_trigger("contract_refining_charges", "trg_contract_refining_charges_substance_role")),
    ("PAY", "the refining-charge guard asks for a penalty element (over-reach: a payable metal is refused there)",
     retarget("contract_refining_charges", "trg_contract_refining_charges_substance_role", "penalty_element", "metal")),
    # ── PEN ──
    ("PEN", "a payable metal is accepted as a penalty element (guard gone)",
     drop_trigger("contract_penalty_elements", "trg_contract_penalty_elements_substance_role")),
    ("PEN", "the penalty-element guard asks for a payable metal (over-reach: F and Cl are refused there)",
     retarget("contract_penalty_elements", "trg_contract_penalty_elements_substance_role", "payable_metal", "substance")),
    # ── SETTLE ──
    ("SETTLE", "settlement prices every content line, F included",
     patch_fn(SETTLE, ROLE_JOIN, "JOIN substances s ON s.code = m.metal")),
    # ── QUOTE ──
    ("QUOTE", "the sale quote prices every content line, F included",
     patch_fn(QUOTE, ROLE_JOIN, "JOIN substances s ON s.code = m.metal")),
    # ── APPLY ──
    ("APPLY", "preview hands F to the engine",
     patch_fn(PREVIEW, "payable_metals_only(p_metals)", "p_metals")),
    ("APPLY", "apply hands F to the engine",
     patch_fn(APPLY, "SELECT payable_metals_only(jsonb_agg(", "SELECT (jsonb_agg(")),
    ("APPLY", "committed-terms pricing hands F to the engine",
     patch_fn(COMMITTED, "SELECT payable_metals_only(jsonb_agg(", "SELECT (jsonb_agg(")),
    ("APPLY", "the filter keeps penalty elements",
     patch_fn(ONLY, "AND s.role <> 'payable_metal'", "AND false")),
    # ── RECOV ──
    ("RECOV", "recovery is computed for every substance",
     patch_view("processing_metal_recovery_all", "(s.role = 'payable_metal'::text)", "true")),
    # ── COST ──
    ("COST", "cost allocation values every output content line, F included",
     patch_fn(COST, COST_JOIN, "JOIN substances sx ON sx.code = obm.metal")),
    # ── PPM ──
    # 两位:0.0123 → 0.01,最先读到它的是结算的惩罚(65.70 → 45.00)—— 红在 SETTLE 是对的;PPM 那一臂由四位那一格去咬
    ("SETTLE", "a content is rounded to two places on the way in (the F penalty is computed from 0.01)",
     patch_fn(REC, "        VALUES (v_id, v_metal, v_pct);", "        VALUES (v_id, v_metal, round(v_pct, 2));")),
    ("PPM", "a content is rounded to four places (1 ppm) on the way in — 0.00005 % (0.5 ppm) is lost",
     patch_fn(REC, "        VALUES (v_id, v_metal, v_pct);", "        VALUES (v_id, v_metal, round(v_pct, 4));")),
    # ── IND ──
    ("IND", "a limit column is added (Q3 says none)",
     "ALTER TABLE public.assay_indicators ADD COLUMN max_value numeric;\n"),
    ("IND", "the indicators are not recorded",
     patch_fn(REC, "        INSERT INTO assay_result_indicators (assay_result_id, indicator, value) VALUES (v_id, v_ind, v_val);\n", "")),
    ("IND", "a negative value is accepted",
     patch_fn(REC, "        IF v_val IS NULL OR v_val < 0 THEN", "        IF v_val IS NULL THEN")),
    ("IND", "a duplicate indicator is not refused by name (the primary key answers in its own words)",
     patch_fn(REC, "        IF v_ind = ANY (v_iseen) THEN", "        IF false THEN")),
    ("IND", "an unknown indicator is not refused by name (the foreign key answers in its own words)",
     patch_fn(REC, "        IF v_ind IS NULL OR NOT EXISTS (SELECT 1 FROM assay_indicators WHERE code = v_ind) THEN", "        IF v_ind IS NULL THEN")),
    ("IND", "a direct write of an indicator value is allowed",
     "CREATE POLICY \"assay_result_indicators insert (injected)\" ON public.assay_result_indicators AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);\n"
     "GRANT INSERT ON public.assay_result_indicators TO authenticated;\n"),
    ("IND", "indicator values are readable by everyone",
     "DROP POLICY \"assay_result_indicators select by permission\" ON public.assay_result_indicators;\n"
     "CREATE POLICY \"assay_result_indicators select by permission\" ON public.assay_result_indicators AS PERMISSIVE FOR SELECT TO authenticated USING (true);\n"),
    ("IND", "the definitions are readable by everyone",
     "DROP POLICY \"assay_indicators select by permission\" ON public.assay_indicators;\n"
     "CREATE POLICY \"assay_indicators select by permission\" ON public.assay_indicators AS PERMISSIVE FOR SELECT TO authenticated USING (true);\n"),
    ("IND", "changing a definition is a silent no-op instead of a named refusal",
     drop_trigger("assay_indicators", "enforce_write_permission")),
    # ── LOG ──
    ("LOG", "indicator values are not change-logged",
     drop_trigger("assay_result_indicators", "zzz_change_log")),
    ("LOG", "the definitions are not change-logged",
     drop_trigger("assay_indicators", "zzz_change_log")),
    ("LOG", "indicators are not on the batch trails",
     patch_fn(TSM, "'assay_result_indicators',          'assay_results',", "'assay_result_indicators_x',        'assay_results',")),
    ("LOG", "the definitions are not a dictionary subject",
     patch_fn(TS, "('dictionary_assay_indicators',", "('dictionary_assay_indicators_x',")),
]

# 一格【预期不红】的注入:证明那一层是第二层(上面 PAY 第一格把两层一起拿掉才红)
LAYERED = [
    ("262", "only the metal_prices guard is gone — upsert_metal_prices still refuses by name first",
     drop_trigger("metal_prices", "trg_metal_prices_substance_role")),
]

OTHER = [
    ("119", None, "FIXTURE 119F2P", "a metal price takes a penalty element (function check and table guard both gone)",
     patch_fn(UPSERT, UPSERT_CHECK, "        IF false THEN\n            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_metal;")
     + drop_trigger("metal_prices", "trg_metal_prices_substance_role")),
    ("119", None, "FIXTURE 119F2P", "a payable metal is accepted as a penalty element",
     drop_trigger("contract_penalty_elements", "trg_contract_penalty_elements_substance_role")),
    ("119", None, "FIXTURE 119F2P", "a formula takes a penalty element",
     drop_trigger("pricing_formula_metals", "trg_pricing_formula_metals_substance_role")),
    ("119", None, "FIXTURE 119F2P", "a committed term takes a penalty element",
     drop_trigger("pricing_term_commitment_metals", "trg_pricing_term_commitment_metals_substance_role")),
    # 149 不接住结算的报错 —— 它红在那一句原样的拒绝上,而那句拒绝点名的正是本刀加进它化验里的 f
    ("149", None, "SETTLEMENT_PAYABLE_NOT_STATED|f", "settlement prices every content line (its assays now carry f)",
     patch_fn(SETTLE, ROLE_JOIN, "JOIN substances s ON s.code = m.metal")),
    ("230", None, "FIXTURE 230E4", "anyone may add a penalty element (the code check is gone) — cl still reaches it",
     drop_trigger("contract_penalty_elements", "enforce_write_permission")
     + "DROP POLICY \"contract penalty elements write by owner permission\" ON public.contract_penalty_elements;\n"
     "CREATE POLICY \"contract penalty elements write (injected)\" ON public.contract_penalty_elements AS PERMISSIVE FOR ALL TO authenticated USING (true) WITH CHECK (true);\n"),
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
rc, out = run(body_of("262"), "")
if rc != 0 or "FIXTURE 262 全部通过" not in out:
    print("✗ the clean fixture 262 is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 262 全部通过")
for num in ("119", "149", "230"):
    rc, out = run(body_of(num), "")
    if rc != 0:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: fixture {num} (exit 0)")

B = body_of("262")
arms = set()
for arm, name, inj in CASES_262:
    rc, out = run(B, inj)
    first, last_arm = where_red(out, "262")
    if rc == 0:
        print(f"✗ 262 {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ 262 {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 262 {arm}" in first or last_arm == arm:
        arms.add(arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ 262 {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ 262 {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
missing = {"ROLE", "PAY", "PEN", "SETTLE", "QUOTE", "APPLY", "RECOV", "COST", "PPM", "IND", "LOG"} - arms
if missing:
    print(f"✗ fixture 262: arms never made red: {sorted(missing)}")
    bad += 1

for num, name, inj in LAYERED:
    rc, out = run(body_of(num), inj)
    if rc == 0 and "INJECTION_DID_NOT_APPLY" not in out:
        print(f"✓ layered (stays green, as stated): {name}")
    else:
        first, _ = where_red(out, num)
        print(f"✗ layered: {name} — expected green, got {first[:300]}")
        bad += 1

for num, stem, needle, name, inj in OTHER:
    rc, out = run(body_of(num, stem), inj)
    first, last_arm = where_red(out, num)
    if rc != 0 and "INJECTION_DID_NOT_APPLY" not in out and needle in first:
        print(f"✓ fixture {num} · {name}: {first[first.index('ERROR'):][:200]}")
    else:
        print(f"✗ fixture {num} · {name}: expected '{needle}', got [{last_arm}] {first[:300]}")
        bad += 1

print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_262)} injections on 262 + {len(LAYERED)} layered + {len(OTHER)} on 119 / 149 / 230, {bad} wrong)")
sys.exit(1 if bad else 0)
