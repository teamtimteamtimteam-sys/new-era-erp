#!/usr/bin/env python3
"""MES-8a:fixture 269 与 270 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。

做法照 db/scripts/2026-10-16-mes7b2-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
视图重建时带回它自己的 reloptions(不假设 security_invoker = off)。
【红在哪一臂】两支 fixture 每进一臂先打一行 NOTICE "fixture 26x · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着
  "FIXTURE 26x <臂>",或者它发生时最后打出的那一臂就是 <臂>。
措辞臂 ㉞ 的两格(TRAIL_WORDING_FAULT wording-drift-mes8a / wording-part-mes8a)是 scripts/check-trail-wording.mjs 的;PDF 路由的三格
  (sst-render-live / sst-no-409 / sst-orphan-left)是 scripts/check-pdf-routes.mjs 的 —— 都不碰库,不在这里。
【"不发生"的断言怎么注入】冻结("签发之后供应商改名,那一份一个字不动")、"改设定不改写过去的评审"、"抽样级别不加化验"三条说的是一件
  【不发生】的事,所以那几格是往库里【加】一支会让它发生的触发器(并摘掉挡着它的那一支只追加守卫)。
【没有格的一处,照直说】supplier_latest_reviews 的"没被取代"那一句在今天的写入口下【不可能单独咬人】:更正永远比被更正的那一次新
  (seq 更大),于是"按 seq 最新的那一次"从来不会是一次被取代的评审。那一句留着是为了将来一个直写的入口,不是为了这里的哪一臂。
跑法:python3 db/scripts/2026-10-16-mes8a-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
退出码:0 = 两支 fixture 干净跑绿、每一格都红在它的那一臂、每一臂都至少红过一次、跑完库与跑前逐字相同;1 = 否则。
"""
import pathlib
import re
import subprocess
import sys

sys.path.insert(0, "db")
from injection_probe import Pristine  # noqa: E402

DSN = sys.argv[1]
if "supabase" in DSN or "pooler" in DSN:
    sys.exit("refusing a live DSN — run against a throwaway rebuild")
ROOT = pathlib.Path(".")


def body_of(num):
    src = next(ROOT.glob(f"db/fixtures/{num}-*.sql")).read_text()
    assert src.count("\nBEGIN;\n") == 1 and src.rstrip().endswith("ROLLBACK;"), f"fixture {num} shape changed"
    return src.split("\nBEGIN;\n", 1)[1].rstrip()[: -len("ROLLBACK;")]


MEA = "public.supplier_scorecard_measures(uuid, date, date)"
GRD = "public.supplier_scorecard_grade(jsonb, jsonb, jsonb)"
RSR = "public.record_supplier_review(uuid, date, date, text, uuid, text)"
SSS = "public.set_supplier_score_settings(jsonb, jsonb, integer, jsonb)"
ADI = "public.supplier_grade_advice_internal(uuid, jsonb, numeric)"
ADV = "public.supplier_grade_advice(uuid, jsonb, numeric)"
RCI = "public.record_cod_issue(uuid, text, text)"
SSD = "public.supplier_statement_data(uuid, date, date)"
ISS = "public.issue_supplier_statement(uuid, date, date, text)"
NSC = "public.next_supplier_statement_code(date)"
RSI = "public.record_supplier_statement_issue(uuid, text, text)"
GSW = "public.guard_supplier_statement_write()"
CPO_NAME = "create_purchase_order"


def patch_fn(sig, old, new):
    o, n = old.replace("'", "''"), new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; BEGIN
    d := pg_get_functiondef('{sig}'::regprocedure);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{sig}'; END IF;
    EXECUTE d2;
END $inj$;
"""


def patch_fn_by_name(name, old, new):
    """create_purchase_order 的签名很长,按名字取(只有一支)。"""
    o, n = old.replace("'", "''"), new.replace("'", "''")
    return f"""DO $inj$ DECLARE d text; d2 text; v_oid oid; BEGIN
    SELECT p.oid INTO STRICT v_oid FROM pg_proc p JOIN pg_namespace s ON s.oid = p.pronamespace WHERE s.nspname = 'public' AND p.proname = '{name}';
    d := pg_get_functiondef(v_oid);
    d2 := replace(d, '{o}', '{n}');
    IF d2 = d THEN RAISE EXCEPTION 'INJECTION_DID_NOT_APPLY|{name}'; END IF;
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


# 改设定时把过去的评审跟着改(摘掉评审的只追加守卫)
SETTINGS_REWRITE_PAST = """ALTER TABLE public.supplier_scorecard_reviews DISABLE TRIGGER trg_supplier_scorecard_reviews_immutable;
CREATE FUNCTION public.f269_inj_follow() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
    UPDATE public.supplier_scorecard_reviews SET weights = NEW.weights, grade_lines = NEW.grade_lines WHERE grade IS NOT NULL;
    RETURN NEW;
END $f$;
CREATE TRIGGER f269_inj_follow AFTER UPDATE ON public.supplier_score_settings FOR EACH ROW EXECUTE FUNCTION public.f269_inj_follow();
"""

# 记一次评审时顺手给物料加一项必须的化验(抽样级别"加了化验")
SAMPLING_ADDS_ASSAY = """CREATE FUNCTION public.f269_inj_assay() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
    INSERT INTO public.material_required_metals (material_id, metal)
    SELECT m.id, 'ni' FROM public.materials m WHERE m.code = 'FX269-M' ON CONFLICT DO NOTHING;
    RETURN NEW;
END $f$;
CREATE TRIGGER f269_inj_assay AFTER INSERT ON public.supplier_scorecard_reviews FOR EACH ROW EXECUTE FUNCTION public.f269_inj_assay();
"""

# 一个持 action.supplier_review 而不持 module.suppliers.view 的角色
ACTION_WITHOUT_VIEW = """DO $inj$ DECLARE r uuid; BEGIN
    INSERT INTO public.roles (code, name_en, name_zh, is_active) VALUES ('f269-inj-noview', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO public.role_permissions (role_id, permission_code) VALUES (r, 'action.supplier_review');
END $inj$;
"""

# 供应商改名时把签发了的对账单跟着改(摘掉对账单的只许取代守卫)—— "PDF 读活数据"在库里的那张脸
STATEMENT_FOLLOWS_SUPPLIER = """ALTER TABLE public.supplier_statements DISABLE TRIGGER trg_supplier_statements_write;
CREATE FUNCTION public.f270_inj_follow() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
    UPDATE public.supplier_statements SET supplier_name = NEW.legal_name WHERE supplier_id = NEW.id;
    RETURN NEW;
END $f$;
CREATE TRIGGER f270_inj_follow AFTER UPDATE ON public.suppliers FOR EACH ROW EXECUTE FUNCTION public.f270_inj_follow();
"""

CASES_269 = [
    ("REG", "a new table not change-logged", "DROP TRIGGER zzz_change_log ON public.supplier_statements;"),
    ("REG", "the base view readable by staff", "GRANT SELECT ON public.grn_discrepancies_all TO authenticated;"),
    ("REG", "a view carries a write grant (F16)", "GRANT UPDATE ON public.supplier_scorecard_rows TO authenticated;"),
    ("MEAS", "short judged on an open order", patch_fn(MEA, "FILTER (WHERE g.po_status IN ('closed', 'cancelled'))", "FILTER (WHERE true)")),
    ("MEAS", "NCRs counted outside the window",
     patch_fn(MEA, "AND (n.opened_at AT TIME ZONE 'Asia/Singapore')::date BETWEEN p_from AND p_to", "")),
    ("MEAS", "withdrawn dispute scored", patch_fn(MEA, "count(*) FILTER (WHERE d.status <> 'withdrawn')", "count(*)")),
    ("MEAS", "certificate lapse ignores the end date",
     patch_fn(MEA, "AND (c2.valid_until IS NULL OR d.day::date <= c2.valid_until)", "")),
    ("NOTCMP", "short not compared reads 0", patch_fn(MEA, "'count', CASE WHEN v_short_cmp > 0 THEN v_short END", "'count', v_short")),
    ("NOTCMP", "no certificate reads 0 lapse days",
     patch_fn(MEA, "'count', CASE WHEN v_cert_types > 0 THEN v_cert_days END", "'count', v_cert_days")),
    ("BREACH", "the breach is not shown", patch_fn(MEA, "gb.assay_date BETWEEN p_from AND p_to", "false")),
    ("BREACH", "a weight on grade breaches accepted", patch_fn(SSS, "RAISE EXCEPTION 'SCORE_WEIGHT_UNKNOWN|%', v_k;", "NULL;")),
    ("WINDOW", "a window in the future accepted", patch_fn(MEA, "IF p_to > v_today THEN", "IF false THEN")),
    ("WINDOW", "an empty window accepted", patch_fn(MEA, "IF p_from IS NULL OR p_to IS NULL THEN", "IF false THEN")),
    ("GATE", "reviews recorded on the view code",
     patch_fn(RSR, "require_permission('action.supplier_review')", "require_permission('module.suppliers.view')")),
    ("GATE", "grade advice without the view code", patch_fn(ADV, "PERFORM require_permission('module.suppliers.view');", "")),
    ("GATE", "a session may insert a review",
     "CREATE POLICY f269_inj_ins ON public.supplier_scorecard_reviews FOR INSERT TO authenticated WITH CHECK (true);\n"
     "GRANT INSERT ON public.supplier_scorecard_reviews TO authenticated;"),
    ("GATE", "the review code held without its view", ACTION_WITHOUT_VIEW),
    ("NOTGR", "V23 unset still grades",
     patch_fn(GRD, "'score', NULL, 'grade', NULL, 'not_graded_reason', 'V23_NOT_SET'", "'score', 0, 'grade', 'A', 'not_graded_reason', NULL")),
    ("NOTGR", "an ungraded review reads as graded", patch_fn(ADI, "'graded',             v_r.grade IS NOT NULL", "'graded',             true")),
    ("V23", "a missing weight accepted", patch_fn(SSS, "RAISE EXCEPTION 'SCORE_WEIGHT_MISSING|%', v_k;", "NULL;")),
    ("V23", "a last line with a ceiling accepted", patch_fn(SSS, "RAISE EXCEPTION 'SCORE_GRADE_LAST_LINE_OPEN';", "NULL;")),
    ("V23", "V23 cleared by the weights alone",
     patch_view("pending_values", "((ss.weights IS NULL) OR (ss.grade_lines IS NULL) OR (ss.review_window_days IS NULL))",
                "((ss.weights IS NULL) OR (ss.grade_lines IS NULL))")),
    ("V23", "V23 / V24 shown without the view code",
     patch_view("pending_values", "'module.suppliers.view'::text AS permission,\n            NULL::uuid AS item_id,\n            'supplier_score_settings'::text",
                "'module.finance.view'::text AS permission,\n            NULL::uuid AS item_id,\n            'supplier_score_settings'::text")),
    ("V24", "V24 asks only for the cap",
     patch_view("pending_values", " OR (((ss.grade_caps -> (gl.value ->> 'grade'::text)) ->> 'sampling_level'::text) IS NULL)", "")),
    ("GRADED", "the open line always wins",
     patch_fn(GRD, "ORDER BY (l ->> 'max_score') IS NULL, (l ->> 'max_score')::numeric, i", "ORDER BY (l ->> 'max_score') IS NULL DESC, i")),
    ("GRADED", "the V24 caps not copied", patch_fn(RSR, "NULLIF(v_p -> 'grade_caps', 'null'::jsonb)", "NULL")),
    ("GRADED", "changing the settings rewrites a past review", SETTINGS_REWRITE_PAST),
    ("CORR", "a correction without a reason", patch_fn(RSR, "RAISE EXCEPTION 'SUPPLIER_REVIEW_CORRECTION_REASON_REQUIRED';", "NULL;")),
    ("CORR", "a correction of another supplier's review", patch_fn(RSR, "RAISE EXCEPTION 'SUPPLIER_REVIEW_OTHER_SUPPLIER';", "NULL;")),
    ("CORR", "a review corrected twice",
     patch_fn(RSR, "RAISE EXCEPTION 'SUPPLIER_REVIEW_ALREADY_CORRECTED|%', p_corrects_review_id;", "NULL;")),
    ("CORR", "a review may be edited",
     "ALTER TABLE public.supplier_scorecard_reviews DISABLE TRIGGER trg_supplier_scorecard_reviews_immutable;"),
    ("LATEST", "a correction outranks a later review",
     patch_view("supplier_latest_reviews", "ORDER BY supplier_id, seq DESC", "ORDER BY supplier_id, (corrects_review_id IS NOT NULL) DESC, seq DESC")),
    ("PO", "creating the order drops the warning",
     patch_fn_by_name(CPO_NAME, "supplier_grade_advice_internal(p_supplier_id, p_payment_terms, v_total) -> 'warnings'", "'[]'::jsonb")),
    ("PO", "the warning refuses the order",
     patch_fn(ADI, "v_warn := jsonb_build_array(jsonb_build_object(", "RAISE EXCEPTION 'PREPAYMENT_ABOVE_GRADE_CAP'; v_warn := jsonb_build_array(jsonb_build_object(")),
    ("PO", "a fixed amount read as a percentage",
     patch_fn(ADI, "v_pct := v_pct + v_fixed / p_estimated_total_ccy * 100;", "v_pct := v_pct + v_fixed;")),
    ("PO", "no estimated total is divided by",
     patch_fn(ADI, "IF p_estimated_total_ccy IS NULL OR p_estimated_total_ccy <= 0 THEN", "IF p_estimated_total_ccy IS NULL THEN")),
    ("SAMPLE", "the sampling level not given", patch_fn(ADI, "v_level := v_r.grade_caps -> v_r.grade ->> 'sampling_level';", "v_level := NULL;")),
    ("SAMPLE", "a review adds a required assay", SAMPLING_ADDS_ASSAY),
    ("DUE", "the arm speaks with no window",
     patch_view("operations_now", "JOIN supplier_score_settings ss ON ((ss.id AND (ss.review_window_days IS NOT NULL))))",
                "JOIN supplier_score_settings ss ON (ss.id))")),
    ("DUE", "approved suppliers not reminded",
     patch_view("operations_now", "(s.status = ANY (ARRAY['approved'::supplier_status, 'active'::supplier_status])) AND ((lr.recorded_at IS NULL)",
                "(s.status = ANY (ARRAY['active'::supplier_status])) AND ((lr.recorded_at IS NULL)")),
    ("DUE", "the reminder shown to every viewer",
     patch_view("operations_now", "'action.supplier_review'::text AS permission", "'module.suppliers.view'::text AS permission")),
    ("F17", "a path outside the certificate's folder", patch_fn(RCI, "p_file_path NOT LIKE v_cod.id::text || '/%'", "false")),
    ("F17", "the digest stored as given", patch_fn(RCI, "VALUES (p_cod_id, p_file_path, lower(p_sha256), auth.uid())", "VALUES (p_cod_id, p_file_path, p_sha256, auth.uid())")
     + "ALTER TABLE public.cod_issues DROP CONSTRAINT IF EXISTS cod_issues_sha256_check;\n"),
    ("F17", "a second set of bytes not refused by name",
     patch_fn(RCI, "RAISE EXCEPTION 'COD_BYTES_ALREADY_RECORDED|%', COALESCE(v_cod.code, v_cod.id::text);", "NULL;")),
]
ALL_269 = {a for a, _, _ in CASES_269}

CASES_270 = [
    ("GATE", "prices restricted not refused", patch_fn(SSD, "RAISE EXCEPTION 'SUPPLIER_STATEMENT_PRICES_RESTRICTED';", "NULL;")),
    ("GATE", "receipts restricted not refused", patch_fn(SSD, "RAISE EXCEPTION 'SUPPLIER_STATEMENT_RECEIPTS_RESTRICTED';", "NULL;")),
    ("GATE", "issued on the view code", patch_fn(ISS, "require_permission('module.finance.edit')", "require_permission('module.finance.view')")),
    ("GATE", "a session may insert a statement",
     "CREATE POLICY f270_inj_ins ON public.supplier_statements FOR INSERT TO authenticated WITH CHECK (true);\n"
     "GRANT INSERT ON public.supplier_statements TO authenticated;"),
    ("PERIOD", "a period in the future accepted", patch_fn(SSD, "IF p_to > CURRENT_DATE THEN", "IF false THEN")),
    ("PERIOD", "an inverted period accepted", patch_fn(SSD, "IF p_to < p_from THEN", "IF false THEN")),
    ("LINES", "an employee claim attributed to the supplier",
     patch_fn(SSD, "(SELECT e.code FROM expenses e WHERE e.id = l.sid AND e.supplier_id = p_supplier_id)",
              "(SELECT e.code FROM expenses e WHERE e.id = l.sid)")),
    ("LINES", "the provisional flag lost", patch_fn(SSD, "b.pricing_status = 'provisional'", "false")),
    ("LINES", "every receipt listed as unpriced", patch_fn(SSD, "AND inbound_unit_price_asof(b.id, p_to) IS NULL", "")),
    ("LINES", "the opening balance dropped",
     patch_fn(SSD, "FILTER (WHERE (x ->> 'date')::date < p_from), 2), 0)", "FILTER (WHERE (x ->> 'date')::date < p_from - 10000), 2), 0)")),
    ("TIE", "the payment on account left out of the tie",
     patch_fn(SSD, "v_diff := round(v_list - v_onacc - v_res - v_closing, 2);", "v_diff := round(v_list - v_res - v_closing, 2);")),
    ("NOTIE", "ties compares nothing", patch_fn(SSD, "'ties',             (v_diff = 0)", "'ties',             true")),
    ("NOTIE", "a statement issued without tying", patch_fn(ISS, "IF (v_d ->> 'ties')::boolean IS NOT TRUE THEN", "IF false THEN")),
    ("ISSUE", "the number truncated to its digits", patch_fn(NSC, "LPAD(v_n, GREATEST(4, length(v_n)), '0')", "v_n")),
    ("ISSUE", "the letterhead not frozen from the profile", patch_fn(ISS, "'legal_name', cp.legal_name", "'legal_name', 'Someone Else'")),
    ("ISSUE", "an issued statement follows the supplier's rename", STATEMENT_FOLLOWS_SUPPLIER),
    ("SUPER", "a supersede without a reason",
     patch_fn(ISS, "IF v_prev IS NOT NULL AND v_reason IS NULL THEN", "IF false THEN")),
    ("SUPER", "the old statement not marked",
     patch_fn(ISS, "SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason\n         WHERE id = v_prev;",
              "SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason\n         WHERE false;")),
    ("SUPER", "a superseded reason may be rewritten", patch_fn(GSW, "AND OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL", "AND NEW.superseded_at IS NOT NULL")),
    ("SUPER", "an issued statement may be edited", "ALTER TABLE public.supplier_statements DISABLE TRIGGER trg_supplier_statements_write;"),
    ("NUM", "numbers compared as text", patch_fn(NSC, "MAX(split_part(code, '-', 3)::integer)", "MAX(split_part(code, '-', 3))::integer")),
    ("NUM", "the width capped at four", patch_fn(NSC, "LPAD(v_n, GREATEST(4, length(v_n)), '0')", "LPAD(v_n, 4, '0')")),
    ("PDF", "bytes recorded on the view code", patch_fn(RSI, "require_permission('module.finance.edit')", "require_permission('module.finance.view')")),
    ("PDF", "a path outside the statement's folder", patch_fn(RSI, "p_file_path NOT LIKE v_s.id::text || '/%'", "false")),
    ("PDF", "a superseded statement re-issued", patch_fn(RSI, "IF v_s.superseded_at IS NOT NULL THEN", "IF false THEN")),
    ("PDF", "the same bytes recorded twice", patch_fn(RSI, "SELECT version INTO v_had FROM supplier_statement_issues WHERE statement_id = p_statement_id AND sha256 = v_sha;",
                                                      "SELECT version INTO v_had FROM supplier_statement_issues WHERE false;")
     + "ALTER TABLE public.supplier_statement_issues DROP CONSTRAINT supplier_statement_issues_statement_id_sha256_key;\n"),
    ("PDF", "the digest not lower-cased",
     patch_fn(RSI, "v_sha  text := lower(btrim(COALESCE(p_sha256, '')));", "v_sha  text := btrim(COALESCE(p_sha256, ''));")
     + patch_fn(RSI, "IF v_sha !~ '^[0-9a-f]{64}$' THEN", "IF v_sha !~* '^[0-9a-f]{64}$' THEN")
     + "ALTER TABLE public.supplier_statement_issues DROP CONSTRAINT IF EXISTS supplier_statement_issues_sha256_check;\n"),
    ("PDF", "an issue row may be edited",
     "ALTER TABLE public.supplier_statement_issues DISABLE TRIGGER trg_supplier_statement_issues_append_only;"),
]
ALL_270 = {a for a, _, _ in CASES_270}


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


def sweep(num, cases, all_arms):
    bad = 0
    B = body_of(num)
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


TOUCHED = ["public.supplier_scorecard_reviews", "public.supplier_statements", "public.supplier_statement_issues", "public.cod_issues",
           "public.grn_discrepancies_all", "public.supplier_scorecard_rows", "public.pending_values", "public.operations_now",
           "public.supplier_latest_reviews", MEA, GRD, RSR, SSS, ADI, ADV, RCI, SSD, ISS, NSC, RSI, GSW]
P = Pristine(DSN, TOUCHED).capture()
bad = sweep("269", CASES_269, ALL_269)
bad += sweep("270", CASES_270, ALL_270)
P.assert_clean("after both sweeps")
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_269)} injections on 269 + {len(CASES_270)} on 270, {bad} wrong)")
sys.exit(1 if bad else 0)
