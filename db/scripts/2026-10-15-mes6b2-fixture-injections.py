#!/usr/bin/env python3
"""MES-6b-2:fixture 264 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。
外加本刀改过的 fixture 各自的那一处(100 · 101 · 111 · 254)。

做法照 db/scripts/2026-10-15-mes6b1-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 264 · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 264 <臂>",
或者它发生时最后打出的那一臂就是 <臂>。别的 fixture 以它们自己的那一句(needle)认。
F6 的四格与 ㉙ 的两格是 scripts/check-trail-wording.mjs 的 TRAIL_WORDING_FAULT,不在这里(那支检查不碰库)。
跑法:python3 db/scripts/2026-10-15-mes6b2-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
退出码:0 = 每一支 fixture 干净跑绿、每一格都红在它的那一臂、264 的每一臂都至少红过一次;1 = 否则。
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


ISSUE = "public.issue_coa(uuid, uuid)"
DATA = "public.coa_certificate_data(uuid, uuid)"
BLOCK = "public.coa_issue_blockers(uuid, uuid)"
GOV = "public.coa_governing_assay(uuid, uuid)"
ASM = "public.coa_assemble(uuid, uuid)"
CAL = "public.coa_output_calibration_problem(uuid)"
NEXT = "public.next_coa_code(date)"
GUARD = "public.guard_coa_mutation()"
REC = "public.record_coa_issue(uuid, text, text)"
SUBV = "public.submit_coa_void_request(uuid, text)"
WSUB = "public.warehouse_request_submit_internal(text, uuid, text)"
WEX = "public.warehouse_request_execute_internal(uuid)"
WDR = "public.withdraw_warehouse_request(uuid, text)"
TS = "public.trail_subjects()"
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


PERM_ISSUE = "    PERFORM require_permission('action.issue_coa');\n"

CASES_264 = [
    # ── REG ──
    ("REG", "action.issue_coa declares only one view code",
     "UPDATE public.permissions SET requires_view_any = ARRAY['module.output.view'] WHERE code = 'action.issue_coa';\n"),
    ("REG", "the COA document type routes elsewhere",
     "UPDATE public.document_types SET route = '/output' WHERE key = 'coa';\n"),
    ("REG", "certificates are not change-logged",
     "DROP TRIGGER zzz_change_log ON public.certificates_of_analysis;\n"),
    ("REG", "the trail has no coa subject",
     patch_fn(TS, "('coa',                    ARRAY['module.output.view'],", "('coa_x',                  ARRAY['module.output.view'],")),
    ("REG", "the inbound batch trail does not show certificates",
     patch_fn(TSM, "('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false)",
              "('inbound_batch',     51, 'certificates_of_analysis',         'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', false, false)")),
    ("REG", "one-subject no longer counts coa_id",
     "ALTER TABLE public.warehouse_requests DROP CONSTRAINT warehouse_requests_one_subject;\n"
     "ALTER TABLE public.warehouse_requests ADD CONSTRAINT warehouse_requests_one_subject CHECK (num_nonnulls(inbound_batch_id, output_batch_id, run_id, cod_id) <= 1);\n"),
    # ── N38 ──
    ("N38", "unknown_pending ranks strongest",
     patch_view("output_batch_chemistry_certainty_all", "WHEN (ib.chemistry_certainty_code = 'unknown_pending'::text) THEN 1", "WHEN (ib.chemistry_certainty_code = 'unknown_pending'::text) THEN 5")),
    ("N38", "only direct parents are leaves (depth 1)",
     patch_view("output_batch_chemistry_certainty_all", "WHERE (l.parent_kind = 'inbound'::text)", "WHERE ((l.parent_kind = 'inbound'::text) AND (l.depth = 1))")),
    ("N38", "an unrecognised code ranks strongest",
     patch_view("output_batch_chemistry_certainty_all", "ELSE 0\n", "ELSE 9\n")),
    ("N38", "no leaves reads as single_known",
     patch_view("output_batch_chemistry_certainty_all", "WHEN (a.output_batch_id IS NULL) THEN 'not_recorded'::text", "WHEN (a.output_batch_id IS NULL) THEN 'single_known'::text")),
    ("N38", "the gated view drops its predicate",
     patch_view("output_batch_chemistry_certainty", "has_permission('module.output.view'::text)", "true")),
    ("N38", "staff read the ungated base view",
     "GRANT SELECT ON public.output_batch_chemistry_certainty_all TO authenticated;\n"),
    # ── GOV ──
    ("GOV", "a resolved dispute is ignored",
     patch_fn(GOV, "WHERE d.output_batch_id = p_output_batch_id AND d.status = 'resolved'", "WHERE d.output_batch_id = p_output_batch_id AND d.status = 'zz'")),
    ("GOV", "the contract's settling party is ignored",
     patch_fn(GOV, "SELECT NULLIF(t.settlement_terms ->> 'settling_party', '') INTO v_party", "SELECT NULL INTO v_party")),
    ("GOV", "a deleted result can govern",
     patch_fn(GOV, "AND a.deleted_at IS NULL AND a.result_party = v_party", "AND a.result_party = v_party")),
    ("GOV", "falls back past a newer preliminary result to an older final one",
     patch_fn(GOV, "     ORDER BY a.assay_date DESC, a.code DESC", "     ORDER BY a.is_final DESC, a.assay_date DESC, a.code DESC")),
    ("GOV", "is_final is not required",
     patch_fn(BLOCK, "IF v_acode IS NULL OR NOT v_final THEN", "IF v_acode IS NULL THEN")),
    # ── NEVER ──
    ("NEVER", "the composition reads output_batch_metals",
     patch_fn(ASM, "FROM assay_result_metals m LEFT JOIN substances s ON s.code = m.metal\n             WHERE m.assay_result_id = v_aid",
              "FROM output_batch_metals m LEFT JOIN substances s ON s.code = m.metal\n             WHERE m.output_batch_id = p_output_batch_id")),
    # ── REFUSE ──
    ("REFUSE", "anyone may issue (the code check is gone)",
     patch_fn(ISSUE, PERM_ISSUE, "")),
    ("REFUSE", "anyone may preview",
     patch_fn(DATA, "    PERFORM require_permission('module.output.view');\n", "")),
    ("REFUSE", "a quality hold does not refuse",
     patch_fn(BLOCK, "    IF FOUND THEN\n        v_out := v_out || format('QUALITY_HOLD_OPEN", "    IF false THEN\n        v_out := v_out || format('QUALITY_HOLD_OPEN")),
    ("REFUSE", "an open dispute does not refuse",
     patch_fn(BLOCK, "d.status = 'open' LIMIT 1", "d.status = 'zz' LIMIT 1")),
    ("REFUSE", "an out-of-calibration output weighing does not refuse",
     patch_fn(CAL, "        ELSIF r.status <> 'in_calibration' THEN", "        ELSIF false THEN")),
    ("REFUSE", "an unweighed output leg passes the calibration rule",
     patch_fn(CAL, "    IF v_n = 0 AND v_since IS NOT NULL", "    IF false AND v_since IS NOT NULL")),
    ("REFUSE", "a rework decision clears a breach",
     patch_fn(BLOCK, "n.disposition IN ('accept', 'accept_with_penalty')", "n.disposition IN ('accept', 'accept_with_penalty', 'rework')")),
    ("REFUSE", "an order that never touched the batch is accepted",
     patch_fn(BLOCK, "IF NOT EXISTS (SELECT 1 FROM sales_order_reservations r JOIN", "IF false AND NOT EXISTS (SELECT 1 FROM sales_order_reservations r JOIN")),
    ("REFUSE", "a non-employee is not refused by name",
     patch_fn(ISSUE, "    IF v_emp IS NULL THEN\n        RAISE EXCEPTION 'COA_ISSUER_NOT_AN_EMPLOYEE';", "    IF false THEN\n        RAISE EXCEPTION 'COA_ISSUER_NOT_AN_EMPLOYEE';")),
    ("REFUSE", "an issuer without a position may issue",
     patch_fn(ISSUE, "    IF v_position IS NULL THEN", "    IF false THEN")),
    ("REFUSE", "a missing company name does not refuse",
     patch_fn(BLOCK, "    IF NOT EXISTS (SELECT 1 FROM company_profile cp", "    IF false AND NOT EXISTS (SELECT 1 FROM company_profile cp")),
    # ── ISSUE ──
    ("ISSUE", "numbering leaves a gap",
     patch_fn(NEXT, "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1", "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 2")),
    ("ISSUE", "the issuer's position is not printed",
     patch_fn(ISSUE, "'issuer', jsonb_build_object('name', v_name, 'position', v_position)", "'issuer', jsonb_build_object('name', v_name)")),
    ("ISSUE", "N38 is not frozen into the certificate",
     patch_fn(ASM, "        'chemistry', (SELECT", "        'chemistry', NULL::jsonb, 'zz_chemistry', (SELECT")),
    ("ISSUE", "the order's limits are dropped",
     patch_fn(ASM, "WHERE (e ->> 'material_id') IS NULL OR (e ->> 'material_id')::uuid = v_batch.material_id", "WHERE false")),
    ("ISSUE", "the customer name is dropped",
     patch_fn(ASM, "'customer_name', v_t.customer_name,", "'customer_name', NULL::text,")),
    ("ISSUE", "a second live certificate is not refused by name",
     patch_fn(BLOCK, "    IF v_live IS NOT NULL THEN", "    IF false THEN")),
    # ── FROZEN ──
    ("FROZEN", "the mutation guard is gone",
     "DROP TRIGGER trg_certificates_of_analysis_mutation ON public.certificates_of_analysis;\n"),
    ("FROZEN", "the snapshot may be rewritten",
     patch_fn(GUARD, "       OR NEW.snapshot IS DISTINCT FROM OLD.snapshot\n", "")),
    ("FROZEN", "a certificate is not refused deletion by name",
     patch_fn(GUARD, "    IF TG_OP = 'DELETE' THEN", "    IF false THEN")),
    ("FROZEN", "staff may write the table",
     "CREATE POLICY \"coa update (injected)\" ON public.certificates_of_analysis AS PERMISSIVE FOR UPDATE TO authenticated USING (true) WITH CHECK (true);\n"),
    ("FROZEN", "staff may insert a certificate directly",
     "CREATE POLICY \"coa insert (injected)\" ON public.certificates_of_analysis AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);\n"),
    # ── BYTES ──
    ("BYTES", "the path need not sit under the certificate",
     patch_fn(REC, "    IF p_file_path IS NULL OR p_file_path NOT LIKE v_c.id::text || '/%' THEN", "    IF p_file_path IS NULL THEN")),
    ("BYTES", "recording bytes needs no code",
     patch_fn(REC, PERM_ISSUE, "")),
    ("BYTES", "the digest is stored as given",
     patch_fn(REC, "VALUES (p_coa_id, p_file_path, lower(p_sha256), auth.uid())", "VALUES (p_coa_id, p_file_path, p_sha256, auth.uid())")),
    ("BYTES", "a second set of bytes is not refused by name",
     patch_fn(REC, "    IF EXISTS (SELECT 1 FROM coa_issues i WHERE i.coa_id = p_coa_id) THEN", "    IF false THEN")),
    ("BYTES", "the byte record is not append-only",
     "DROP TRIGGER trg_coa_issues_append_only ON public.coa_issues;\n"),
    # ── VOID ──
    ("VOID", "staff can void in one step",
     "GRANT EXECUTE ON FUNCTION public.void_coa_internal(uuid, text, uuid) TO authenticated;\n"),
    ("VOID", "anyone may raise a void request",
     patch_fn(SUBV, PERM_ISSUE, "")),
    ("VOID", "approval does not void",
     patch_fn(WEX, "PERFORM void_coa_internal(v_coa.id, v_r.reason, v_r.created_by);", "NULL;")),
    ("VOID", "voided_by is the approver, not the raiser",
     patch_fn(WEX, "PERFORM void_coa_internal(v_coa.id, v_r.reason, v_r.created_by);", "PERFORM void_coa_internal(v_coa.id, v_r.reason, NULL);")),
    # submit 先查一次、再整笔干跑执行(执行那一侧再查一次)—— 两道都拿掉,申请才会被收下
    ("VOID", "a void certificate may be raised again",
     patch_fn(WSUB, "            RAISE EXCEPTION 'COA_NOT_ISSUED|%|%', v_code, v_stat;", "            NULL;")
     + patch_fn(WEX, "            RAISE EXCEPTION 'COA_NOT_ISSUED|%|%', v_coa.code, v_coa.status;", "            NULL;")),
    ("VOID", "the replacement is not linked",
     patch_fn(ISSUE, "UPDATE certificates_of_analysis c SET replaced_by_coa_id = v_id", "UPDATE certificates_of_analysis c SET replaced_by_coa_id = NULL")),
    ("VOID", "withdrawing a coa_void needs some other code",
     patch_fn(WDR, "WHEN 'coa_void' THEN 'action.issue_coa'", "WHEN 'coa_void' THEN 'action.zz_nobody'")),
    # ── ARM ──
    ("ARM", "a newer assay does not show",
     patch_view("operations_now", "(a_1.created_at > c.issued_at)", "(a_1.created_at > (c.issued_at + '100 years'::interval))")),
    ("ARM", "the arm is gated by the view code",
     patch_view("operations_now", "'coa_facts_changed'::text AS item_type,\n            'action.issue_coa'::text AS permission",
                "'coa_facts_changed'::text AS item_type,\n            'module.output.view'::text AS permission")),
    ("ARM", "a newer NCR does not show",
     patch_view("operations_now", "(n.opened_at > c.issued_at)", "(n.opened_at > (c.issued_at + '100 years'::interval))")),
    # ── TRAIL ──
    ("TRAIL", "anyone reads certificates",
     "ALTER POLICY \"certificates_of_analysis select by permission\" ON public.certificates_of_analysis USING (true);\n"),
    ("TRAIL", "coa_rows drops the customer label",
     patch_view("coa_rows", "COALESCE(cu.short_name, cu.legal_name) AS customer_name", "NULL::text AS customer_name")),
    ("TRAIL", "anon reads coa_rows",
     "GRANT SELECT ON public.coa_rows TO anon;\n"),
]

# 改过的既有 fixture:(号, 文件名前缀, 该红的那一句, 名字, 注入)
OTHER = [
    ("100", "every-document", "FIXTURE 100", "COA numbering leaves a gap",
     patch_fn(NEXT, "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1", "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 2")),
    ("101", "a-declared-module-gate", "FIXTURE 101", "the certificate read policy calls another module's code",
     "ALTER POLICY \"certificates_of_analysis select by permission\" ON public.certificates_of_analysis USING (has_permission('module.quality.view'));\n"),
    ("111", "a-service-interval", "FIXTURE 111F1", "the coa_facts_changed arm is renamed",
     patch_view("operations_now", "'coa_facts_changed'::text AS item_type", "'coa_facts_changedx'::text AS item_type")),
    ("254", None, "FIXTURE 254 NUM", "the COA document type is gone",
     "DELETE FROM public.document_types WHERE key = 'coa';\n"),
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
rc, out = run(body_of("264"), "")
if rc != 0 or "FIXTURE 264 全部通过" not in out:
    print("✗ the clean fixture 264 is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 264 全部通过")
for num, stem in sorted({(o[0], o[1]) for o in OTHER}, key=lambda x: (int(x[0]), x[1] or '')):
    rc, out = run(body_of(num, stem), "")
    if rc != 0:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: fixture {num} (exit 0)")

B = body_of("264")
arms = set()
for arm, name, inj in CASES_264:
    rc, out = run(B, inj)
    first, last_arm = where_red(out, "264")
    if rc == 0:
        print(f"✗ 264 {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ 264 {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 264 {arm}" in first or last_arm == arm:
        arms.add(arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ 264 {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ 264 {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
missing = {"REG", "N38", "GOV", "NEVER", "REFUSE", "ISSUE", "FROZEN", "BYTES", "VOID", "ARM", "TRAIL"} - arms
if missing:
    print(f"✗ fixture 264: arms never made red: {sorted(missing)}")
    bad += 1

for num, stem, needle, name, inj in OTHER:
    rc, out = run(body_of(num, stem), inj)
    first, last_arm = where_red(out, num)
    if rc != 0 and "INJECTION_DID_NOT_APPLY" not in out and needle in first:
        print(f"✓ fixture {num} · {name}: {first[first.index('ERROR'):][:200]}")
    else:
        print(f"✗ fixture {num} · {name}: expected '{needle}', got [{last_arm}] {first[:300]}")
        bad += 1

print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_264)} injections on 264 + {len(OTHER)} on 100 / 101 / 111 / 254, {bad} wrong)")
sys.exit(1 if bad else 0)
