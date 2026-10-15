#!/usr/bin/env python3
"""MES-6b-1(v1.4.50):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数与换掉的函数、换掉的视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(结算口径加一列、三支守卫触发器、惩罚条款的守卫改参数、权限目录一行、
单据登记一行、三条授权)在这里逐句写出,并先断言镜像里那几行真的是这个样子。照抄 build_mes6a2_migration.py 的形状。
跑法:python3 db/scripts/build_mes6b1_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql"

NEW_TABLES = ["contract_quality_limits", "quality_limit_judgements", "nonconformance_reports"]   # 外键次序:判定在报告之前
# 先于新表的:新表的触发器要用的那一支(guard_ncr_mutation)与不读新表的几支 —— 纯判据 ncr_holds、取号、条款守卫。
#   (plpgsql 的体在建的时候不解析表名,但【声明】会被编译:一句 nonconformance_reports%ROWTYPE 在表之前建会报
#    "relation does not exist" —— 线上的 COMMIT→ROLLBACK 试跑抓到的,所以其余的一律放到新表之后。)
NEW_FUNCS_EARLY = ["ncr_holds", "next_ncr_code", "guard_ncr_mutation", "guard_substance_priced_and_penalised"]
# 新表之后:读新表的 plpgsql(开 / 决定 / 判定 / 流水守卫)与 SQL 语言的两支(SQL 的体在建的时候就解析表名)
NEW_FUNCS_LATE = ["ncr_open_internal", "open_ncr", "decide_ncr", "judge_quality_limits", "guard_quality_hold",
                  "batch_quality_hold", "assay_is_supplement"]
REPLACED_FUNCS = ["guard_substance_role", "contract_activation_missing", "contract_terms_state", "terms_request_submit_internal",
                  "link_document_to_contract", "sale_settlement_compute", "record_assay_result", "reserve_stock_internal",
                  "blending_plan_write_children", "release_blending_plan", "apply_assay_result", "apply_output_assay",
                  "preview_apply_output_assay", "preview_assay_price", "unapply_assay_result",
                  "trail_subjects", "trail_subject_members", "arm_permission_any", "arm_permission_widen"]
NEW_VIEWS = ["ncr_rows"]
REPLACED_VIEWS = ["pending_values", "operations_now"]

PUBLIC_SIGS = ["public.open_ncr(text, text, uuid, uuid, uuid, uuid, uuid, bigint)",
               "public.decide_ncr(uuid, text, text, uuid, uuid)",
               "public.batch_quality_hold(uuid, uuid)",
               "public.ncr_holds(text, text, timestamp with time zone, numeric)",
               "public.assay_is_supplement(uuid)",
               "public.next_ncr_code(date)"]
INTERNAL_SIGS = ["public.guard_quality_hold()", "public.guard_substance_priced_and_penalised()", "public.guard_ncr_mutation()",
                 "public.ncr_open_internal(uuid, uuid, text, text, uuid, uuid, uuid, bigint, uuid)",
                 "public.judge_quality_limits(uuid, uuid, text)"]

NCR_DECIDERS = ["admin", "cco", "cto"]          # MES-6b Step 0 Q9

# 前后比对的表(既有的行逐字未变)。结算口径减掉新列(减一个不存在的键是空操作)
DIGEST_TABLES = {
    "contracts": [], "contract_settlement_terms": ["quality_limit_basis"], "contract_pricing_terms": [], "contract_penalty_elements": [],
    "contract_refining_charges": [], "contract_grade_specs": [], "contract_document_terms": [], "terms_requests": [],
    "assay_results": [], "assay_result_metals": [], "assay_result_indicators": [], "inbound_batches": [], "output_batches": [],
    "inbound_batch_metals": [], "output_batch_metals": [], "inventory_movements": [], "sales_order_reservations": [],
    "sales_orders": [], "sales_order_lines": [], "sales_settlements": [], "assay_disputes": [], "samples": [],
    "blending_plans": [], "blending_plan_lines": [], "warehouse_requests": [], "receipt_price_requests": [], "price_history": [],
    "invoice_requests": [], "journal_entries": [], "journal_lines": [], "expenses": [], "payments": [], "payment_allocations": [],
    "payment_requests": [], "substances": [], "assay_indicators": [], "materials": [], "suppliers": [], "customers": [],
}


def fn(name):
    body = (ROOT / f"db/functions/{name}.sql").read_text().rstrip("\n") + "\n"
    if not body.rstrip().endswith(";"):
        body = body.rstrip("\n") + ";\n"
    return "\n" + body


def view(name, replace=False):
    body = (ROOT / f"db/views/{name}.sql").read_text().rstrip("\n") + "\n"
    assert "CREATE VIEW public." in body, name
    if replace:
        body = body.replace("CREATE VIEW public.", "CREATE OR REPLACE VIEW public.", 1)
    return "\n" + body


def mirror(path):
    return (ROOT / path).read_text()


def must(path, text):
    assert text in mirror(path), (path, text[:80])
    return text


def between(path, start, end_marker):
    text = mirror(path)
    i = text.index(start)
    j = text.index(end_marker, i) + len(end_marker)
    return text[i:j]


def digest(t, minus):
    j = "to_jsonb(t)" + "".join(f" - '{c}'" for c in minus)
    return f"(SELECT md5(COALESCE(string_agg(({j})::text, '|' ORDER BY ({j})::text), '')) FROM {t} t)"


def comment_stmt(path, head):
    """一句 COMMENT ... IS '…'; —— 字面量里的 '' 是转义,不是结尾。"""
    m = re.search(re.escape(head) + r"\s*'(?:[^']|'')*';\n", mirror(path))
    assert m, (path, head)
    return m.group(0)


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
CST = "db/tables/contract_settlement_terms.sql"
CST_COL = must(CST, """    quality_limit_basis text
        CHECK (quality_limit_basis IS NULL OR quality_limit_basis IN ('none_agreed', 'per_parameter')),
""")
CST_COMMENT = comment_stmt(CST, "COMMENT ON COLUMN public.contract_settlement_terms.quality_limit_basis IS")

CPE = "db/tables/contract_penalty_elements.sql"
CPE_ROLE_TRIGGER = must(CPE, """CREATE TRIGGER trg_contract_penalty_elements_substance_role
    BEFORE INSERT OR UPDATE OF substance ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('payable_metal,penalty_element', 'substance');
""")
CPE_UNPRICED = must(CPE, """CREATE TRIGGER trg_contract_penalty_elements_unpriced
    BEFORE INSERT OR UPDATE OF substance, contract_id ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_priced_and_penalised();
""")
CPE_COMMENT = comment_stmt(CPE, "COMMENT ON TABLE public.contract_penalty_elements IS")
assert "MES-6b-1(F4,Q15)起本表收惩罚元素或可计价的金属" in CPE_COMMENT
CPT_UNPENALISED = must("db/tables/contract_pricing_terms.sql", """CREATE TRIGGER trg_contract_pricing_terms_unpenalised
    BEFORE INSERT OR UPDATE OF metal, contract_id ON public.contract_pricing_terms
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_priced_and_penalised();
""")
IM_HOLD = must("db/tables/inventory_movements.sql", """CREATE TRIGGER trg_inventory_movements_quality_hold
    BEFORE INSERT ON public.inventory_movements
    FOR EACH ROW EXECUTE FUNCTION public.guard_quality_hold();
""")

PERM = "db/tables/permissions.sql"
PERM_ROW = between(PERM, "    ('action.ncr_decide', 'action', 'Decide non-conformance reports'", "1240);")
must(PERM, "    ('action.ncr_decide',               ARRAY['module.quality.view']),")
DOC_ROW = must("db/tables/document_types.sql",
               "    ('ncr', 'NCR', 'nonconformance_reports', 'gapless', NULL, '/quality/ncr', 'detail', 'description', ARRAY['description']::text[], ARRAY['module.quality.view']::text[]);")
RP = mirror("db/tables/role_permissions.sql")
assert "action.ncr_decide" not in RP   # 引导不授它:cco / cto 不在引导里,admin 的引导按目录全给

bindings = mirror("db/views/zzz_change_log_triggers.sql")
bind_sql = []
for t in NEW_TABLES:
    m = re.search(rf"CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public\.{t}\n.*?\n"
                  rf"CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public\.{t}\n.*?\n", bindings)
    assert m, t
    bind_sql.append(m.group(0))
grants = mirror("db/views/zzz_function_grants.sql")
for sig in INTERNAL_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" in grants, sig
for sig in PUBLIC_SIGS:
    assert f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;" not in grants, sig

HEADER = """-- db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql
-- MES-6b-1 —— 质量暂扣经不合格报告;卖方合同的质量验收限(V17);可计价金属也能当惩罚元素(F4);只测惩罚元素的化验是补充(F5)
--   (MES 组的第十四刀,v1.4.50;发布那一行在 docs/handbacks/MES-6b-1.md 的抬头)。
-- 由 db/scripts/build_mes6b1_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-15:MES-6b Step 0 的 Q2–Q9 · Q15–Q16 · Q18–Q28 · Q33–Q42,一律照裁定)
--   ① 不合格报告(Q7):nonconformance_reports(NCR-YYYY-NNNN,按年无洞;进料 XOR 产出;来源 manual · quality_limit · customer_complaint,
--      inspection 保留;说明必填;可挂化验 / 争议 / 销售单 / 判定;open → decided 只经函数;只追加)。open_ncr(module.quality.edit)·
--      decide_ncr(action.ncr_decide;开单人永远不能决定自己那一张,按人认;系统开的任何持码人都能决定)。
--   ② 质量暂扣(Q2 · Q3):一批有一张开着的报告、或一张拒收而货还在的报告,就在暂扣里(判据 ncr_holds 一处;batch_quality_hold 读它)。
--      流水上一支 BEFORE INSERT 守卫(guard_quality_hold)按名拒 QUALITY_HOLD_OPEN|批号|报告编号:投料、销售、发货那条腿、进 committed、
--      不在 CFO 注销申请里的注销;转移、盘点、暂扣 / 释放、释放预留、收货、产出、冲销照常。结算(Q4)与配料计划的建 / 改 / 放行另外显式问。
--   ③ V17(Q8 · Q25–Q27):contract_quality_limits(卖方合同;参数 = 水分或一个指标码;可选物料;下 / 上限)· 结算口径多一列
--      quality_limit_basis(none_agreed · per_parameter;空 = 未设,卖方合同申请生效前必须设;per_parameter 而一行都没有按名拒)。
--      挂接那一刻随结算口径抄进单据的合同副本;化验登记(产出批预留给有限的单)与预留(批已有化验)两处判一次,一参数一行只追加的
--      quality_limit_judgements;越限 → 同一笔事务里开一张来源 quality_limit 的报告,预留照留。
--   ④ F4(Q15 · Q33 · Q34):惩罚条款收惩罚元素或可计价金属;同一份合同里一种物质既计价又罚,两张条款表上一支守卫按名拒
--      SUBSTANCE_PRICED_AND_PENALISED|<码>,申请生效时再问一次;结算的计价圈跳过被列为惩罚元素的可计价金属。
--   ⑤ F5(Q16 · Q36):一份一种可计价金属都没测的化验是【补充】—— 两侧的应用只换掉它测了的那几种、不计价、不顶替前一份、
--      也不被下一份顶替;撤销只删它自己那几行。预览说出它换掉哪几种。
--   ⑥ 三支提醒(ncr_open · quality_hold_reserved · quality_prompt_ncr)· V17 那一行待定值 · 单据登记 NCR · 审计主语 ncr ·
--      三张新表进变更记录(豁免仍是 8;没有遮蔽的列)· action.ncr_decide 进目录并授 cco · cto · admin。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关;授权只多 action.ncr_decide 那三行;不写、不改、不冲任何一张既有单据、批次、
--   化验、合同、条款、预留、流水、结算、配料计划、费用单、付款、分录;不建任何合同、验收限、判定、报告或化验;
--   require_calibrated_since 保持空。线上由本迁移造出的只有:quality_limit_basis 那一列(空)、一个权限码与它的三条授权、
--   单据登记 NCR 那一行。
--
-- 【破窗】旧应用不认 QUALITY_HOLD_OPEN(印兜底句 + 短码)—— 但线上零张报告,所以没有一批在暂扣里,守卫一次都不会拒;
--   旧的合同页不画质量验收限、也不画 quality_limit_basis:卖方合同在部署之前【申请生效会被拒】(清单第 5 项),旧页印那一项的原码。
--   线上 0 份合同,所以窗口里没有人会撞上。窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了 action.ncr_decide 的三行,admin 持目录里每一个码(78);
--   在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的合同、条款、化验、批次、含量、
--   流水、预留、销售单、结算、争议、样品、配料计划、仓库申请、定价申请、价格历史、开票申请、分录、费用单、付款、物质、指标、物料、
--   供应商、客户逐字未变;三张新表零行;变更记录只多了本刀种的那几行;六支新函数员工调得到、五支内层与触发器调不到;
--   anon 能执行的【恰好】两支;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);单据登记 58 行、
--   豁免 45 行;提醒 65 支、待定值 23 行;295 张表。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

parts = [HEADER]
parts.append("""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES6B1_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.nonconformance_reports') IS NOT NULL OR to_regclass('public.contract_quality_limits') IS NOT NULL
       OR to_regclass('public.quality_limit_judgements') IS NOT NULL OR to_regclass('public.ncr_rows') IS NOT NULL
       OR EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'contract_settlement_terms'
                    AND column_name = 'quality_limit_basis')
       OR EXISTS (SELECT 1 FROM permissions WHERE code = 'action.ncr_decide')
       OR EXISTS (SELECT 1 FROM document_types WHERE key = 'ncr' OR prefix = 'NCR')
       OR to_regprocedure('public.batch_quality_hold(uuid, uuid)') IS NOT NULL
       OR to_regprocedure('public.guard_quality_hold()') IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B1_PRE|MES-6b-1 objects already exist';
    END IF;
    IF (SELECT count(*) FROM roles WHERE code IN ('admin', 'cco', 'cto')) <> 3 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected the admin, cco and cto roles';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 77
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected a catalogue of 77 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 57 OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 57 document types and 45 exceptions';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 62 THEN
        RAISE EXCEPTION 'MES6B1_PRE|operations_now should have 62 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 22 THEN
        RAISE EXCEPTION 'MES6B1_PRE|pending_values should have 22 arms before';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 292 THEN
        RAISE EXCEPTION 'MES6B1_PRE|expected 292 public tables';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B1_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join(f"{digest(t, m)} AS {t}" for t, m in DIGEST_TABLES.items())
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes6b1_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes6b1_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes6b1_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes6b1_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes6b1_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append("\n-- ── 1 · 新函数(镜像原样),先于新表的四支:纯判据 ncr_holds · 取号 · 报告只追加的触发器函数 · 条款守卫 ───\n")
for f in NEW_FUNCS_EARLY:
    parts.append(fn(f))

parts.append(f"""
-- ── 2 · 结算口径多一列(与 db/tables/contract_settlement_terms.sql 逐字同一份的约束与注释;可空 = V17 未设,不给默认值)────
ALTER TABLE public.contract_settlement_terms ADD COLUMN
{CST_COL.rstrip().rstrip(',')};
{CST_COMMENT}""")

parts.append("\n-- ── 3 · 新表(镜像原样):质量验收限 · 判定 · 不合格报告(外键次序)─────────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append("\n-- ── 4 · 新函数(镜像原样),新表之后:开 / 决定 / 判定 / 流水守卫 · 暂扣的判据 · 一份化验是不是补充 ──────────────────────\n")
for f in NEW_FUNCS_LATE:
    parts.append(fn(f))

parts.append("\n-- ── 5 · 换掉的函数(镜像原样,同签名)────────────────────────────────────────────────────────────\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 6 · 视图:不合格报告的读面(新)· 待定值多 V17 一行 · 提醒多三支(镜像原样,同列)─────────────────────────\n")
for v in NEW_VIEWS:
    parts.append(view(v))
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append(f"""
-- ── 7 · 守卫上表(与各自的表镜像逐字同一份)────────────────────────────────────────────────────
-- 7a · 惩罚条款的角色守卫改收一组角色(F4):触发器的参数是建的时候定死的,所以 DROP 再建
DROP TRIGGER trg_contract_penalty_elements_substance_role ON public.contract_penalty_elements;
{CPE_ROLE_TRIGGER}-- 7b · 一种物质要么计价、要么罚(两张条款表各一支,同一支函数)
{CPE_UNPRICED}{CPT_UNPENALISED}-- 7c · 质量暂扣守在流水上
{IM_HOLD}-- 7d · 惩罚条款的表注释(F4 改了它收什么)
{CPE_COMMENT}""")

parts.append(f"""
-- ── 8 · 权限目录一行 + 它声明的查看码(与 db/tables/permissions.sql 逐字同一份)· 单据登记 NCR(与 db/tables/document_types.sql 那一行同一份)──
INSERT INTO public.permissions (code, category, name_en, name_zh, description_en, description_zh, sort_order) VALUES
{PERM_ROW}
UPDATE public.permissions SET requires_view_any = ARRAY['module.quality.view'] WHERE code = 'action.ncr_decide';
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
{DOC_ROW}
""")

parts.append("\n-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──\n")
parts.append("".join(bind_sql))

parts.append(f"""
-- ── 10 · 授权(MES-6b Step 0 Q9):action.ncr_decide → {' · '.join(NCR_DECIDERS)} —— 本刀唯一的授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'action.ncr_decide' FROM roles r WHERE r.code IN ({", ".join(f"'{c}'" for c in NCR_DECIDERS)})
ON CONFLICT (role_id, permission_code) DO NOTHING;
""")

acl = ["""
-- ── 11 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
for sig in PUBLIC_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO service_role;\n")
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes6b1_pending_decider_check")
parts.append("\n-- ── 12 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

expected_grants = sorted(f"{r}:action.ncr_decide" for r in NCR_DECIDERS)
public_checks = "\n".join(
    f"""    IF NOT has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|{sig} must be callable by staff and not by anon';
    END IF;""" for sig in PUBLIC_SIGS)
internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(f"{digest(t, m)} IS DISTINCT FROM (SELECT {t} FROM mes6b1_rows_before)" for t, m in DIGEST_TABLES.items())
TRIGGERS = [("contract_penalty_elements", "trg_contract_penalty_elements_substance_role"),
            ("contract_penalty_elements", "trg_contract_penalty_elements_unpriced"),
            ("contract_pricing_terms", "trg_contract_pricing_terms_unpenalised"),
            ("inventory_movements", "trg_inventory_movements_quality_hold"),
            ("nonconformance_reports", "trg_nonconformance_reports_mutation"),
            ("nonconformance_reports", "trg_nonconformance_reports_truncate"),
            ("quality_limit_judgements", "trg_quality_limit_judgements_append_only"),
            ("contract_quality_limits", "trg_contract_quality_limits_frozen")]
for t, g in TRIGGERS:
    assert g in mirror(f"db/tables/{t}.sql"), (t, g)
trigger_checks = "\n       OR ".join(
    f"NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = '{g}' AND tgrelid = 'public.{t}'::regclass)" for t, g in TRIGGERS)

parts.append(f"""
CREATE TEMP TABLE mes6b1_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权:恰好多了 action.ncr_decide 的三行,别的一行没动;admin 持目录里每一个码(78);每一个角色仍满足"动作码蕴含查看码"
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes6b1_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes6b1_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM '{", ".join(expected_grants)}' THEN
        RAISE EXCEPTION 'MES6B1_PROOF|grant change is not exactly the three ncr_decide grants: %', v_bad;
    END IF;
    IF (SELECT count(*) FROM permissions) <> 78
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|admin does not hold every one of the 78 codes';
    END IF;
    IF (SELECT requires_view_any FROM permissions WHERE code = 'action.ncr_decide') IS DISTINCT FROM ARRAY['module.quality.view'] THEN
        RAISE EXCEPTION 'MES6B1_PROOF|action.ncr_decide must declare module.quality.view';
    END IF;
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6B1_PROOF|action-implies-view violated: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES6B1_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes6b1_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes6b1_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(结算口径比对时减掉新列)
    IF EXISTS ((SELECT b.k, b.id FROM mes6b1_pending_before b EXCEPT SELECT a.k, a.id FROM mes6b1_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes6b1_pending_after a EXCEPT SELECT b.k, b.id FROM mes6b1_pending_before b)) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a pre-existing contract, term, assay, batch, content, movement, reservation, order, settlement, dispute, sample, plan, request, price, journal, expense, payment, substance, indicator, material, supplier or customer changed';
    END IF;
    IF EXISTS (SELECT 1 FROM contract_settlement_terms WHERE quality_limit_basis IS NOT NULL) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|quality_limit_basis must start empty (V17 not set) on every existing row';
    END IF;

    -- ④ 三张新表零行(本刀不在线上建任何验收限、判定或报告)
    IF EXISTS (SELECT 1 FROM contract_quality_limits) OR EXISTS (SELECT 1 FROM quality_limit_judgements)
       OR EXISTS (SELECT 1 FROM nonconformance_reports) THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a new table has rows';
    END IF;

    -- ⑤ 变更记录只多了本刀种的那几行:permissions 1 插 1 改 · role_permissions 3 插 · document_types 1 插
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes6b1_log_before), 0)
       AND NOT ((c.op = 'INSERT' AND c.table_name IN ('permissions', 'role_permissions', 'document_types'))
                OR (c.op = 'UPDATE' AND c.table_name = 'permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6B1_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes6b1_log_before), 0);
    IF v_n <> 6 THEN RAISE EXCEPTION 'MES6B1_PROOF|change_log moved by % (expected 1 + 1 + 3 + 1 = 6)', v_n; END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6B1_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑥ 结构:守卫都在;单据登记 58 行带 NCR、豁免 45 行;提醒 65 支、待定值 23 行;295 张表;审计主语 ncr 在册
    IF {trigger_checks} THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a guard trigger is missing';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 58 OR document_type_prefix('ncr') <> 'NCR'
       OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|document_types should be 58 with NCR and exceptions stay 45';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 65
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 23 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|operations_now should have 65 arms and pending_values 23';
    END IF;
    IF (SELECT count(*) FROM pg_tables WHERE schemaname = 'public') <> 295 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|expected 295 public tables';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM trail_subjects() s WHERE s.subject = 'ncr') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|trail subject ncr is not registered';
    END IF;
    IF arm_permission_any('quality_hold_reserved') IS DISTINCT FROM ARRAY['module.output.view']
       OR arm_permission_widen('quality_hold_reserved') IS DISTINCT FROM ARRAY['module.sales.view'] THEN
        RAISE EXCEPTION 'MES6B1_PROOF|quality_hold_reserved must narrow to output view and widen to sales view';
    END IF;

    -- ⑦ 函数面:六支员工调得到;五支内层与触发器调不到;anon 能执行的【恰好】两支;新表与新视图 anon 读不到
{public_checks}
{internal_checks}
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES6B1_PROOF|anon executes: %', v_bad;
    END IF;
    IF has_table_privilege('anon', 'public.nonconformance_reports'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.contract_quality_limits'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.quality_limit_judgements'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.ncr_rows'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|anon can read a new relation';
    END IF;

    -- ⑧ 那 44 条开着的读策略还是 44 条;报告与判定表上没有写策略(只经函数)
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('nonconformance_reports', 'quality_limit_judgements')
                 AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES6B1_PROOF|a write policy exists on nonconformance_reports or quality_limit_judgements';
    END IF;

    -- ⑨ 变更记录:覆盖零缺口(三张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes6b1_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES6B1 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes6b1_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES6B1_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes6b1_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
