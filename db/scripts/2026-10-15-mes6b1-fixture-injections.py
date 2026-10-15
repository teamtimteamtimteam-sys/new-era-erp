#!/usr/bin/env python3
"""MES-6b-1:fixture 263 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。
外加本刀改过的 fixture 各自的那一臂(149 K · 54 S · 230 C1 · 119 F2P · 262 PEN · 100 · 101 · 102 G · 111 F1),
以及 F8(MES-6a-2 close-out a 项、Tim 2026-10-15)的五格:
  F8-1  计价引擎【条款】那一侧的 SUBSTANCE_NOT_PAYABLE 自己拿掉 → 119 F2P(条款那一条路)红
  F8-2  公式【修改】那条路单独绕开守卫(只在修改申请的执行里把 f / cl 滤掉,新建那条路不动)→ 262 PAY(formula change)红
  F8-3  第九条变更记录豁免(一张真没绑的新表 + 名单里一行)→ 262 LOG 与 235 O1 都红(零缺口,只有"豁免是 8"那一句咬)
  F8-4  产出那条路只记三个指标(d10 / d90 丢掉)→ 262 IND 红(产出现在记全五个)
  F8-5  七个既有码之一不再是 payable_metal → 119 F1 红

做法照 db/scripts/2026-10-10-mes6a2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture <n> · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE <n> <臂>",
或者它发生时最后打出的那一臂就是 <臂>。别的 fixture 以它们自己的那一句(needle)认。
跑法:python3 db/scripts/2026-10-15-mes6b1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
退出码:0 = 每一支 fixture 干净跑绿、每一格都红在它的那一臂、263 的每一臂都至少红过一次;1 = 否则。
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


OPEN = "public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint)"
DECIDE = "public.decide_ncr(uuid, text, text, uuid, uuid)"
NEXT = "public.next_ncr_code(date)"
HOLDF = "public.batch_quality_hold(uuid, uuid)"
HOLDS = "public.ncr_holds(text, text, timestamp with time zone, numeric)"
GUARDH = "public.guard_quality_hold()"
JUDGE = "public.judge_quality_limits(uuid, uuid, text)"
REC = "public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb)"
RES = "public.reserve_stock_internal(uuid, uuid, numeric, uuid)"
SETTLE = "public.sale_settlement_compute(uuid, uuid, uuid)"
BLW = "public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb)"
BLR = "public.release_blending_plan(uuid)"
CAM = "public.contract_activation_missing(uuid)"
TRS = "public.terms_request_submit_internal(text, uuid, jsonb, text)"
TEX = "public.terms_request_execute_internal(uuid)"
CTS = "public.contract_terms_state(uuid)"
LINK = "public.link_document_to_contract(text, uuid, uuid)"
SUPP = "public.assay_is_supplement(uuid)"
APPLY = "public.apply_assay_result(uuid, uuid, date)"
APPLYO = "public.apply_output_assay(uuid)"
PREV = "public.preview_assay_price(uuid, jsonb, date)"
UNAPPLY = "public.unapply_assay_result(uuid, text)"
ENGINE = "public.calculate_metal_price_from_terms(jsonb, jsonb, numeric, date)"
TS = "public.trail_subjects()"
EXCL = "public.change_log_exclusions()"
WIDEN = "public.arm_permission_widen(text)"
ANY = "public.arm_permission_any(text)"


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


def drop_trigger(table, trig):
    return f"DROP TRIGGER {trig} ON public.{table};\n"


G_BLOCK = "NEW.movement_type IN ('processing_consume', 'sale')"
G_COMMITTED = "(NEW.movement_type = 'status_change_in' AND NEW.stock_status = 'committed')"
G_CTX = "AND COALESCE(current_setting('evoltrya.warehouse_request_ctx', true), '') = ''"
H_REJECT = "OR (p_status = 'decided' AND p_disposition = 'reject'"
H_STOCK = """
                        AND p_batch_deleted_at IS NULL AND COALESCE(p_remaining_qty, 0) > 0), false)"""
HOLD_CHECK_SETTLE = "SELECT h.ncr_code INTO v_hold FROM batch_quality_hold(NULL::uuid, p_output_batch_id) h;"
HOLD_CHECK_BLW = "SELECT h.ncr_code INTO v_hold FROM batch_quality_hold(v_ib, v_ob) h;"
J_PREF = "ORDER BY e ->> 'parameter', ((e ->> 'material_id') IS NULL)"
J_DEDUPE = """        IF EXISTS (SELECT 1 FROM quality_limit_judgements j
                    WHERE j.output_batch_id = p_output_batch_id AND j.sales_order_id = p_sales_order_id
                      AND j.assay_result_id = v_assay.id AND j.parameter = v_lim.parameter) THEN"""
J_GOV = "WHERE d.output_batch_id = p_output_batch_id AND d.status = 'resolved'"
J_PARTY = "           AND a.result_party = (v_t.settlement_terms ->> 'settling_party')\n"
J_NCR = "        IF v_res IN ('below_min', 'above_max') THEN"
SUPP_BODY = "    SELECT NOT EXISTS (SELECT 1 FROM assay_result_metals m"

CASES_263 = [
    # ── REG ──
    ("REG", "action.ncr_decide declares another page's view code",
     "UPDATE public.permissions SET requires_view_any = ARRAY['module.output.view'] WHERE code = 'action.ncr_decide';\n"),
    ("REG", "the NCR document type routes elsewhere",
     "UPDATE public.document_types SET route = '/quality/samples' WHERE key = 'ncr';\n"),
    ("REG", "NCRs are not change-logged",
     drop_trigger("nonconformance_reports", "zzz_change_log")),
    ("REG", "the trail has no ncr subject",
     patch_fn(TS, "('ncr',                    ARRAY['module.quality.view'],", "('ncr_x',                  ARRAY['module.quality.view'],")),
    # ── NCR ──
    ("NCR", "anyone may open an NCR (the code check is gone)",
     patch_fn(OPEN, "    PERFORM require_permission('module.quality.edit');\n", "")),
    ("NCR", "two batches are not refused by name",
     patch_fn(OPEN, "    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN", "    IF false THEN")),
    ("NCR", "a person may open a quality_limit NCR",
     patch_fn(OPEN, "    IF p_source = 'quality_limit' THEN", "    IF false THEN")),
    ("NCR", "inspection is not reserved",
     patch_fn(OPEN, "    ELSIF p_source = 'inspection' THEN", "    ELSIF false THEN")),
    ("NCR", "a blank description is not refused by name",
     patch_fn(OPEN, "    IF p_description IS NULL OR btrim(p_description) = '' THEN", "    IF p_description IS NULL THEN")),
    ("NCR", "a linked assay of another batch is accepted",
     patch_fn(OPEN, "    IF p_assay_result_id IS NOT NULL AND NOT EXISTS (", "    IF false AND NOT EXISTS (")),
    ("NCR", "numbering leaves a gap",
     patch_fn(NEXT, "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1", "COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 2")),
    ("NCR", "an NCR can be rewritten and deleted (the append-only guard is gone)",
     drop_trigger("nonconformance_reports", "trg_nonconformance_reports_mutation")),
    ("NCR", "an NCR can be inserted directly",
     "CREATE POLICY \"ncr insert (injected)\" ON public.nonconformance_reports AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);\n"
     "GRANT INSERT ON public.nonconformance_reports TO authenticated;\n"),
    # ── DECIDE ──
    ("DECIDE", "anyone may decide (the code check is gone)",
     patch_fn(DECIDE, "    PERFORM require_permission('action.ncr_decide');\n", "")),
    ("DECIDE", "the opener decides their own NCR",
     patch_fn(DECIDE, "    PERFORM forbid_self_approval(v_n.opened_by, NULL::uuid, 'ncr');\n", "")),
    ("DECIDE", "a blank note is not refused by name",
     patch_fn(DECIDE, "    IF p_note IS NULL OR btrim(p_note) = '' THEN", "    IF p_note IS NULL THEN")),
    ("DECIDE", "accept carries a money document",
     patch_fn(DECIDE, "    ELSIF p_penalty_invoice_request_id IS NOT NULL OR p_penalty_price_request_id IS NOT NULL THEN", "    ELSIF false THEN")),
    ("DECIDE", "any price request is accepted as the money document",
     patch_fn(DECIDE, "                              AND r.inbound_batch_id = v_n.inbound_batch_id AND r.status IN ('submitted', 'approved')) THEN",
              "                              AND false) THEN")),
    ("DECIDE", "a decided NCR is not refused by name (NCR_NOT_OPEN)",
     patch_fn(DECIDE, "    IF v_n.status <> 'open' THEN", "    IF false THEN")),
    ("DECIDE", "an NCR is opened with nobody else to decide it",
     patch_fn(OPEN, "    IF NOT EXISTS (SELECT 1\n                     FROM role_permissions rp", "    IF false AND NOT EXISTS (SELECT 1\n                     FROM role_permissions rp")),
    ("DECIDE", "the opener's own decide code counts as another decider",
     patch_fn(OPEN, "AND self_leg(v_user, NULL::uuid, g.user_id) = 'none') THEN", "AND true) THEN")),
    # ── HOLD ──
    ("HOLD", "the ledger guard is gone",
     drop_trigger("inventory_movements", "trg_inventory_movements_quality_hold")),
    ("HOLD", "consumption is not blocked",
     patch_fn(GUARDH, G_BLOCK, "NEW.movement_type IN ('sale')")),
    ("HOLD", "a sale / the shipment leg is not blocked",
     patch_fn(GUARDH, G_BLOCK, "NEW.movement_type IN ('processing_consume')")),
    ("HOLD", "a reservation (status leg into committed) is not blocked",
     patch_fn(GUARDH, G_COMMITTED, "false")),
    ("HOLD", "a write-off outside a request is not blocked",
     patch_fn(GUARDH, G_CTX, "AND false")),
    ("HOLD", "over-reach: transfers are blocked too",
     patch_fn(GUARDH, G_BLOCK, "NEW.movement_type IN ('processing_consume', 'sale', 'transfer_out', 'transfer_in')")),
    ("HOLD", "over-reach: the CFO write-off is blocked too",
     patch_fn(GUARDH, G_CTX, "AND true")),
    ("HOLD", "over-reach: releasing to available is blocked too",
     patch_fn(GUARDH, G_COMMITTED, "(NEW.movement_type = 'status_change_in')")),
    # ── SETTLE ──
    ("SETTLE", "settlement does not ask about the hold",
     patch_fn(SETTLE, HOLD_CHECK_SETTLE, "SELECT NULL::text AS ncr_code INTO v_hold WHERE false;")),
    # ── DISP ──
    ("DISP", "reject releases the hold",
     patch_fn(HOLDS, H_REJECT, "OR (false AND p_disposition = 'reject'")),
    ("DISP", "reject holds even after the stock is gone (the write-off does not end it)",
     patch_fn(HOLDS, H_STOCK, "), false)")),
    ("DISP", "accept_with_penalty for an output batch names no credit note",
     patch_fn(DECIDE, "            IF p_penalty_invoice_request_id IS NULL OR p_penalty_price_request_id IS NOT NULL THEN", "            IF false THEN")),
    # ── BLEND ──
    ("BLEND", "a held batch can be a plan line",
     patch_fn(BLW, HOLD_CHECK_BLW, "SELECT NULL::text AS ncr_code INTO v_hold WHERE false;")),
    ("BLEND", "a plan with a held line is released",
     patch_fn(BLR, "     WHERE l.plan_id = p_plan_id\n     ORDER BY h.batch_code", "     WHERE l.plan_id = p_plan_id AND false\n     ORDER BY h.batch_code")),
    # ── V17 ──
    ("V17", "an unset basis is not on the checklist",
     patch_fn(CAM, "           WHERE st.id IS NOT NULL AND st.quality_limit_basis IS NULL", "           WHERE false")),
    ("V17", "per_parameter with no rows is not on the checklist",
     patch_fn(CAM, "           WHERE st.quality_limit_basis = 'per_parameter'\n", "           WHERE false AND st.quality_limit_basis = 'per_parameter'\n")),
    ("V17", "QUALITY_LIMITS_NOT_FILED is not said by name",
     patch_fn(TRS, "        IF 'quality_limits' = ANY (v_missing) THEN", "        IF false THEN")),
    ("V17", "priced-and-penalised is not on the checklist",
     patch_fn(CAM, "           WHERE pt.contract_id = c.id\n             AND EXISTS (SELECT 1 FROM contract_penalty_elements pe",
              "           WHERE false AND pt.contract_id = c.id\n             AND EXISTS (SELECT 1 FROM contract_penalty_elements pe")),
    ("V17", "pricing a penalised metal is not refused at the terms",
     drop_trigger("contract_pricing_terms", "trg_contract_pricing_terms_unpenalised")),
    ("V17", "penalising a priced metal is not refused at the terms",
     drop_trigger("contract_penalty_elements", "trg_contract_penalty_elements_unpriced")),
    ("V17", "quality limits do not freeze with the contract",
     drop_trigger("contract_quality_limits", "trg_contract_quality_limits_frozen")),
    ("V17", "the CFO's terms state leaves the limits out",
     patch_fn(CTS, "'quality_limits', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (", "'quality_limits_x', COALESCE((SELECT jsonb_agg(x.j ORDER BY x.j::text) FROM (")),
    ("V17", "the link does not copy the limits",
     patch_fn(LINK, "                         'quality_limits', COALESCE((", "                         'quality_limits_x', COALESCE((")),
    ("V17", "F4 undone: a payable metal is refused as a penalty element",
     drop_trigger("contract_penalty_elements", "trg_contract_penalty_elements_substance_role")
     + "CREATE TRIGGER trg_contract_penalty_elements_substance_role BEFORE INSERT OR UPDATE OF substance ON public.contract_penalty_elements "
       "FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('penalty_element', 'substance');\n"),
    # ── JUDGE ──
    ("JUDGE", "recording an output assay judges nothing",
     patch_fn(REC, "            v_judge := judge_quality_limits(p_output_batch_id, v_so, 'assay_recorded');", "            v_judge := jsonb_build_object('judged', 0, 'ncrs', '[]'::jsonb);")),
    ("JUDGE", "reserving judges nothing",
     patch_fn(RES, "    v_judge := judge_quality_limits(p_output_batch_id, v_line.order_id, 'reserved');", "    v_judge := jsonb_build_object('judged', 0, 'ncrs', '[]'::jsonb);")),
    ("JUDGE", "the general limit wins over the material's own",
     patch_fn(JUDGE, J_PREF, "ORDER BY e ->> 'parameter', ((e ->> 'material_id') IS NOT NULL)")),
    ("JUDGE", "the same assay is judged again",
     patch_fn(JUDGE, J_DEDUPE, "        IF false THEN")),
    ("JUDGE", "a resolved dispute's governing assay is ignored",
     patch_fn(JUDGE, J_GOV, "WHERE false AND d.output_batch_id = p_output_batch_id AND d.status = 'resolved'")),
    ("JUDGE", "any party's latest result is judged",
     patch_fn(JUDGE, J_PARTY, "")),
    ("JUDGE", "a breach opens no NCR",
     patch_fn(JUDGE, J_NCR, "        IF false THEN")),
    ("JUDGE", "a judgement can be rewritten",
     drop_trigger("quality_limit_judgements", "trg_quality_limit_judgements_append_only")),
    # ── F5 ──
    ("F5", "nothing is a supplement",
     patch_fn(SUPP, SUPP_BODY, "    SELECT false AND NOT EXISTS (SELECT 1 FROM assay_result_metals m")),
    ("F5", "an inbound supplement wipes the content",
     patch_fn(APPLY, "     WHERE inbound_batch_id = v_batch.id AND (NOT v_supp OR metal = ANY (v_measured));", "     WHERE inbound_batch_id = v_batch.id;")),
    ("F5", "the preview does not say supplement",
     patch_fn(PREV, "        RETURN jsonb_build_object('calc', NULL, 'impact', NULL, 'supplement', true, 'replaces', v_sub);", "        NULL;")),
    ("F5", "unapplying a supplement leaves its rows",
     patch_fn(UNAPPLY, "    IF v_supp THEN\n        IF v_assay.inbound_batch_id IS NOT NULL THEN", "    IF false THEN\n        IF v_assay.inbound_batch_id IS NOT NULL THEN")),
    ("F5", "a supplement is superseded by the next full assay",
     patch_fn(APPLY, "      AND NOT assay_is_supplement(id)\n", "")),
    # ── ARMS ──
    ("ARMS", "the ncr_open arm is gone",
     patch_view("operations_now", "'ncr_open'::text AS item_type", "'ncr_open_x'::text AS item_type")),
    ("ARMS", "quality_hold_reserved is not narrowed to output viewers",
     patch_fn(ANY, "                WHEN p_item_type = 'quality_hold_reserved'\n                THEN ARRAY['module.output.view']\n", "")),
    ("ARMS", "quality_hold_reserved is not widened to sales viewers",
     patch_fn(WIDEN, "                WHEN p_item_type = 'quality_hold_reserved'\n                THEN ARRAY['module.sales.view']\n", "")),
    ("ARMS", "the prompt forgets contamination above V11",
     patch_view("operations_now", "(cc.above_warning IS TRUE)", "false")),
    ("ARMS", "the prompt forgets failed modules",
     patch_view("operations_now", "(dm.verdict = 'fail'::text)", "false")),
    ("ARMS", "the prompt forgets grade breaches",
     patch_view("operations_now", "FROM (contract_grade_breaches gb", "FROM (contract_grade_breaches gb JOIN (SELECT 1 AS z WHERE false) zz ON true")),
    ("ARMS", "an NCR does not clear the prompt",
     patch_view("operations_now", "(n2.opened_at >= q.found_at)", "false")),
    ("ARMS", "V17 is gone",
     patch_view("pending_values", "'V17'::text AS value_code", "'V17x'::text AS value_code")),
    # ── LOG ──
    ("LOG", "the NCR change-log trigger keys its rows on the wrong column (still bound and enabled — the coverage check sees nothing)",
     drop_trigger("nonconformance_reports", "zzz_change_log")
     + "CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.nonconformance_reports FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');\n"),
]

OTHER = [
    # 本刀改过的那几支 fixture 各自那一臂
    ("149", None, "FIXTURE 149K", "settlement prices a penalised-only copper again (F4 skip gone)",
     patch_fn(SETTLE, "           AND NOT COALESCE(v_st->>'penalty_basis' = 'per_element'", "           AND NOT COALESCE(false")),
    ("149", None, "FIXTURE 149K", "pricing a penalised copper is not refused at the terms",
     drop_trigger("contract_pricing_terms", "trg_contract_pricing_terms_unpenalised")),
    ("54", None, "FIXTURE 54S", "an output supplement wipes the content",
     patch_fn(APPLYO, "     WHERE output_batch_id = v_batch.id AND (NOT v_supp OR metal = ANY (v_measured));", "     WHERE output_batch_id = v_batch.id;")),
    ("54", None, "FIXTURE 54S", "nothing is a supplement",
     patch_fn(SUPP, SUPP_BODY, "    SELECT false AND NOT EXISTS (SELECT 1 FROM assay_result_metals m")),
    ("230", None, "FIXTURE 230C1", "the checklist forgets the V17 basis",
     patch_fn(CAM, "           WHERE st.id IS NOT NULL AND st.quality_limit_basis IS NULL", "           WHERE false")),
    ("119", None, "FIXTURE 119F2P", "F4 undone: copper refused as a penalty element",
     drop_trigger("contract_penalty_elements", "trg_contract_penalty_elements_substance_role")
     + "CREATE TRIGGER trg_contract_penalty_elements_substance_role BEFORE INSERT OR UPDATE OF substance ON public.contract_penalty_elements "
       "FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('penalty_element', 'substance');\n"),
    ("262", None, "FIXTURE 262 PEN", "penalising a priced copper is accepted",
     drop_trigger("contract_penalty_elements", "trg_contract_penalty_elements_unpriced")),
    ("262", None, "FIXTURE 262 PEN", "the penalty guard takes any role (other is accepted)",
     drop_trigger("contract_penalty_elements", "trg_contract_penalty_elements_substance_role")),
    ("100", "every-document", "FIXTURE 100/1", "the NCR document type is missing",
     "DELETE FROM public.document_types WHERE key = 'ncr';\n"),
    ("101", "a-declared-module-gate", "FIXTURE 101", "the NCR document type declares a gate its read policy does not call first",
     "UPDATE public.document_types SET view_permission = ARRAY['module.sales.view']::text[] WHERE key = 'ncr';\n"),
    ("102", "logistics-alerts", "FIXTURE 102G", "the reserved-hold arm is widened to finance as well",
     patch_fn(WIDEN, "THEN ARRAY['module.sales.view']", "THEN ARRAY['module.sales.view', 'module.finance.view']")
     + patch_fn(WIDEN, "                WHEN p_item_type = 'quality_hold_reserved'", "                WHEN p_item_type IN ('quality_hold_reserved', 'ncr_open')")),
    ("111", None, "FIXTURE 111F1", "the quality_prompt_ncr arm is renamed",
     patch_view("operations_now", "'quality_prompt_ncr'::text AS item_type", "'quality_prompt'::text AS item_type")),
    # ── F8 ──
    ("119", None, "FIXTURE 119F2P", "F8-1 the engine's terms-side SUBSTANCE_NOT_PAYABLE is gone",
     patch_fn(ENGINE, "      JOIN substances s ON s.code = k WHERE s.role <> 'payable_metal' ORDER BY k LIMIT 1;",
              "      JOIN substances s ON s.code = k WHERE false ORDER BY k LIMIT 1;")),
    ("262", None, "formula change", "F8-2 the formula-change path alone drops a penalty element instead of refusing it",
     patch_fn(TEX, "    SELECT v_r.formula_id, e->>'metal', (e->>'payable_pct')::numeric\n      FROM jsonb_array_elements(v_t->'metals') e\n",
              "    SELECT v_r.formula_id, e->>'metal', (e->>'payable_pct')::numeric\n      FROM jsonb_array_elements(v_t->'metals') e WHERE e->>'metal' NOT IN ('f', 'cl')\n")),
    ("262", None, "FIXTURE 262 LOG", "F8-3 a ninth change-log exclusion (on a genuinely unbound table)",
     "CREATE TABLE public.zz_inj_ninth (id int PRIMARY KEY);\n"
     + patch_fn(EXCL, "('scan_events', ", "('zz_inj_ninth', 'injected'), ('scan_events', ")),
    ("235", None, "FIXTURE 235O1", "F8-3 a ninth change-log exclusion (on a genuinely unbound table)",
     "CREATE TABLE public.zz_inj_ninth (id int PRIMARY KEY);\n"
     + patch_fn(EXCL, "('scan_events', ", "('zz_inj_ninth', 'injected'), ('scan_events', ")),
    ("262", None, "FIXTURE 262 IND", "F8-4 the output path records only three of the five indicators",
     patch_fn(REC, "        v_iseen := v_iseen || v_ind;\n",
              "        v_iseen := v_iseen || v_ind;\n        IF p_output_batch_id IS NOT NULL AND v_ind IN ('d10_um', 'd90_um') THEN CONTINUE; END IF;\n")),
    ("119", None, "FIXTURE 119F1", "F8-5 one of the seven is no longer a payable metal",
     "UPDATE public.substances SET role = 'other' WHERE code = 'fe';\n"),
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
rc, out = run(body_of("263"), "")
if rc != 0 or "FIXTURE 263 全部通过" not in out:
    print("✗ the clean fixture 263 is not green:\n" + out[-1500:])
    sys.exit(1)
print("✓ clean: FIXTURE 263 全部通过")
for num, stem in sorted({(o[0], o[1]) for o in OTHER}, key=lambda x: (int(x[0]), x[1] or '')):
    rc, out = run(body_of(num, stem), "")
    if rc != 0:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: fixture {num} (exit 0)")

B = body_of("263")
arms = set()
for arm, name, inj in CASES_263:
    rc, out = run(B, inj)
    first, last_arm = where_red(out, "263")
    if rc == 0:
        print(f"✗ 263 {arm} · {name}: did NOT go red")
        bad += 1
    elif "INJECTION_DID_NOT_APPLY" in out:
        print(f"✗ 263 {arm} · {name}: the injection did not apply — {first}")
        bad += 1
    elif f"FIXTURE 263 {arm}" in first or last_arm == arm:
        arms.add(arm)
        shown = first[first.index("ERROR"):][:200] if "ERROR" in first else first
        print(f"✓ 263 {arm} · {name}: [{last_arm}] {shown}")
    else:
        print(f"✗ 263 {arm} · {name}: red in the wrong place [{last_arm}] — {first[:300]}")
        bad += 1
missing = {"REG", "NCR", "DECIDE", "HOLD", "SETTLE", "DISP", "BLEND", "V17", "JUDGE", "F5", "ARMS", "LOG"} - arms
if missing:
    print(f"✗ fixture 263: arms never made red: {sorted(missing)}")
    bad += 1

for num, stem, needle, name, inj in OTHER:
    rc, out = run(body_of(num, stem), inj)
    first, last_arm = where_red(out, num)
    if rc != 0 and "INJECTION_DID_NOT_APPLY" not in out and needle in first:
        print(f"✓ fixture {num} · {name}: {first[first.index('ERROR'):][:200]}")
    else:
        print(f"✗ fixture {num} · {name}: expected '{needle}', got [{last_arm}] {first[:300]}")
        bad += 1

print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_263)} injections on 263 + {len(OTHER)} on 149 / 54 / 230 / 119 / 262 / 100 / 101 / 102 / 111 / 235 (F8's five among them), {bad} wrong)")
sys.exit(1 if bad else 0)
