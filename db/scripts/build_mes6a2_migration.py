#!/usr/bin/env python3
"""MES-6a-2(v1.4.49):从镜像拼出迁移文件。镜像是真源,迁移是它的一次投影 —— 新表、新函数与换掉的函数、换掉的视图原样从 db/ 下抽出,
所以迁移建出来的与门重建出来的是同一串字。既有表上的改动(substances 加 role 列与两行、六支守卫触发器、单据豁免一行)在这里逐句写出,
并先断言镜像里那几行真的是这个样子。照抄 build_mes6a1_migration.py 的形状。
跑法:python3 db/scripts/build_mes6a2_migration.py(在仓库根目录)。应用之后不要再跑(迁移目录记的是发生过的事)。"""
import pathlib
import re

ROOT = pathlib.Path(".")
OUT = ROOT / "db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql"

NEW_TABLES = ["assay_indicators", "assay_result_indicators"]
NEW_FUNCS = ["guard_substance_role", "payable_metals_only"]
REPLACED_FUNCS = ["upsert_metal_prices", "calculate_metal_price_from_terms", "apply_assay_result", "preview_assay_price",
                  "committed_terms_price", "price_output_sale", "sale_settlement_compute", "allocate_processing_costs",
                  "trail_subjects", "trail_subject_members"]
REPLACED_VIEWS = ["processing_metal_recovery_all"]

OLD_RECORD_ASSAY = "public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)"
NEW_RECORD_ASSAY = "public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb)"
INTERNAL_SIGS = ["public.guard_substance_role()", "public.payable_metals_only(jsonb)"]

# 六张表上的守卫(表镜像里那一句原样)
GUARDED = [("metal_prices", "payable_metal", "metal"), ("pricing_formula_metals", "payable_metal", "metal"),
           ("pricing_term_commitment_metals", "payable_metal", "metal"), ("contract_pricing_terms", "payable_metal", "metal"),
           ("contract_refining_charges", "payable_metal", "metal"), ("contract_penalty_elements", "penalty_element", "substance")]

# 前后比对的表(既有的行逐字未变)。substances 单列:比对时减掉 role、只比既有的七行
DIGEST_TABLES = [
    "metal_prices", "pricing_formulas", "pricing_formula_metals", "pricing_term_commitments", "pricing_term_commitment_metals",
    "contracts", "contract_pricing_terms", "contract_refining_charges", "contract_penalty_elements", "contract_grade_specs",
    "contract_settlement_terms", "material_required_metals", "blending_plan_targets",
    "assay_results", "assay_result_metals", "inbound_batches", "output_batches", "inbound_batch_metals", "output_batch_metals",
    "receipt_price_requests", "price_history", "processing_runs", "journal_entries", "journal_lines", "expenses",
    "payments", "payment_allocations", "payment_requests", "sales_orders", "sales_settlements",
    "samples", "sample_events", "assay_disputes", "materials", "suppliers",
]


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


def digest(t, where=""):
    return f"(SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM {t} t{where})"


SUBST_DIGEST = ("(SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'role')::text, '|' ORDER BY (to_jsonb(t) - 'role')::text), '')) "
                "FROM substances t WHERE t.code NOT IN ('f', 'cl'))")


def comment_stmt(path, head):
    """一句 COMMENT ... IS '…'; —— 字面量里的 '' 是转义,不是结尾。"""
    m = re.search(re.escape(head) + r"\s*'(?:[^']|'')*';\n", mirror(path))
    assert m, (path, head)
    return m.group(0)


# ── 镜像里那几行真的是这个样子 ──────────────────────────────────────────────────
SUB = "db/tables/substances.sql"
must(SUB, "    role       text NOT NULL CHECK (role IN ('payable_metal', 'penalty_element', 'other'))\n);")
SUB_TABLE_COMMENT = comment_stmt(SUB, "COMMENT ON TABLE public.substances IS")
SUB_ROLE_COMMENT = comment_stmt(SUB, "COMMENT ON COLUMN public.substances.role IS")
F_ROW = must(SUB, "    ('f',  'Fluorine',  '氟', 'F',  8, NULL, 'penalty_element'),\n")
CL_ROW = must(SUB, "    ('cl', 'Chlorine',  '氯', 'Cl', 9, NULL, 'penalty_element');")
for code in ("ni", "co", "li", "mn", "cu", "al", "fe"):
    assert re.search(rf"\('{code}',[^\n]*'payable_metal'\)", mirror(SUB)), code

TRIGGERS = []
for t, role, col in GUARDED:
    TRIGGERS.append(must(f"db/tables/{t}.sql", f"""CREATE TRIGGER trg_{t}_substance_role
    BEFORE INSERT OR UPDATE OF {col} ON public.{t}
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('{role}', '{col}');
"""))

# 惩罚条款的表注释:原来写着"氟与氯不在字典里"(Q45:本刀碰到的文件里,过期的记录就地改)
CPE_COMMENT = comment_stmt("db/tables/contract_penalty_elements.sql", "COMMENT ON TABLE public.contract_penalty_elements IS")
assert "曾经的具名缺席,已经补上" in CPE_COMMENT

EXC_ROW = must("db/tables/document_type_exceptions.sql",
               "    ('assay_indicators',              '化验指标的目录(MES-6a-2):code 是指标代号(残粉 · 箔纯度 · D10 / D50 / D90),化验的指标行引用它'),")

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

HEADER = """-- db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql
-- MES-6a-2 —— 氟、氯与化验指标:氟与氯记得下、点得进合同的惩罚条款(% 旁带 ppm),却进不了任何一条定价的路,也不碰结算的计价;
--   化验可以记残粉、箔纯度与粒径(D10 / D50 / D90)(MES 组的第十三刀,v1.4.49;发布那一行在 docs/handbacks/MES-6a-2.md 的抬头)。
-- 由 db/scripts/build_mes6a2_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-10:MES-6a Step 0 的 Q3 · Q4 · Q26–Q32 与 Q38–Q45 中属于 6a-2 的部分,一律照推荐)
--   ① substances.role(Q26):NOT NULL、没有默认值,payable_metal / penalty_element / other;既有七行 → payable_metal。
--      两行新物质(Q31):f 氟 / cl 氯,role = penalty_element,排 8 · 9。
--   ② 守卫(Q27):行情、公式、承诺副本、合同计价条款、精炼费只收 payable_metal(别的按名拒 SUBSTANCE_NOT_PAYABLE|<码>);
--      合同惩罚条款只收 penalty_element(SUBSTANCE_NOT_PENALTY_ELEMENT|<码>)。一支触发器函数 guard_substance_role,六张表各一支;
--      upsert_metal_prices 与计价引擎 calculate_metal_price_from_terms 自己先说同一句。插入与改到那一列时才判,既有的行不回头判。
--   ③ 读者(Q28):结算的计价那一圈、销售报价、按条款计价(应用 · 试算 · 按已承诺条款)、回收率、成本分摊只读 payable_metal ——
--      payable_metals_only 在交给引擎之前拿掉惩罚元素;含量照旧整份落进批次。
--   ④ 指标(Q3 · Q4):assay_indicators(字典,五行:残粉 · 箔纯度 · D10 · D50 · D90)+ assay_result_indicators(一份化验一个指标一行);
--      record_assay_result 尾部多一个 p_indicators(带默认)。没有限、没有判定、没有批次上的副本。
--   ⑤ 两张新表进变更记录(豁免仍是 8)· 两个批次主语多一个成员、一个字典主语 · assay_indicators 进单据登记的豁免(它不是单据)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何码、不改任何授权;不写、不改、不冲任何一张既有单据、批次、化验、
--   合同、条款、行情、费用单、付款、分录;不建任何化验、条款或指标值;require_calibrated_since 保持空。线上由本迁移造出的只有:
--   role 那一列(既有七行填 payable_metal)、f / cl 两行、五个指标的定义、单据豁免那一行。
--
-- 【破窗】旧的化验表单按具名参数调 record_assay_result,不带 p_indicators → 默认值,照常;旧的定价页下拉里多出 f / cl 两个选项
--   (旧 toOptions 不分角色),选了按名拒 SUBSTANCE_NOT_PAYABLE(旧应用印它的兜底句)—— 选不选由人,拒在库里。
--   旧的字典页不认 role 列:在旧页面上【新建】一种物质会被 NOT NULL 拒(改既有的不受影响)。窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动,admin 持目录里每一个码;在途单据一张不少、一张不多,
--   每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的行情、公式、承诺、合同与条款、必测项、配料目标、化验、批次、
--   含量、定价申请、价格历史、炉次、分录、费用单、付款、销售单与结算、样品、争议、物料、供应商逐字未变,既有七种物质除 role 外逐字未变;
--   变更记录只多了 substances 的 7 改 2 插与单据豁免 1 插;指标定义五行、指标值零行;六支守卫在;record_assay_result 只剩新签名;
--   anon 能执行的【恰好】两支;两支内层函数 authenticated 调不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口
--   (豁免 8、规则 114);单据登记 57 行、豁免 45 行。断言失败 = 整笔回滚。

BEGIN;
"""

PENDING = (ROOT / "db/scripts/build_at1a_migration.py").read_text()
PENDING = PENDING[PENDING.index('PENDING = """') + len('PENDING = """'):]
PENDING = PENDING[:PENDING.index('"""')]

parts = [HEADER]
parts.append(f"""
-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES6A2_PRE|approvals are expected ON';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'substances' AND column_name = 'role')
       OR EXISTS (SELECT 1 FROM substances WHERE code IN ('f', 'cl'))
       OR to_regclass('public.assay_indicators') IS NOT NULL OR to_regclass('public.assay_result_indicators') IS NOT NULL
       OR to_regprocedure('public.guard_substance_role()') IS NOT NULL OR to_regprocedure('public.payable_metals_only(jsonb)') IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A2_PRE|MES-6a-2 objects already exist';
    END IF;
    IF (SELECT string_agg(code, ',' ORDER BY sort_order) FROM substances) IS DISTINCT FROM 'ni,co,li,mn,cu,al,fe' THEN
        RAISE EXCEPTION 'MES6A2_PRE|expected exactly the seven metals';
    END IF;
    IF to_regprocedure('{OLD_RECORD_ASSAY}') IS NULL THEN
        RAISE EXCEPTION 'MES6A2_PRE|record_assay_result does not have the signature this migration replaces';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES6A2_PRE|expected 7 accounts';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 77
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6A2_PRE|expected a catalogue of 77 codes, all held by admin';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 57 OR (SELECT count(*) FROM document_type_exceptions) <> 44 THEN
        RAISE EXCEPTION 'MES6A2_PRE|expected 57 document types and 44 exceptions';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6A2_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6A2_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A2_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;
""")

before_cols = ",\n       ".join([f"{SUBST_DIGEST} AS substances"] + [f"{digest(t)} AS {t}" for t in DIGEST_TABLES])
parts.append(f"""
-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes6a2_pending_before ON COMMIT DROP AS
{PENDING};
CREATE TEMP TABLE mes6a2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes6a2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes6a2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes6a2_rows_before ON COMMIT DROP AS
SELECT {before_cols};
""")

parts.append(f"""
-- ── 1 · substances.role(与 db/tables/substances.sql 逐字同一份的约束与注释):加列 → 既有七行填 payable_metal → NOT NULL + CHECK;
--       没有默认值(Q26)—— 所以先加可空的列、填满、再收紧,而不是带一个默认值加进来
ALTER TABLE public.substances ADD COLUMN role text;
UPDATE public.substances SET role = 'payable_metal' WHERE code IN ('ni', 'co', 'li', 'mn', 'cu', 'al', 'fe');
ALTER TABLE public.substances ALTER COLUMN role SET NOT NULL;
ALTER TABLE public.substances ADD CONSTRAINT substances_role_check CHECK (role IN ('payable_metal', 'penalty_element', 'other'));
{SUB_TABLE_COMMENT}
{SUB_ROLE_COMMENT}
-- 两行新物质(Q31;与镜像引导里那两行逐字同一份)
INSERT INTO public.substances (code, name_en, name_zh, symbol, sort_order, notes, role) VALUES
{F_ROW}{CL_ROW}
""")

parts.append("\n-- ── 2 · 新表(镜像原样):化验指标的字典(五行定义)· 化验上的指标值 ─────────────────────────────────────────────\n")
for t in NEW_TABLES:
    parts.append("\n" + mirror(f"db/tables/{t}.sql"))

parts.append("\n-- ── 3 · 新函数(镜像原样):角色守卫 · 只留可计价金属的过滤器(role 列先在,SQL 函数的体才解析得了)────────\n")
for f in NEW_FUNCS:
    parts.append(fn(f))

parts.append(f"""
-- ── 4 · 换掉的函数 ──────────────────────────────────────────────────────────────
-- 4a · record_assay_result 尾部多一个 p_indicators(带默认)—— 签名变了,先 DROP 旧的再建(MES-6a-1 的先例);旧的具名调用照旧走得通
DROP FUNCTION {OLD_RECORD_ASSAY};
""")
parts.append(fn("record_assay_result"))
parts.append("\n-- 4b · 同签名替换(镜像原样):行情与引擎的按名拒 · 读者只读可计价金属 · 审计主语登记\n")
for f in REPLACED_FUNCS:
    parts.append(fn(f))

parts.append("\n-- ── 5 · 换掉的视图(镜像原样,同列):回收率只算可计价金属 ─────────────────────────────────────\n")
for v in REPLACED_VIEWS:
    parts.append(view(v, replace=True))

parts.append("\n-- ── 6 · 六支守卫上表(与各自的表镜像逐字同一份)· 惩罚条款的表注释改掉那句过期的「氟与氯不在字典里」 ──────────────────────\n")
parts.append("".join(TRIGGERS))
parts.append(CPE_COMMENT)

parts.append(f"""
-- ── 7 · 单据登记的豁免:assay_indicators 有 code 列,但它是一份字典,不是单据(与 db/tables/document_type_exceptions.sql 那一行逐字同一份)──
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
{EXC_ROW.rstrip(',')};
""")

parts.append("\n-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份;种子在绑定之前,与重建同一个次序)──\n")
parts.append("".join(bind_sql))

acl = ["""
-- ── 9 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
"""]
acl.append(f"REVOKE EXECUTE ON FUNCTION {NEW_RECORD_ASSAY} FROM PUBLIC, anon;\n")
acl.append(f"GRANT EXECUTE ON FUNCTION {NEW_RECORD_ASSAY} TO authenticated, service_role;\n")
for sig in INTERNAL_SIGS:
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM PUBLIC, anon;\n")
    acl.append(f"GRANT EXECUTE ON FUNCTION {sig} TO service_role;\n")
    acl.append(f"REVOKE EXECUTE ON FUNCTION {sig} FROM authenticated;\n")
parts.append("".join(acl))

a10 = (ROOT / "db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql").read_text()
start = a10.index("CREATE FUNCTION pg_temp.a10_pending_decider_check")
dec = a10[start:a10.index("$f$;", start) + 4].replace("a10_pending_decider_check", "mes6a2_pending_decider_check")
parts.append("\n-- ── 10 · 自证 ────────────────────────────────────────────────────────────\n")
parts.append(dec + "\n")

internal_checks = "\n".join(
    f"""    IF has_function_privilege('authenticated', '{sig}'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', '{sig}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A2_PROOF|{sig} must be a function nobody outside can call';
    END IF;""" for sig in INTERNAL_SIGS)
digest_checks = "\n       OR ".join(
    [f"{SUBST_DIGEST} IS DISTINCT FROM (SELECT substances FROM mes6a2_rows_before)"]
    + [f"{digest(t)} IS DISTINCT FROM (SELECT {t} FROM mes6a2_rows_before)" for t in DIGEST_TABLES])
trigger_checks = " OR ".join(
    f"NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_{t}_substance_role' AND tgrelid = 'public.{t}'::regclass)" for t, _, _ in GUARDED)

parts.append(f"""
CREATE TEMP TABLE mes6a2_pending_after ON COMMIT DROP AS
{PENDING};

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行没动;admin 持目录里每一个码(77)
    IF EXISTS ((SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                EXCEPT SELECT role_code, permission_code FROM mes6a2_grants_before)
               UNION ALL
               (SELECT role_code, permission_code FROM mes6a2_grants_before
                EXCEPT SELECT r.code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) THEN
        RAISE EXCEPTION 'MES6A2_PROOF|a grant changed (this cut changes none)';
    END IF;
    IF (SELECT count(*) FROM permissions) <> 77
       OR EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                                WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES6A2_PROOF|admin does not hold every one of the 77 codes';
    END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES6A2_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes6a2_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes6a2_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES6A2_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变(既有七种物质比对时减掉 role)
    IF EXISTS ((SELECT b.k, b.id FROM mes6a2_pending_before b EXCEPT SELECT a.k, a.id FROM mes6a2_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes6a2_pending_after a EXCEPT SELECT b.k, b.id FROM mes6a2_pending_before b)) THEN
        RAISE EXCEPTION 'MES6A2_PROOF|a pending document changed state';
    END IF;
    IF {digest_checks} THEN
        RAISE EXCEPTION 'MES6A2_PROOF|a pre-existing substance (apart from role), price, formula, commitment, contract, term, requirement, target, assay, batch, content, request, price history, run, journal, expense, payment, sales order, settlement, sample, dispute, material or supplier changed';
    END IF;

    -- ④ 物质:七个可计价、两个惩罚元素,恰好如此;role NOT NULL、没有默认值
    IF (SELECT string_agg(code || ':' || role, ',' ORDER BY sort_order) FROM substances)
         IS DISTINCT FROM 'ni:payable_metal,co:payable_metal,li:payable_metal,mn:payable_metal,cu:payable_metal,al:payable_metal,fe:payable_metal,f:penalty_element,cl:penalty_element'
       OR (SELECT string_agg(concat_ws('|', code, name_en, name_zh, symbol, sort_order, is_active), ';' ORDER BY sort_order) FROM substances WHERE code IN ('f', 'cl'))
         IS DISTINCT FROM 'f|Fluorine|氟|F|8|t;cl|Chlorine|氯|Cl|9|t'
       OR (SELECT is_nullable FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'substances' AND column_name = 'role') <> 'NO'
       OR (SELECT column_default FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'substances' AND column_name = 'role') IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A2_PROOF|substances: seven payable metals, f and cl as penalty elements, role NOT NULL with no default';
    END IF;

    -- ⑤ 指标:五个定义、零个值;没有限的列
    IF (SELECT string_agg(code || '|' || unit, ',' ORDER BY sort_order) FROM assay_indicators)
         IS DISTINCT FROM 'residual_powder_pct|%,foil_purity_pct|%,d10_um|µm,d50_um|µm,d90_um|µm'
       OR EXISTS (SELECT 1 FROM assay_result_indicators) THEN
        RAISE EXCEPTION 'MES6A2_PROOF|the five indicator definitions and no value';
    END IF;

    -- ⑥ 变更记录只多了本刀种的那几行:substances 7 改(role)+ 2 插(f · cl)+ 单据豁免 1 插
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes6a2_log_before), 0)
       AND NOT ((c.table_name = 'substances' AND c.op IN ('INSERT', 'UPDATE'))
                OR (c.table_name = 'document_type_exceptions' AND c.op = 'INSERT'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES6A2_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes6a2_log_before), 0);
    IF v_n <> 10 THEN RAISE EXCEPTION 'MES6A2_PROOF|change_log moved by % (expected 7 + 2 + 1 = 10)', v_n; END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES6A2_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑦ 结构:六支守卫在;record_assay_result 只剩新签名、最后一个参数带默认;单据登记 57 行,豁免 45 行
    IF {trigger_checks} THEN
        RAISE EXCEPTION 'MES6A2_PROOF|a substance-role guard is missing';
    END IF;
    IF to_regprocedure('{OLD_RECORD_ASSAY}') IS NOT NULL OR to_regprocedure('{NEW_RECORD_ASSAY}') IS NULL
       OR (SELECT count(*) FROM pg_proc WHERE proname = 'record_assay_result' AND pronamespace = 'public'::regnamespace) <> 1
       OR pg_get_function_arguments('{NEW_RECORD_ASSAY}'::regprocedure) NOT LIKE '%p_indicators jsonb DEFAULT NULL::jsonb'
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = '{NEW_RECORD_ASSAY}'::regprocedure)
       OR NOT has_function_privilege('authenticated', '{NEW_RECORD_ASSAY}'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A2_PROOF|record_assay_result must exist once, DEFINER, callable by staff, with p_indicators last and defaulted';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 57 OR (SELECT count(*) FROM document_type_exceptions) <> 45 THEN
        RAISE EXCEPTION 'MES6A2_PROOF|document_types should stay 57 and exceptions become 45';
    END IF;

    -- ⑧ 匿名面:anon 能执行的【恰好】两支;两支内层函数调不到;新表 anon 读不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES6A2_PROOF|anon executes: %', v_bad;
    END IF;
{internal_checks}
    IF has_table_privilege('anon', 'public.assay_indicators'::regclass, 'SELECT')
       OR has_table_privilege('anon', 'public.assay_result_indicators'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES6A2_PROOF|anon can read an indicator table';
    END IF;

    -- ⑨ 那 44 条开着的读策略还是 44 条;指标值表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES6A2_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename = 'assay_result_indicators' AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES6A2_PROOF|a write policy exists on assay_result_indicators';
    END IF;

    -- ⑩ 变更记录:覆盖零缺口(两张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有遮蔽的列)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES6A2_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES6A2_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑪ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes6a2_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES6A2 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes6a2_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES6A2_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes6a2_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
""")

OUT.write_text("".join(parts))
print(f"wrote {OUT} ({sum(p.count(chr(10)) for p in parts)} lines)")
