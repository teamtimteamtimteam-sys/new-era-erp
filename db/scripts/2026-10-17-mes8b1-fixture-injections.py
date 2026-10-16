#!/usr/bin/env python3
"""MES-8b-1:fixture 271 与 272 的故障注入 —— 每一格注入一处缺陷,那支 fixture 必须在【它点名的那一臂】红。

做法照 db/scripts/2026-10-16-mes8a-fixture-injections.py:每一格是一段 SQL,插在 fixture 自己的 BEGIN 之后;注入随 ROLLBACK 消失。
函数与视图的注入用 pg_get_functiondef / pg_get_viewdef + replace + EXECUTE,并且【先断言替换真的发生了】(INJECTION_DID_NOT_APPLY)。
视图重建时带回它自己的 reloptions(不假设 security_invoker = off)。
【红在哪一臂】两支 fixture 每进一臂先打一行 NOTICE "fixture 27x · <臂>";一格注入算咬对了地方,当且仅当第一条 ERROR 写着
  "FIXTURE 27x <臂>",或者它发生时最后打出的那一臂就是 <臂>。
措辞臂 ㉟ 的两格(TRAIL_WORDING_FAULT wording-drift-mes8b1 / wording-part-mes8b1)是 scripts/check-trail-wording.mjs 的;PDF 路由的三格
  (cpk-render-live / cpk-no-409 / cpk-orphan-left)是 scripts/check-pdf-routes.mjs 的 —— 都不碰库,不在这里。
【"不发生"的断言怎么注入】"冻下来的包不随活数据动"、"之后给 V26 不改写冻下来的包"、"一条没过账的结算不进收入"说的是一件【不发生】的事,
  所以那几格是往库里【加】一支会让它发生的触发器或读法(并摘掉挡着它的那一支守卫)。
【没有格的几处,照直说】
  · freeze_compliance_pack 的 COMPLIANCE_PACK_PERIOD_REQUIRED:摘掉它,compliance_pack_data(NULL) 仍然以同一个码拒 —— 两道闸里的外层那一道
    在今天不可能单独咬人(纵深防御,不是一臂)。
  · V26 那一支的"格式或频率任一为空":set_compliance_settings 的成对检查让"只给一半"写不进去,于是 OR 换成只看格式在今天的写入口下不可能单独咬人。
  · inventory_metal_exposure 的新加坡日期:fixture 拿同一个表达式比,换成 UTC 只在每天八个小时里不同 —— 一格时红时绿的注入不是一格注入。
跑法:python3 db/scripts/2026-10-17-mes8b1-fixture-injections.py "<一个已经从镜像重建好的库的 DSN>"(绝不对着线上)
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


MAR = "public.inbound_batch_margin(uuid)"
EXP = "public.inventory_metal_exposure()"
CPD = "public.compliance_pack_data(date)"
FRZ = "public.freeze_compliance_pack(date, text, text)"
RCI = "public.record_compliance_pack_issue(uuid, text, text)"
SCS = "public.set_compliance_settings(text, text, text, text)"
CMS = "public.compliance_pack_month_status(date)"
GPW = "public.guard_compliance_pack_write()"


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


# 收入把卖方结算(没过账)也加进来
REVENUE_READS_SETTLEMENTS = patch_fn(
    MAR, "SELECT sr.output_batch_id, sum(sr.quantity) AS qty, sum(sr.amount_base) AS rev",
    "SELECT sr.output_batch_id, sum(sr.quantity) AS qty, sum(sr.amount_base) + COALESCE((SELECT sum(ss.amount_usd) FROM sales_settlements ss "
    "WHERE ss.output_batch_id = sr.output_batch_id), 0) AS rev")

# 一个持 action.compliance_pack 而不持 module.compliance.view 的角色
ACTION_WITHOUT_VIEW = """DO $inj$ DECLARE r uuid; BEGIN
    INSERT INTO public.roles (code, name_en, name_zh, is_active) VALUES ('f272-inj-noview', 'f', 'f', true) RETURNING id INTO r;
    INSERT INTO public.role_permissions (role_id, permission_code) VALUES (r, 'action.compliance_pack');
END $inj$;
"""

# 之后给 V26 时把冻下来的包跟着改 —— 守卫只给这一支触发器开一道缝(整支摘掉会让 NUM 那几句"改对谁都按名拒"先红,红错地方)
SETTINGS_REWRITE_PACK = patch_fn(GPW, "BEGIN\n    IF TG_OP = 'UPDATE'",
                                 "BEGIN\n    IF current_setting('f272.inj', true) = 'on' THEN RETURN NEW; END IF;\n    IF TG_OP = 'UPDATE'") + """
CREATE FUNCTION public.f272_inj_follow() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
    PERFORM set_config('f272.inj', 'on', true);
    UPDATE public.compliance_packs SET payload = jsonb_set(payload, '{nea_return,state}', '"set"');
    PERFORM set_config('f272.inj', '', true);
    RETURN NEW;
END $f$;
CREATE TRIGGER f272_inj_follow AFTER UPDATE ON public.compliance_settings FOR EACH ROW EXECUTE FUNCTION public.f272_inj_follow();
"""

# 记一件事故时把冻下来的包跟着改 —— "冻下来的包读活数据"在库里的那张脸
PACK_FOLLOWS_INCIDENTS = """ALTER TABLE public.compliance_packs DISABLE TRIGGER trg_compliance_packs_write;
CREATE FUNCTION public.f272_inj_live() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER AS $f$
BEGIN
    UPDATE public.compliance_packs SET payload = payload || jsonb_build_object('incidents', (payload -> 'incidents') || jsonb_build_array(jsonb_build_object('code', NEW.code)));
    RETURN NEW;
END $f$;
CREATE TRIGGER f272_inj_live AFTER INSERT ON public.incidents FOR EACH ROW EXECUTE FUNCTION public.f272_inj_live();
"""

CASES_271 = [
    ("GATE", "the margin without the price code", patch_fn(MAR, "PERFORM require_permission('data.view_prices');", "")),
    ("GATE", "the margin without either module code",
     patch_fn(MAR, "IF NOT (has_permission('module.finance.view') OR has_permission('module.processing.view')) THEN", "IF false THEN")),
    ("GATE", "the margin needs both modules (AND, not OR)",
     patch_fn(MAR, "has_permission('module.finance.view') OR has_permission('module.processing.view')",
              "has_permission('module.finance.view') AND has_permission('module.processing.view')")),
    ("GATE", "the exposure without the price code", patch_fn(EXP, "PERFORM require_permission('data.view_prices');", "")),
    ("GATE", "the exposure without either module code",
     patch_fn(EXP, "IF NOT (has_permission('module.finance.view') OR has_permission('module.processing.view')) THEN", "IF false THEN")),
    ("GATE", "a missing batch reads as nothing",
     patch_fn(MAR, "RAISE EXCEPTION 'INBOUND_BATCH_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');", "RETURN NULL;")),
    ("PATH", "an output's sales counted whole, not by share",
     patch_fn(MAR, "'qty_sold', round(l.qty_sold * l.share_num / l.share_den, 3)", "'qty_sold', round(l.qty_sold, 3)")),
    ("PATH", "only the first stage followed",
     patch_fn(MAR, "WHERE t.node_type = 'run_output'",
              "WHERE t.node_type = 'run_output' AND t.depth = (SELECT min(x.depth) FROM t x WHERE x.node_type = 'run_output')")),
    ("PATH", "the share rounded to two places",
     patch_fn(MAR, "'share', round(l.share_num / l.share_den, 6)", "'share', round(l.share_num / l.share_den, 2)")),
    ("PATH", "unsold stock deducted from the margin",
     patch_fn(MAR, "THEN round(v_rev - v_cost, 2) END", "THEN round(v_rev - v_cost - COALESCE(v_onval, 0), 2) END")),
    ("MARGIN", "cost of sold reads the stock at cost",
     patch_fn(MAR, "'cost_of_sold_base', CASE WHEN v_ok THEN round(COALESCE(v_cost, 0), 2) END",
              "'cost_of_sold_base', CASE WHEN v_ok THEN round(COALESCE(v_onval, 0), 2) END")),
    ("MARGIN", "revenue reported net of cost",
     patch_fn(MAR, "'revenue_base', CASE WHEN v_ok THEN round(COALESCE(v_rev, 0), 2) END",
              "'revenue_base', CASE WHEN v_ok THEN round(COALESCE(v_rev, 0) - COALESCE(v_cost, 0), 2) END")),
    ("MARGIN", "the state never says computed", patch_fn(MAR, "ELSE 'computed' END", "ELSE 'sold' END")),
    ("UNSOLD", "the batch's own stock left out",
     patch_fn(MAR, "round(COALESCE(v_onval, 0) + v_root_on * v_landed, 2)", "round(COALESCE(v_onval, 0), 2)")),
    ("UNSOLD", "downstream stock counted whole",
     patch_fn(MAR, "COALESCE(sum(l.on_hand * l.share_num / l.share_den), 0),", "COALESCE(sum(l.on_hand), 0),")),
    ("REVENUE", "an unposted settlement counted as revenue", REVENUE_READS_SETTLEMENTS),
    ("REVENUE", "the revenue source misnamed",
     patch_fn(MAR, "'revenue_source', 'sales_records'", "'revenue_source', 'sales_settlements'")),
    ("NOCOMP", "an output with no unit cost computed",
     patch_fn(MAR, "FILTER (WHERE l.unit_cost_base IS NULL OR l.cost_incomplete)", "FILTER (WHERE l.cost_incomplete)")),
    ("NOCOMP", "an incomplete cost computed",
     patch_fn(MAR, "FILTER (WHERE l.unit_cost_base IS NULL OR l.cost_incomplete)", "FILTER (WHERE l.unit_cost_base IS NULL)")),
    ("NOCOMP", "an unpriced inbound batch computed", patch_fn(MAR, "IF NOT v_priced THEN", "IF false THEN")),
    ("NOCOMP", "not computable reads 0",
     patch_fn(MAR, "THEN round(v_rev - v_cost, 2) END", "THEN round(v_rev - v_cost, 2) ELSE 0 END")),
    ("NOSALE", "nothing sold reads computed", patch_fn(MAR, "WHEN NOT v_any_sold THEN 'nothing_sold'", "WHEN false THEN 'nothing_sold'")),
    ("NOSALE", "nothing sold reads a margin of 0",
     patch_fn(MAR, "CASE WHEN v_ok AND v_any_sold THEN round(v_rev - v_cost, 2) END",
              "CASE WHEN v_ok THEN round(COALESCE(v_rev, 0) - COALESCE(v_cost, 0), 2) END")),
    ("EXPO", "tomorrow's price counted", patch_fn(EXP, " AND p.price_date <= v_today) d ON true", ") d ON true")),
    ("EXPO", "penalty elements listed", patch_fn(EXP, "WHERE s.role = 'payable_metal'\n    ), per AS", "WHERE true\n    ), per AS")),
    ("EXPO", "an ambiguous price picked", patch_fn(EXP, "WHEN lt.n_prices > 1 THEN 'price_ambiguous'", "WHEN false THEN 'price_ambiguous'")),
    ("EXPO", "spare parts counted", patch_fn(EXP, " AND k.may_ever_be_processed", "")),
    ("EXPO", "a batch not in kg not listed", patch_fn(EXP, "FILTER (WHERE s.unit <> 'kg')", "FILTER (WHERE false)")),
    ("EXPO", "the not-measured list empty", patch_fn(EXP, "FILTER (WHERE s.unit = 'kg' AND NOT EXISTS", "FILTER (WHERE false AND NOT EXISTS")),
    ("EXPO", "an unpriced metal valued at 0",
     patch_fn(EXP, "'value_usd', CASE WHEN l.state = 'priced' THEN round(l.metal_kg / 1000 * l.price, 2) END",
              "'value_usd', COALESCE(round(l.metal_kg / 1000 * l.price, 2), 0)")),
    ("EXPO", "a price older than the content not flagged",
     patch_fn(EXP, "AND lt.price_date < p.content_on) AS price_older_than_content", "AND false) AS price_older_than_content")),
    ("EXPO", "complete despite the gaps", patch_fn(EXP, "'complete', COALESCE(v_complete, true) AND", "'complete', true OR")),
    ("LOG", "a new table not change-logged", "DROP TRIGGER zzz_change_log ON public.compliance_packs;"),
    ("LOG", "a reader that may write", "ALTER FUNCTION public.inventory_metal_exposure() VOLATILE;"),
]
ALL_271 = {a for a, _, _ in CASES_271}

CASES_272 = [
    ("REG", "a new table not change-logged", "DROP TRIGGER zzz_change_log ON public.compliance_pack_issues;"),
    ("REG", "V26 guessed in the bootstrap", "UPDATE public.compliance_settings SET nea_return_format = 'guess', nea_return_frequency = 'monthly';"),
    ("REG", "the document type points elsewhere", "UPDATE public.document_types SET route = '/safety' WHERE key = 'compliance_pack';"),
    ("REG", "the action code declares no view", "UPDATE public.permissions SET requires_view_any = NULL WHERE code = 'action.compliance_pack';"),
    ("REG", "the action code held without its view", ACTION_WITHOUT_VIEW),
    ("REG", "a view carries a write grant (F16)", "GRANT UPDATE ON public.pending_values TO authenticated;"),
    ("V2627", "V26 shown without the view code",
     patch_view("pending_values", "'module.compliance.view'::text AS permission,\n            NULL::uuid AS item_id,\n            'compliance_settings'::text AS item_code,\n            'NEA",
                "'module.safety.view'::text AS permission,\n            NULL::uuid AS item_id,\n            'compliance_settings'::text AS item_code,\n            'NEA")),
    ("V2627", "V27 never listed",
     patch_view("pending_values", "((cs.eu_efficiency_method IS NULL) OR (cs.eu_efficiency_targets IS NULL))", "false")),
    ("V2627", "V26 set on the view code",
     patch_fn(SCS, "PERFORM require_permission('action.compliance_pack');", "PERFORM require_permission('module.compliance.view');")),
    ("V2627", "half of V26 accepted", patch_fn(SCS, "RAISE EXCEPTION 'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V26';", "NULL;")),
    ("V2627", "half of V27 accepted", patch_fn(SCS, "RAISE EXCEPTION 'COMPLIANCE_SETTINGS_PAIR_INCOMPLETE|V27';", "NULL;")),
    ("V2627", "a blank frequency read as given",
     patch_fn(SCS, "v_q  text := NULLIF(btrim(COALESCE(p_nea_return_frequency, '')), '');", "v_q  text := p_nea_return_frequency;")),
    ("V2627", "V27 claims it computed", patch_fn(CPD, "'masses', v_masses, 'computed', false)", "'masses', v_masses, 'computed', true)")),
    ("V2627", "setting V26 later rewrites a frozen pack", SETTINGS_REWRITE_PACK),
    ("GATE", "the preview without the view code",
     patch_fn(CPD, "PERFORM require_permission('module.compliance.view');\n    IF p_month IS NULL THEN", "IF p_month IS NULL THEN")),
    ("GATE", "a pack frozen on the view code",
     patch_fn(FRZ, "PERFORM require_permission('action.compliance_pack');\n    PERFORM require_permission('module.compliance.view');",
              "PERFORM require_permission('module.compliance.view');")),
    ("GATE", "the month-end line open to everyone",
     patch_fn(CMS, "IF NOT (has_permission('module.finance.view') OR has_permission('module.compliance.view')) THEN", "IF false THEN")),
    ("GATE", "a session may insert a pack",
     "CREATE POLICY f272_inj_ins ON public.compliance_packs FOR INSERT TO authenticated WITH CHECK (true);\n"
     "GRANT INSERT ON public.compliance_packs TO authenticated;"),
    ("LOCK", "an open month frozen", patch_fn(FRZ, "IF v_locked IS NULL OR v_locked <= v_end THEN", "IF v_locked IS NULL THEN")),
    ("LOCK", "the month-end line calls an open month locked",
     patch_fn(CMS, "'locked', v_locked IS NOT NULL AND v_locked > v_end", "'locked', v_locked IS NOT NULL")),
    ("ARM", "the reminder shown to every viewer",
     patch_view("operations_now", "'action.compliance_pack'::text AS permission", "'module.compliance.view'::text AS permission")),
    ("ARM", "the first month left out",
     patch_view("operations_now", "date_trunc('month'::text, (fs.system_start_date)::timestamp without time zone)",
                "date_trunc('month'::text, ((fs.system_start_date + 31))::timestamp without time zone)")),
    ("ARM", "an open month reminded", patch_view("operations_now", "AND (((m.m + '1 mon'::interval))::date <= fs.locked_before)", "")),
    ("ARM", "a frozen month still reminded",
     patch_view("operations_now", "WHERE ((cp.period_month = (m.m)::date) AND (cp.superseded_at IS NULL))", "WHERE false")),
    ("SECT", "the frozen payload is not the preview",
     patch_fn(FRZ, "v_payload := compliance_pack_data(v_start);", "v_payload := compliance_pack_data(v_start) || '{\"frozen\": true}'::jsonb;")),
    ("SECT", "the plant-wide balance dropped",
     patch_fn(CPD, "INTO v_balance FROM processing_balance_monthly_all b WHERE b.month = v_start;",
              "INTO v_balance FROM processing_balance_monthly_all b WHERE b.month = v_start AND b.scope = 'operation';")),
    ("SECT", "the roll-forward of another month",
     patch_fn(CPD, "FROM stock_rollforward_monthly_all r WHERE r.month = v_start;",
              "FROM stock_rollforward_monthly_all r WHERE r.month = (v_start - interval '1 month')::date;")),
    ("SECT", "the licence in force two months earlier", patch_fn(CPD, "v_lic_id := storage_licence_in_force(v_end);", "v_lic_id := storage_licence_in_force(v_start - 60);")),
    ("SECT", "category stock in kg, not tonnes",
     patch_fn(CPD, "sum(quantity_in_tonnes(bal.qty, bal.unit)) AS tonnes", "sum(bal.qty) AS tonnes")),
    ("SECT", "above the ceiling never said", patch_fn(CPD, "WHEN COALESCE(cat.tonnes, 0) > l.limit_tonnes THEN 'above_ceiling'", "WHEN false THEN 'above_ceiling'")),
    ("SECT", "the NEA notification date lost",
     patch_fn(CPD, "'notified_on', (i.notified_at AT TIME ZONE 'Asia/Singapore')::date", "'notified_on', NULL::date")),
    ("SECT", "an exceedance judged within", patch_fn(CPD, "WHEN r.exceeds THEN 'exceeds' ELSE 'within'", "WHEN r.exceeds THEN 'within' ELSE 'within'")),
    ("SECT", "inspections outside the month",
     patch_fn(CPD, "WHERE (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date BETWEEN v_start AND v_end;", "WHERE true;")),
    ("SECT", "a later finding counted open at month end",
     patch_fn(CPD, "WHERE (r.inspected_at AT TIME ZONE 'Asia/Singapore')::date <= v_end\n       AND NOT EXISTS", "WHERE true\n       AND NOT EXISTS")),
    ("NOINJ", "the injured person's name carried",
     patch_fn(CPD, "'nea_reportable', i.nea_reportable,",
              "'nea_reportable', i.nea_reportable, 'injured', (SELECT x.injured_person_name FROM incidents x WHERE x.id = i.id),")),
    ("NOINJ", "what happened carried",
     patch_fn(CPD, "'nea_reportable', i.nea_reportable,", "'nea_reportable', i.nea_reportable, 'what', (SELECT x.what_happened FROM incidents x WHERE x.id = i.id),")),
    ("NOINJ", "the inspector's name carried",
     patch_fn(CPD, "'area', r.template_area,",
              "'area', r.template_area, 'by', (SELECT e.preferred_name FROM employees e WHERE e.id = r.inspector_employee_id),")),
    ("NOINJ", "a cost carried", patch_fn(CPD, "'qty_kg', b.qty, 'runs', b.runs", "'qty_kg', b.qty, 'runs', b.runs, 'cost_base', 0")),
    ("NUM", "a second pack without a reason", patch_fn(FRZ, "IF FOUND AND v_reason IS NULL THEN", "IF false THEN")),
    ("NUM", "a reason with nothing to supersede", patch_fn(FRZ, "IF NOT FOUND AND v_reason IS NOT NULL THEN", "IF false THEN")),
    ("NUM", "the -2 suffix lost", patch_fn(FRZ, "CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END", "''")),
    ("NUM", "the old pack not superseded",
     patch_fn(FRZ, "SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason\n         WHERE id = v_prev.id;",
              "SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason\n         WHERE false;")),
    ("NUM", "a frozen pack may be edited", "ALTER TABLE public.compliance_packs DISABLE TRIGGER trg_compliance_packs_write;"),
    ("NUM", "a superseded reason may be rewritten",
     patch_fn(GPW, "AND OLD.superseded_at IS NULL AND NEW.superseded_at IS NOT NULL", "AND NEW.superseded_at IS NOT NULL")),
    ("NUM", "a frozen pack follows the live data", PACK_FOLLOWS_INCIDENTS),
    ("PDF", "bytes recorded on the view code",
     patch_fn(RCI, "PERFORM require_permission('action.compliance_pack');", "PERFORM require_permission('module.compliance.view');")),
    ("PDF", "a path outside the pack's folder", patch_fn(RCI, "p_file_path NOT LIKE v_p.id::text || '/%'", "false")),
    ("PDF", "a digest that is not one accepted",
     patch_fn(RCI, "IF v_sha !~ '^[0-9a-f]{64}$' THEN", "IF false THEN")
     + "ALTER TABLE public.compliance_pack_issues DROP CONSTRAINT compliance_pack_issues_sha256_check;\n"),
    ("PDF", "a superseded pack re-issued", patch_fn(RCI, "IF v_p.superseded_at IS NOT NULL THEN", "IF false THEN")),
    ("PDF", "a missing pack reads as nothing",
     patch_fn(RCI, "RAISE EXCEPTION 'COMPLIANCE_PACK_NOT_FOUND|%', COALESCE(p_pack_id::text, '?');", "RETURN NULL;")),
    ("PDF", "the digest not lower-cased",
     patch_fn(RCI, "v_sha  text := lower(btrim(COALESCE(p_sha256, '')));", "v_sha  text := btrim(COALESCE(p_sha256, ''));")
     + patch_fn(RCI, "IF v_sha !~ '^[0-9a-f]{64}$' THEN", "IF v_sha !~* '^[0-9a-f]{64}$' THEN")
     + "ALTER TABLE public.compliance_pack_issues DROP CONSTRAINT compliance_pack_issues_sha256_check;\n"),
    ("PDF", "the same bytes recorded twice",
     patch_fn(RCI, "WHERE pack_id = p_pack_id AND sha256 = v_sha;", "WHERE false;")
     + "ALTER TABLE public.compliance_pack_issues DROP CONSTRAINT compliance_pack_issues_pack_id_sha256_key;\n"),
    ("PDF", "an issue row may be edited", "ALTER TABLE public.compliance_pack_issues DISABLE TRIGGER trg_compliance_pack_issues_append_only;"),
    ("PDF", "a session may insert an issue",
     "CREATE POLICY f272_inj_iss ON public.compliance_pack_issues FOR INSERT TO authenticated WITH CHECK (true);\n"
     "GRANT INSERT ON public.compliance_pack_issues TO authenticated;"),
]
ALL_272 = {a for a, _, _ in CASES_272}


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


TOUCHED = ["public.compliance_packs", "public.compliance_pack_issues", "public.compliance_settings", "public.pending_values",
           "public.operations_now", "public.document_types", "public.permissions", "public.incidents",
           MAR, EXP, CPD, FRZ, RCI, SCS, CMS, GPW]
P = Pristine(DSN, TOUCHED).capture()
bad = sweep("271", CASES_271, ALL_271)
bad += sweep("272", CASES_272, ALL_272)
P.assert_clean("after both sweeps")
print(f"INJECTIONS_OWN_EXIT={1 if bad else 0} ({len(CASES_271)} injections on 271 + {len(CASES_272)} on 272, {bad} wrong)")
sys.exit(1 if bad else 0)
