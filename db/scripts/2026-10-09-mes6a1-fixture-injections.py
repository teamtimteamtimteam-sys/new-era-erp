#!/usr/bin/env python3
"""MES-6a-1:fixture 260 与 261 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。
外加本刀改过的六支 fixture 各自的新臂:40 F · 118 F5 · 149 J · 220 I6 · 258 F3 · 100(SMP 那一行没了)· 111(提醒臂改了名)。

做法照 db/scripts/2026-10-09-mes5b3-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
【红在哪一臂】fixture 每进一臂先打一行 NOTICE "fixture 26x · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着 "FIXTURE 26x <臂>",
或者它发生时最后打出的那一臂就是 <臂>。别的 fixture 以它们自己的那一句(needle)认。
跑法:python3 db/scripts/2026-10-09-mes6a1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"
退出码:0 = 每一支 fixture 干净跑绿、每一格都红在它的那一臂、260 / 261 的每一臂都至少红过一次;1 = 否则。

【刻意没写成一格的(层数),照直记下,不假装它们被证过】
  · "记录函数不再判样品是不是同一批" 单独注入不会红 —— 表上的守卫说同一句话(SAMPLE_NOT_FOR_BATCH)。所以写成两格:只拿掉守卫(直插那一句红),
    以及函数与守卫一起拿掉(函数那一句红)。
  · "reverse_expense 不再判理由" 单独注入在 261 不会红 —— reverse_expense_internal 与行守卫各自再拒同一句。它在 258 F3 红(那里要求理由
    【先于】电费单那一道拒);261 那一格把三层一起拿掉,只剩表上的 CHECK,于是说的话变了、红。
  · "一批同时一件开着的争议" 函数的判与唯一索引是两层 —— 一格把两层一起拿掉。
  · "应用化验不再看争议" 单独注入不会红 —— 应用在同一事务里提一张化验来源的定价申请,而提交会照批准那一刻的同一支过账【试跑】
    (receipt_price_post_internal),那里再看一次争议,说同一句话。所以那一格把应用与过账那一处一起拿掉(第一次跑时注入抓到的,不是事先想到的)。
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


REC_SAMPLE = "public.record_sample(text, date, uuid, uuid, numeric, uuid, bigint, uuid, text)"
REC_EVENT = "public.record_sample_event(uuid, text, timestamp with time zone, text, text, uuid, text, text)"
SET_Q = "public.set_quality_settings(integer)"
CODE = "public.next_sample_code(date)"
REC_ASSAY = "public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)"
OPEN = "public.open_assay_dispute(uuid, uuid, text, uuid)"
UMP = "public.record_dispute_umpire(uuid, uuid, uuid)"
RESOLVE = "public.resolve_assay_dispute(uuid, uuid, text)"
FEE = "public.link_dispute_fee(uuid, uuid)"
APPLY = "public.apply_assay_result(uuid, uuid, date)"
APPLY_OUT = "public.apply_output_assay(uuid)"
PREVIEW = "public.preview_assay_price(uuid, jsonb, date)"
POST = "public.receipt_price_post_internal(uuid)"
SETTLE = "public.sale_settlement_compute(uuid, uuid, uuid)"
REV = "public.reverse_expense(uuid, text)"
REV_INT = "public.reverse_expense_internal(uuid, text)"
REV_ELEC = "public.reverse_electricity_allocation(uuid, text)"
GUARD = "public.guard_expense_mutation()"
PAYEE = "public.payment_request_payee_check(text, uuid)"
TSM = "public.trail_subject_members()"

DISPUTE_SELECT_APPLY = "SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.inbound_batch_id = v_batch.id AND d.status = 'open';"


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


CASES_260 = [
    # ── SMP ──
    ("SMP", "codes are off by one (numbering no longer MAX+1)",
     patch_fn(CODE, "LPAD(v_seq::text, 4, '0')", "LPAD((v_seq + 1)::text, 4, '0')")),
    ("SMP", "the SMP row reads another permission",
     "UPDATE document_types SET view_permission = ARRAY['module.inbound.view'] WHERE key = 'sample';\n"),
    # ── CUST ──
    ("CUST", "taking a sample writes no 'taken' event",
     patch_fn(REC_SAMPLE, "    INSERT INTO sample_events (sample_id, event_kind, occurred_at, storage_location_id, created_by)\n"
                          "    VALUES (v_id, 'taken', (p_taken_on::timestamp) AT TIME ZONE 'Asia/Singapore', p_storage_location_id, v_user);\n", "")),
    ("CUST", "at the lab it can be sent again and moved",
     patch_fn(REC_EVENT, "OR (v_state = 'at_lab' AND p_event_kind IN ('received_back', 'disposed'))", "OR (v_state = 'at_lab')")),
    ("CUST", "an event may be dated before the last one",
     patch_fn(REC_EVENT, "IF p_occurred_at < v_last.occurred_at THEN", "IF false THEN")),
    ("CUST", "custody events are no longer append-only",
     "DROP TRIGGER trg_sample_events_append_only ON public.sample_events;\n"),
    ("CUST", "an inactive laboratory is accepted",
     patch_fn(REC_EVENT, "WHERE code = p_laboratory_code AND is_active", "WHERE code = p_laboratory_code")),
    ("CUST", "the state is read from the first event, not the latest",
     patch_view("sample_rows", "ORDER BY x.id DESC", "ORDER BY x.id")),
    ("CUST", "a disposal needs no reason (the function check is gone; the table CHECK answers in its own words)",
     patch_fn(REC_EVENT, "IF p_event_kind = 'disposed' AND v_reason IS NULL THEN", "IF false THEN")),
    ("CUST", "a quality editor can insert into samples directly",
     "CREATE POLICY \"samples insert (injected)\" ON public.samples AS PERMISSIVE FOR INSERT TO authenticated WITH CHECK (true);\n"
     "GRANT INSERT ON public.samples TO authenticated;\n"),
    # ── RET ──
    ("RET", "the contract's retention days are ignored",
     patch_fn(REC_SAMPLE, "IF COALESCE((v_st ->> 'sample_retention_required')::boolean, false)", "IF false")),
    ("RET", "V16 is ignored",
     patch_fn(REC_SAMPLE, "SELECT q.internal_retention_days INTO v_days FROM quality_settings q WHERE q.id;", "v_days := NULL;")),
    ("RET", "changing V16 re-dates the existing internal samples",
     patch_fn(SET_Q, "    IF NOT FOUND THEN\n        RAISE EXCEPTION 'QUALITY_SETTINGS_MISSING';\n    END IF;",
              "    IF NOT FOUND THEN\n        RAISE EXCEPTION 'QUALITY_SETTINGS_MISSING';\n    END IF;\n"
              "    UPDATE samples SET retain_until = taken_on + p_internal_retention_days, retention_days_at = p_internal_retention_days\n"
              "     WHERE retain_until_source = 'internal' AND p_internal_retention_days IS NOT NULL;")),
    ("RET", "an inbound sample may name a sales order (the table CHECK answers in its own words)",
     patch_fn(REC_SAMPLE, "        IF p_output_batch_id IS NULL THEN\n            RAISE EXCEPTION 'SAMPLE_SALES_ORDER_NEEDS_OUTPUT_BATCH';",
              "        IF false THEN\n            RAISE EXCEPTION 'SAMPLE_SALES_ORDER_NEEDS_OUTPUT_BATCH';")),
    ("RET", "a sampling date in the future is accepted",
     patch_fn(REC_SAMPLE, "IF p_taken_on > (now() AT TIME ZONE 'Asia/Singapore')::date THEN", "IF false THEN")),
    ("RET", "a not-sampled contamination check is accepted",
     patch_fn(REC_SAMPLE, "IF NOT FOUND OR v_check.kind <> 'sampled' OR v_check.output_batch_id IS DISTINCT FROM p_output_batch_id THEN",
              "IF NOT FOUND THEN")),
    # ── ASSAY ──
    ("ASSAY", "the table guard is gone (a direct write of another batch's sample goes in)",
     "DROP TRIGGER trg_assay_results_sample_batch ON public.assay_results;\n"),
    ("ASSAY", "neither the function nor the guard checks the sample's batch",
     patch_fn(REC_ASSAY, "IF p_sample_id IS NOT NULL AND NOT EXISTS (", "IF false AND NOT EXISTS (")
     + "DROP TRIGGER trg_assay_results_sample_batch ON public.assay_results;\n"),
    ("ASSAY", "the sample is not stored on the assay",
     patch_fn(REC_ASSAY, "p_result_party, p_sample_id,", "p_result_party, NULL,")),
    # ── EARLY ──
    ("EARLY", "the retention reminder never fires",
     patch_view("operations_now", "(s.retain_until < CURRENT_DATE)", "(s.retain_until < (CURRENT_DATE - 1000))")),
    ("EARLY", "an early disposal is not flagged",
     patch_view("sample_rows", "::date < s.retain_until)) AS disposed_early", "::date < (s.retain_until - 1000))) AS disposed_early")),
    # ── CODES ──
    ("CODES", "taking a sample asks only the view code",
     patch_fn(REC_SAMPLE, "PERFORM require_permission('module.quality.edit');", "PERFORM require_permission('module.quality.view');")),
    ("CODES", "action.apply_assay no longer declares module.quality.view",
     "UPDATE permissions SET requires_view_any = ARRAY['module.inbound.view','module.output.view'] WHERE code = 'action.apply_assay';\n"),
    ("CODES", "the bootstrap warehouse holds quality edit (Q12 says no)",
     "INSERT INTO role_permissions (role_id, permission_code) SELECT id, 'module.quality.edit' FROM roles WHERE code = 'warehouse';\n"),
    # ── READ ──
    ("READ", "samples are readable by everyone",
     "DROP POLICY \"samples select by permission\" ON public.samples;\n"
     "CREATE POLICY \"samples select by permission\" ON public.samples AS PERMISSIVE FOR SELECT TO authenticated USING (true);\n"),
    ("READ", "custody events are readable by everyone",
     "DROP POLICY \"sample_events select by permission\" ON public.sample_events;\n"
     "CREATE POLICY \"sample_events select by permission\" ON public.sample_events AS PERMISSIVE FOR SELECT TO authenticated USING (true);\n"),
    ("READ", "sample_rows shows every sample to a batch viewer",
     patch_view("sample_rows", "OR ((s.output_batch_id IS NOT NULL) AND has_permission('module.output.view'::text))", "OR true")),
    # ── LOG ──
    ("LOG", "samples are not change-logged",
     "DROP TRIGGER zzz_change_log ON public.samples;\n"),
    ("LOG", "custody is not on the sample's trail",
     patch_fn(TSM, "('sample',             1, 'sample_events',", "('sample_x',           1, 'sample_events',")),
    # ── PV ──
    ("PV", "V16 is listed even once it is set",
     patch_view("pending_values", "(qs.internal_retention_days IS NULL)", "true")),
]

CASES_261 = [
    # ── OPEN ──
    ("OPEN", "opening asks only the view code",
     patch_fn(OPEN, "PERFORM require_permission('module.quality.edit');", "PERFORM require_permission('module.quality.view');")),
    ("OPEN", "the 'ours' side is not checked by party",
     patch_fn(OPEN, "IF v_ours.result_party <> 'ours' THEN", "IF false THEN")),
    ("OPEN", "two batches can be put in one dispute",
     patch_fn(OPEN, "IF v_ours.inbound_batch_id IS DISTINCT FROM v_cp.inbound_batch_id\n       OR v_ours.output_batch_id IS DISTINCT FROM v_cp.output_batch_id THEN",
              "IF false THEN")),
    ("OPEN", "two open disputes on one batch (function check and unique index both gone)",
     patch_fn(OPEN, "IF EXISTS (SELECT 1 FROM assay_disputes d WHERE d.inbound_batch_id = v_ours.inbound_batch_id AND d.status = 'open') THEN",
              "IF false THEN")
     + "DROP INDEX public.uq_assay_disputes_one_open_inbound;\n"),
    # ── HOLD ──
    ("HOLD", "apply and the posting check (which the request's submit dry-runs) no longer see the open dispute",
     patch_fn(APPLY, DISPUTE_SELECT_APPLY, DISPUTE_SELECT_APPLY.replace("d.status = 'open'", "d.status = 'none'"))
     + patch_fn(POST, "    IF v_r.source = 'assay' THEN\n        SELECT d.id INTO v_disp", "    IF false THEN\n        SELECT d.id INTO v_disp")),
    ("HOLD", "preview no longer sees the open dispute (parity)",
     patch_fn(PREVIEW, DISPUTE_SELECT_APPLY, DISPUTE_SELECT_APPLY.replace("d.status = 'open'", "d.status = 'none'"))),
    ("HOLD", "a waiting assay request posts despite the dispute",
     patch_fn(POST, "    IF v_r.source = 'assay' THEN\n        SELECT d.id INTO v_disp", "    IF false THEN\n        SELECT d.id INTO v_disp")),
    ("HOLD", "manual and committed-terms repricing are held too (over-reach)",
     patch_fn(POST, "    IF v_r.source = 'assay' THEN\n        SELECT d.id INTO v_disp", "    IF true THEN\n        SELECT d.id INTO v_disp")),
    ("HOLD", "withdrawing asks only the view code",
     patch_fn("public.withdraw_assay_dispute(uuid, text)", "PERFORM require_permission('module.quality.edit');", "PERFORM require_permission('module.quality.view');")),
    # ── RESOLVE ──
    ("RESOLVE", "resolving asks quality edit instead of action.apply_assay",
     patch_fn(RESOLVE, "PERFORM require_permission('action.apply_assay');", "PERFORM require_permission('module.quality.edit');")),
    ("RESOLVE", "resolving applies something (it finalises the batch's pricing status)",
     patch_fn(RESOLVE, "    RETURN jsonb_build_object('dispute_id', p_dispute_id, 'status', 'resolved'",
              "    UPDATE inbound_batches SET pricing_status = 'final' WHERE id = v_d.inbound_batch_id;\n"
              "    RETURN jsonb_build_object('dispute_id', p_dispute_id, 'status', 'resolved'")),
    ("RESOLVE", "a result from another batch can govern",
     patch_fn(RESOLVE, "IF NOT FOUND OR v_a.inbound_batch_id IS DISTINCT FROM v_d.inbound_batch_id\n       OR v_a.output_batch_id IS DISTINCT FROM v_d.output_batch_id THEN",
              "IF NOT FOUND THEN")),
    # ── D4 ──
    ("D4", "inbound: applying any party's result supersedes ours (the old rule)",
     patch_fn(APPLY, "      AND result_party = v_assay.result_party\n", "")),
    ("D4", "output: applying any party's result supersedes ours (the old rule)",
     patch_fn(APPLY_OUT, "      AND result_party = v_assay.result_party\n", "")),
    # ── SELL ──
    ("SELL", "settlement no longer sees the open dispute",
     patch_fn(SETTLE, "WHERE d.output_batch_id = p_output_batch_id AND d.status = 'open';", "WHERE d.output_batch_id = p_output_batch_id AND d.status = 'none';")),
    ("SELL", "the contract's limit is not copied onto the dispute",
     patch_fn(OPEN, "v_limit := (v_st ->> 'splitting_limit_pct')::numeric;", "v_limit := NULL;")),
    # ── FEE ──
    ("FEE", "the fee may be owed to anyone",
     patch_fn(FEE, "IF v_exp.supplier_id IS DISTINCT FROM v_sup THEN", "IF false THEN")),
    ("FEE", "a lab with no supplier is not refused by name",
     patch_fn(FEE, "IF v_sup IS NULL THEN", "IF false THEN")),
    ("FEE", "the umpire result may be anyone's",
     patch_fn(UMP, "IF v_a.result_party <> 'umpire' THEN", "IF false THEN")),
    ("FEE", "the fee amount shows to a reader without finance view",
     patch_view("assay_dispute_rows", "WHEN has_permission('module.finance.view'::text) THEN fe.amount_base", "WHEN true THEN fe.amount_base")),
    ("FEE", "the counterparty's share under 'equal' is the whole fee",
     patch_view("assay_dispute_rows", "WHEN 'equal'::text THEN (50)::numeric", "WHEN 'equal'::text THEN (100)::numeric")),
    ("FEE", "an unapproved supplier can be paid",
     patch_fn(PAYEE, "IF v_status NOT IN ('approved', 'active') THEN", "IF false THEN")),
    # ── DISAGREE ──
    ("DISAGREE", "the sell-side prompt never fires",
     patch_view("assay_disagreements_all", "(x.max_diff_pct > ((t.settlement_terms ->> 'splitting_limit_pct'::text))::numeric)", "(x.max_diff_pct > (1000)::numeric)")),
    ("DISAGREE", "an open dispute does not silence the prompt",
     patch_view("assay_disagreements_all", "(d.status = ANY (ARRAY['open'::text, 'resolved'::text]))", "(d.status = 'none'::text)")),
    # ── V14 ──
    ("V14", "V14 stays listed after the rule is given",
     patch_view("pending_values", "(cst.arbitration_fee_rule IS NOT NULL)", "false")),
    ("V14", "the fee rule column takes any word",
     "ALTER TABLE public.contract_settlement_terms DROP CONSTRAINT contract_settlement_terms_arbitration_fee_rule_check;\n"),
    # ── F3 ──
    ("F3", "every reason layer is gone but the CHECK (the refusal speaks in the CHECK's words)",
     patch_fn(REV, "IF NULLIF(btrim(COALESCE(p_memo, '')), '') IS NULL THEN", "IF false THEN")
     + patch_fn(REV_INT, "    IF v_reason IS NULL THEN\n        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', v_orig.code",
                "    IF false THEN\n        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', v_orig.code")
     + patch_fn(GUARD, "IF NEW.reversal_reason IS NULL OR btrim(NEW.reversal_reason) = '' OR NEW.reversed_at IS NULL THEN", "IF false THEN")),
    ("F3", "the reason is not stored on the reversed expense",
     patch_fn(REV_INT, "reversal_reason = v_reason, reversed_at = now(), reversed_by = auth.uid()",
              "reversal_reason = 'reversed', reversed_at = now(), reversed_by = auth.uid()")),
    ("F3", "the mirror's notes carry the human text again",
     patch_fn(REV_INT, "'REVERSAL: ' || v_orig.code,", "'REVERSAL: ' || v_orig.code || ' — ' || v_reason,")),
    ("F3", "the row guard lets posted → reversed through without a reason (the CHECK answers instead)",
     patch_fn(GUARD, "IF NEW.reversal_reason IS NULL OR btrim(NEW.reversal_reason) = '' OR NEW.reversed_at IS NULL THEN", "IF false THEN")),
    ("F3", "the internal path accepts a blank reason (the guard answers instead)",
     patch_fn(REV_INT, "    IF v_reason IS NULL THEN\n        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', v_orig.code",
              "    IF false THEN\n        RAISE EXCEPTION 'EXPENSE_REVERSAL_REASON_REQUIRED|%', v_orig.code")
     + patch_fn(GUARD, "IF NEW.reversal_reason IS NULL OR btrim(NEW.reversal_reason) = '' OR NEW.reversed_at IS NULL THEN", "IF false THEN")),
    ("F3", "a posted expense can carry a reversal reason (CHECK gone)",
     "ALTER TABLE public.expenses DROP CONSTRAINT expenses_reversal_shape;\n"),
]

OTHER = [
    ("40", None, "FIXTURE 40F", "preview no longer sees the open dispute",
     patch_fn(PREVIEW, DISPUTE_SELECT_APPLY, DISPUTE_SELECT_APPLY.replace("d.status = 'open'", "d.status = 'none'"))),
    ("118", None, "FIXTURE 118F5", "applying any party's result supersedes ours (the old rule)",
     patch_fn(APPLY, "      AND result_party = v_assay.result_party\n", "")),
    ("149", None, "FIXTURE 149J", "settlement no longer sees the open dispute",
     patch_fn(SETTLE, "WHERE d.output_batch_id = p_output_batch_id AND d.status = 'open';", "WHERE d.output_batch_id = p_output_batch_id AND d.status = 'none';")),
    ("220", None, "FIXTURE 220I6", "a waiting assay request posts despite the dispute",
     patch_fn(POST, "    IF v_r.source = 'assay' THEN\n        SELECT d.id INTO v_disp", "    IF false THEN\n        SELECT d.id INTO v_disp")),
    ("258", None, "FIXTURE 258 F3", "reverse_expense no longer checks the reason first",
     patch_fn(REV, "IF NULLIF(btrim(COALESCE(p_memo, '')), '') IS NULL THEN", "IF false THEN")),
    ("258", None, "FIXTURE 258 F3", "the electricity reversal prefixes the reason again",
     patch_fn(REV_ELEC, "v_x := reverse_expense_internal(v_a.expense_id, v_reason);",
              "v_x := reverse_expense_internal(v_a.expense_id, 'Electricity bill reversed: ' || v_reason);")),
    ("100", "every-document", "FIXTURE 100/1", "the SMP row is gone from the registry",
     "DELETE FROM document_types WHERE key = 'sample';\n"),
    ("111", None, "FIXTURE 111F1", "a reminder arm is renamed",
     patch_view("operations_now", "'sample_retention_due'::text AS item_type", "'sample_retention_overdue'::text AS item_type")),
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
clean = {("260", None): "FIXTURE 260 全部通过", ("261", None): "FIXTURE 261 全部通过", ("258", None): "FIXTURE 258 全部通过",
         ("100", "every-document"): "FIXTURE 100 全部通过"}
for (num, stem), needle in clean.items():
    rc, out = run(body_of(num, stem), "")
    if rc != 0 or needle not in out:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: {needle}")
for num in ("40", "118", "149", "220", "111"):
    rc, out = run(body_of(num), "")
    if rc != 0:
        print(f"✗ the clean fixture {num} is not green:\n" + out[-1500:])
        sys.exit(1)
    print(f"✓ clean: fixture {num} (exit 0)")

for num, cases, all_arms in (("260", CASES_260, {"SMP", "CUST", "RET", "ASSAY", "EARLY", "CODES", "READ", "LOG", "PV"}),
                             ("261", CASES_261, {"OPEN", "HOLD", "RESOLVE", "D4", "SELL", "FEE", "DISAGREE", "V14", "F3"})):
    B = body_of(num)
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

for num, stem, needle, name, inj in OTHER:
    rc, out = run(body_of(num, stem), inj)
    first, last_arm = where_red(out, num)
    if rc != 0 and "INJECTION_DID_NOT_APPLY" not in out and needle in first:
        print(f"✓ fixture {num} · {name}: {first[first.index('ERROR'):][:200]}")
    else:
        print(f"✗ fixture {num} · {name}: expected '{needle}', got [{last_arm}] {first[:300]}")
        bad += 1

print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_260)} injections on 260 + {len(CASES_261)} on 261 + {len(OTHER)} on 40 / 118 / 149 / 220 / 258 / 100 / 111, {bad} wrong)")
sys.exit(1 if bad else 0)
