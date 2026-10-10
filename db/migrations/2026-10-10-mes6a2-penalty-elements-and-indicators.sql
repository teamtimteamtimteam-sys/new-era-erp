-- db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql
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
    IF to_regprocedure('public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)') IS NULL THEN
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

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes6a2_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE mes6a2_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes6a2_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes6a2_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes6a2_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'role')::text, '|' ORDER BY (to_jsonb(t) - 'role')::text), '')) FROM substances t WHERE t.code NOT IN ('f', 'cl')) AS substances,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM metal_prices t) AS metal_prices,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM pricing_formulas t) AS pricing_formulas,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM pricing_formula_metals t) AS pricing_formula_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM pricing_term_commitments t) AS pricing_term_commitments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM pricing_term_commitment_metals t) AS pricing_term_commitment_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contracts t) AS contracts,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_pricing_terms t) AS contract_pricing_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_refining_charges t) AS contract_refining_charges,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_penalty_elements t) AS contract_penalty_elements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_grade_specs t) AS contract_grade_specs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_settlement_terms t) AS contract_settlement_terms,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_required_metals t) AS material_required_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM blending_plan_targets t) AS blending_plan_targets,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_results t) AS assay_results,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_metals t) AS assay_result_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) AS output_batches,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t) AS inbound_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t) AS output_batch_metals,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t) AS receipt_price_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM price_history t) AS price_history,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t) AS processing_runs,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) AS journal_entries,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) AS payments,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t) AS payment_allocations,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t) AS payment_requests,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t) AS sales_orders,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_settlements t) AS sales_settlements,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM samples t) AS samples,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sample_events t) AS sample_events,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_disputes t) AS assay_disputes,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t) AS materials,
       (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t) AS suppliers;

-- ── 1 · substances.role(与 db/tables/substances.sql 逐字同一份的约束与注释):加列 → 既有七行填 payable_metal → NOT NULL + CHECK;
--       没有默认值(Q26)—— 所以先加可空的列、填满、再收紧,而不是带一个默认值加进来
ALTER TABLE public.substances ADD COLUMN role text;
UPDATE public.substances SET role = 'payable_metal' WHERE code IN ('ni', 'co', 'li', 'mn', 'cu', 'al', 'fe');
ALTER TABLE public.substances ALTER COLUMN role SET NOT NULL;
ALTER TABLE public.substances ADD CONSTRAINT substances_role_check CHECK (role IN ('payable_metal', 'penalty_element', 'other'));
COMMENT ON TABLE public.substances IS
'PROC-4:我们【测量并核算】的元素与物质 —— 一张字典,替掉曾经重复在八张表上的
那条 CHECK (metal IN (…))。

【为什么叫 substances 而不是 metals(D3)】
排队要进来的东西里,**氟、氯、石墨、塑料没有一个是金属**:氟氯是惩罚元素,
石墨是碳的一种形态,塑料连元素都不是。一张叫 metals 的表在收下石墨那天就开始
说假话,而那时它已经被八张表引用着。**名字选错的代价,是等它被引用之后才付的。**

【本表的行是什么】"一种物质,我们在物料里测它的含量、并在商务上核算它" ——
这一句同时容得下:可付款金属(今天的七个)、惩罚元素(氟、氯)、
以及可回收的非金属流(石墨、塑料)。

【已知的名不副实,而代价是量过的】指向本表的那八个列【仍然叫 metal】。
实测把它改名要动 **623 处**(db/tables 38 · views+functions 89,其中 15 处是
函数吐出去的 **JSON 键**,改了就是改 API 形状 · app+lib 314 · fixtures 182)。
本刀不付这笔账:CHECK 才是挡住氟氯石墨的那个东西,列名只是难看。
**排期:列名 metal → substance_code,代价 623 处,见 docs/known-issues.md。**

【D2:七个可计价金属 + 两个惩罚元素,而这【仍然不是】清单的全部】
  * ~~**氟(F)/ 氯(Cl)** —— 惩罚元素。今天它们【连记都记不下来】。~~
    ★ **MES-6a-2(2026-10-10,MES-6a Step 0 Q31,Tim)加上了**:f / cl,role = penalty_element。化验与含量里记得下,
    合同的惩罚条款里点得了名;**定价那几条路(行情、公式、承诺、合同计价与精炼费、计价器)按名拒它们**
    (SUBSTANCE_NOT_PAYABLE),结算的计价、报价、回收率与成本分摊只读 payable_metal —— 见 role 的列注。
    原来写的返回条件(第一份写明惩罚结构的条款,U11)没有变:它们的阈值与费率仍是一份一份合同的条款(V15 不设待补的值)。
  * **石墨** —— 可回收流。返回条件:**第一次真的回收出一条石墨流**。
  * **塑料** —— 同上。返回条件:**流程图定稿,确认它是一条产品流而不是处置流**
    (U6)。
现在就把后两样加进来,等于宣称我们能记录、能定价它们 —— 而今天两样都不能,
一个没人用得上的字典行会教下一个读它的人"这一类在用"(material_kinds 不加
reagent 是同一条)。

【RUNTIME CONFIG】加一种物质 = 加一行,不是一支迁移。check_mirrors 不逐行比对
它的内容(与 material_kinds / certificate_types / waste_classifications 同形)。';

COMMENT ON COLUMN public.substances.role IS
'MES-6a-2(2026-10-10,MES-0 Q69;MES-6a Step 0 Q26–Q28,Tim):这种物质在商务上扮演什么。NOT NULL,【没有默认值】。

  * payable_metal   —— 按含量计价的金属。【只有它们】进得了定价的那几条路:行情(metal_prices)、公式与它的承诺副本
                       (pricing_formula_metals · pricing_term_commitment_metals)、合同的计价条款与精炼费
                       (contract_pricing_terms · contract_refining_charges)、计价器与 calculate_metal_price_from_terms ——
                       别的按名拒 SUBSTANCE_NOT_PAYABLE(表上的守卫 guard_substance_role 一道,写入函数自己再先说一遍);
                       结算的计价那一圈、销售报价、按条款计价、回收率与成本分摊也只读它们。
  * penalty_element —— 惩罚元素(氟、氯)。【只有它们】点得进合同的惩罚条款(contract_penalty_elements),别的按名拒
                       SUBSTANCE_NOT_PENALTY_ELEMENT;结算只在惩罚那一圈读它们。屏幕上在 % 旁边带 ppm(1 % = 10,000 ppm),不舍到两位。
  * other           —— 记得下、哪儿都不算钱的(将来的石墨、塑料之类)。

【在哪儿都记得下】化验、批次含量、物料必测项、采购单的预计化验、合同品位规格、配料目标 —— 三种都收(Q27 的"任意")。

【为什么没有默认值】一个默认 payable_metal 会让以后加的每一行都悄悄变成"可计价";一个默认 other 会让一种真要计价的金属
悄悄算不进钱。两种错都不报错 —— 所以加一行就得说出它是哪一种(字典编辑器上是一个必选的下拉)。

【改一行的 role 不回头判已经写下的行】与 is_active 同一条(D5):守卫只管新写入与改到那一列的那一次;
既有的行情、条款、含量照旧读得出来。要让一种金属"不再计价",改的是这一列,而它从那一刻起才生效。';

-- 两行新物质(Q31;与镜像引导里那两行逐字同一份)
INSERT INTO public.substances (code, name_en, name_zh, symbol, sort_order, notes, role) VALUES
    ('f',  'Fluorine',  '氟', 'F',  8, NULL, 'penalty_element'),
    ('cl', 'Chlorine',  '氯', 'Cl', 9, NULL, 'penalty_element');

-- ── 2 · 新表(镜像原样):化验指标的字典(五行定义)· 化验上的指标值 ─────────────────────────────────────────────

-- db/tables/assay_indicators.sql
-- MES-6a-2(2026-10-10,MES-0 3.5b · 3.5c · 3.5e;MES-6a Step 0 Q3 · Q4,Tim):化验上【除了物质含量之外】还要记的指标 —— 一张字典。
--   今天五个,都是【定义】,不是标准:残粉(箔上残留的粉,%)· 箔纯度(%)· 粒径的 D10 / D50 / D90(µm,实验室按分布报)。
--   一个值、一个限都没有种 —— 限(V17,水分与粒径的验收限)按合同,随质量冻结排在 MES-6b(Step 0 Q5)。
--   水分【不在这里】:它照旧是 assay_results.moisture_pct 那一列(换湿 / 干基要用它,Q3)。
--   值记在 assay_result_indicators(一份化验一个指标一行),在两张化验表单上填;批次上没有一份抄过去的副本(Q3)。
--   读:持进料 / 产出 / 物料任一查看码的人(不是 USING (true) —— 见下面的策略)。
--   RUNTIME CONFIG:Tim 可以停用任何一个(字典编辑器,与 substances 同一个写码 module.materials.edit);停用只管"还能不能新选",
--   已经记下的值照旧读得出来(与 substances.is_active 同一条,D5)。check_mirrors 不逐行比对它的内容。
--
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.assay_indicators (
    code       text PRIMARY KEY CHECK (code ~ '^[a-z][a-z0-9_]*$'),
    name_en    text NOT NULL CHECK (btrim(name_en) <> ''),
    name_zh    text NOT NULL CHECK (btrim(name_zh) <> ''),
    unit       text NOT NULL CHECK (btrim(unit) <> ''),
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.assay_indicators IS
'MES-6a-2:化验上除物质含量之外要记的指标(字典)。五个定义:残粉 %、箔纯度 %、粒径 D10 / D50 / D90 µm —— 定义,不是标准:没有值、没有限(V17 在 MES-6b)。水分仍是 assay_results.moisture_pct。值在 assay_result_indicators。停用只管新选(D5)。写 module.materials.edit;读要进料 / 产出 / 物料任一查看码。';
COMMENT ON COLUMN public.assay_indicators.unit IS
'这个指标的单位,原样印在值的后面(%、µm)。一个文字标签,不参与任何换算 —— 屏幕不替它换单位。';

-- ── 五个定义(Q4)。值与限一个都不种 ──────────────────────────────────────
INSERT INTO public.assay_indicators (code, name_en, name_zh, unit, sort_order, notes) VALUES
    ('residual_powder_pct', 'Residual powder on foil', '箔上残粉', '%',  1, NULL),
    ('foil_purity_pct',     'Foil purity',             '箔纯度',   '%',  2, NULL),
    ('d10_um',              'Particle size D10',       '粒径 D10', 'µm', 3, NULL),
    ('d50_um',              'Particle size D50',       '粒径 D50', 'µm', 4, NULL),
    ('d90_um',              'Particle size D90',       '粒径 D90', 'µm', 5, NULL);

ALTER TABLE public.assay_indicators ENABLE ROW LEVEL SECURITY;
-- 读:读得到化验的人(进料 / 产出查看码)与维护字典的人(物料查看码)—— 记化验、看化验、看批次的人都要读得出指标的名字。
--   【不是 USING (true)】那 44 条对 authenticated 敞开的读策略是一个被钉住的数(fixture 249 POL),目录也用不着对每一个人敞开
--   (cell_constructions 的先例:按读它的那几页的码)。
CREATE POLICY "assay_indicators select by permission"
    ON public.assay_indicators AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.inbound.view'::text, 'module.output.view'::text, 'module.materials.view'::text]));
CREATE POLICY "assay_indicators insert by permission"
    ON public.assay_indicators AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "assay_indicators update by permission"
    ON public.assay_indicators AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.assay_indicators TO authenticated;
REVOKE ALL ON public.assay_indicators FROM anon;

-- ── SILENT-1 · 被拒绝的写要抛,不许是一次"成功的空操作"(与 substances 同一支语句级触发器)──────────
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.assay_indicators
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');

-- db/tables/assay_result_indicators.sql
-- MES-6a-2(2026-10-10,MES-6a Step 0 Q3 · Q4,Tim):一份化验上一个指标的值 —— 残粉、箔纯度、粒径(assay_indicators 的码)。
--   在两张化验表单上填,经 record_assay_result 的 p_indicators 一起落下(一份化验一笔事务);【没有写策略】,写只经那一支函数。
--   值 ≥ 0,没有上限、没有判定(Q3:没有限 —— V17 在 MES-6b)。单位是指标自己的(字典的 unit)。
--   批次上没有副本(Q3):批次页读的是它那几份化验上最近记下的值,不另存一份会漂开的数。
--   读:与化验的金属行同一条(化验挂在哪一批,就要那一批那一页的查看码)。
--
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.assay_result_indicators (
    assay_result_id uuid NOT NULL REFERENCES public.assay_results (id) ON DELETE CASCADE,
    indicator       text NOT NULL REFERENCES public.assay_indicators (code),
    value           numeric NOT NULL CHECK (value >= 0),
    created_at      timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (assay_result_id, indicator)
);
CREATE INDEX assay_result_indicators_indicator_rel ON public.assay_result_indicators (indicator);

COMMENT ON TABLE public.assay_result_indicators IS
'MES-6a-2:一份化验上一个指标(assay_indicators)的值。经 record_assay_result 的 p_indicators 落下,没有写策略。值 ≥ 0,没有上限、没有判定(没有限,V17 在 MES-6b)。批次上不抄副本。读跟着化验的父批次(进料 / 产出查看码)。';
COMMENT ON COLUMN public.assay_result_indicators.value IS
'记下的值,单位是那个指标自己的(assay_indicators.unit,% 或 µm)。原样存、原样印,不舍入。';

ALTER TABLE public.assay_result_indicators ENABLE ROW LEVEL SECURITY;
-- 与 assay_result_metals 的读策略逐字同一个谓词(化验挂在哪一批,就要那一批那一页的查看码)。写:一条策略都不给。
CREATE POLICY "assay_result_indicators select by permission"
    ON public.assay_result_indicators
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (EXISTS (SELECT 1 FROM public.assay_results ar
                    WHERE ar.id = assay_result_indicators.assay_result_id
                      AND ((ar.inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
                        OR (ar.output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)))));
GRANT SELECT ON public.assay_result_indicators TO authenticated;
REVOKE ALL ON public.assay_result_indicators FROM anon;

-- ── 3 · 新函数(镜像原样):角色守卫 · 只留可计价金属的过滤器(role 列先在,SQL 函数的体才解析得了)────────

-- db/functions/guard_substance_role.sql
-- MES-6a-2(2026-10-10,MES-0 Q69;MES-6a Step 0 Q27,Tim):一张只收【某一种】物质的表上,写进来的那个码必须是那一种。
--   TG_ARGV[0] = 要的 role(payable_metal / penalty_element),TG_ARGV[1] = 存码的那一列(metal / substance)。
--   定价那几张表要 payable_metal → 拒 SUBSTANCE_NOT_PAYABLE|<码>;合同的惩罚条款要 penalty_element → 拒 SUBSTANCE_NOT_PENALTY_ELEMENT|<码>。
--   写入函数(upsert_metal_prices、calculate_metal_price_from_terms)在自己那一步先按名说一遍;这一道守着【每一条】写路 ——
--   直连写的合同条款(action.contract_terms 的写策略)、公式的提交与它的试跑、承诺副本的复制。
--   不在字典里的码不归它管:外键在它之后照旧按 foreign_key_violation 拒(两件不同的事,两句不同的话)。
--   INVOKER:substances 的读策略对每一个登录的人都是 USING (true),没有什么要借属主的眼睛去看。
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql.
CREATE OR REPLACE FUNCTION public.guard_substance_role()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text := to_jsonb(NEW) ->> TG_ARGV[1];
    v_role text;
BEGIN
    IF v_code IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT s.role INTO v_role FROM substances s WHERE s.code = v_code;
    IF NOT FOUND THEN
        RETURN NEW;   -- 外键会说"不在字典里",那不是这一道的话
    END IF;
    IF v_role IS DISTINCT FROM TG_ARGV[0] THEN
        IF TG_ARGV[0] = 'payable_metal' THEN
            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_code
              USING HINT = '这种物质不是按含量计价的金属(substances.role ≠ payable_metal)—— 它不进行情、公式、承诺、合同计价与精炼费';
        END IF;
        RAISE EXCEPTION 'SUBSTANCE_NOT_PENALTY_ELEMENT|%', v_code
          USING HINT = '合同的惩罚条款只收惩罚元素(substances.role = penalty_element)';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/payable_metals_only.sql
-- MES-6a-2(2026-10-10,MES-6a Step 0 Q28,Tim):一张 [{metal, content_pct}, …] 的清单里,把【字典里登记为不计价】的物质拿掉 ——
--   惩罚元素(氟、氯)与 other。按含量计价的那几条读者(按化验应用 · 按化验试算 · 按已承诺条款计价 · 产出的销售报价)把一份化验
--   或一批的含量交给计价引擎之前过这一道:引擎(calculate_metal_price_from_terms)对一个不计价的码【按名拒】SUBSTANCE_NOT_PAYABLE,
--   而一份同时测了氟的化验不该因此算不出镍钴的钱(Q28:氟落在化验或产出批上,什么都不坏)。
--   【不认识的码原样留着】—— 那是引擎的 METAL_INVALID 要说的话,这里不替它吞掉。NULL 进 NULL 出;顺序不变。
--   INVOKER、只读;从 authenticated 收回(只给那几支 DEFINER 读者在体内用)。
-- NOTE: introduced by db/migrations/2026-10-10-mes6a2-penalty-elements-and-indicators.sql.
CREATE OR REPLACE FUNCTION public.payable_metals_only(p_metals jsonb)
 RETURNS jsonb
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' THEN p_metals
        ELSE (SELECT COALESCE(jsonb_agg(e.v ORDER BY e.n), '[]'::jsonb)
                FROM jsonb_array_elements(p_metals) WITH ORDINALITY AS e(v, n)
               WHERE NOT EXISTS (SELECT 1 FROM substances s
                                  WHERE s.code = e.v ->> 'metal' AND s.role <> 'payable_metal'))
    END
$function$;

-- ── 4 · 换掉的函数 ──────────────────────────────────────────────────────────────
-- 4a · record_assay_result 尾部多一个 p_indicators(带默认)—— 签名变了,先 DROP 旧的再建(MES-6a-1 的先例);旧的具名调用照旧走得通
DROP FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid);

CREATE OR REPLACE FUNCTION public.record_assay_result(
    p_assay_date date,
    p_metals jsonb,
    p_lab_name text DEFAULT NULL::text,
    p_certificate_ref text DEFAULT NULL::text,
    p_sample_ref text DEFAULT NULL::text,
    p_is_final boolean DEFAULT true,
    p_notes text DEFAULT NULL::text,
    p_inbound_batch_id uuid DEFAULT NULL::uuid,
    p_output_batch_id uuid DEFAULT NULL::uuid,
    -- ── PROC-6 追加(尾部,带默认,与 PROC-2c 的做法一致)────────────────────
    -- 【两个都默认 NULL,而"必填"由别处执行】
    --   weight_basis  → 触发器(旧行补不出来,所以只管新行)
    --   result_party  → 本函数里具名拒绝 + 列上 NOT NULL 兜底
    -- 这里【不】给业务默认值:默认会让"忘了填"静静变成一个可以拿去算钱的答案。
    p_weight_basis text DEFAULT NULL::text,
    p_moisture_pct numeric DEFAULT NULL::numeric,
    p_result_party text DEFAULT NULL::text,
    -- ── MES-6a-1 追加(2026-10-09,Step 0 Q9):这份结果化验的是哪一份实物样品 —— 尾部、带默认,今天的调用照旧走得通 ──
    --   样品必须挂在同一批上(SAMPLE_NOT_FOR_BATCH);可空,sample_ref 那段自由文本照旧。
    p_sample_id uuid DEFAULT NULL::uuid,
    -- ── MES-6a-2 追加(2026-10-10,Step 0 Q3 · Q4):这份化验上的指标 —— [{indicator, value}, …],尾部、带默认 ──
    --   残粉 / 箔纯度 / 粒径(assay_indicators 的码);值 ≥ 0,没有上限、没有判定(Q3)。空 = 这一份没报指标。
    p_indicators jsonb DEFAULT NULL::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user  uuid := auth.uid();
    v_id    uuid := gen_random_uuid();
    v_code  text;
    v_el    jsonb;
    v_metal text;
    v_pct   numeric;
    v_seen  text[] := ARRAY[]::text[];
    v_count integer := 0;
    v_ind   text;
    v_val   numeric;
    v_iseen text[] := ARRAY[]::text[];
    v_icount integer := 0;
BEGIN
    -- PROC-1:两个父【二选一】。记录、编号、取代共享一张表一条序列;
    -- 权限跟着父走 —— 进料化验挂 inbound 模块,产出化验挂 output 模块。
    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'ASSAY_ONE_PARENT';
    END IF;
    IF p_inbound_batch_id IS NOT NULL THEN
        PERFORM require_permission('module.inbound.edit');
        IF NOT EXISTS (
            SELECT 1 FROM inbound_batches WHERE id = p_inbound_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
        END IF;
    ELSE
        PERFORM require_permission('module.output.edit');
        IF NOT EXISTS (
            SELECT 1 FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL
        ) THEN
            RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
        END IF;
    END IF;
    IF p_assay_date IS NULL OR p_assay_date > CURRENT_DATE THEN
        RAISE EXCEPTION 'ASSAY_DATE_INVALID|%', COALESCE(p_assay_date::text, '?');
    END IF;
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;
    -- MES-6a-2:指标要么不给(NULL),要么是一张清单 —— 一个读不懂的形状不当成"没有指标"
    IF p_indicators IS NOT NULL AND jsonb_typeof(p_indicators) <> 'array' THEN
        RAISE EXCEPTION 'INDICATORS_INVALID';
    END IF;

    -- PROC-6:出具方必须明说。**在这里具名拒绝,而不是等列上的 NOT NULL 抛机器话** ——
    -- 一个具名码翻得成人话,一个 null-value violation 翻不成。
    IF p_result_party IS NULL THEN
        RAISE EXCEPTION 'ASSAY_RESULT_PARTY_REQUIRED'
          USING HINT = '这一份结果是我们出的、对手方出的、还是仲裁实验室出的?没有默认值 —— 默认会让"忘了改"变成"这是我们测的"。';
    END IF;

    -- MES-6a-1(Q9):样品必须是同一批的 —— 在这里按名拒,而不是等表上的守卫抛(两道,同一句话)
    IF p_sample_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM samples s WHERE s.id = p_sample_id
           AND s.inbound_batch_id IS NOT DISTINCT FROM p_inbound_batch_id
           AND s.output_batch_id IS NOT DISTINCT FROM p_output_batch_id) THEN
        RAISE EXCEPTION 'SAMPLE_NOT_FOR_BATCH|%', COALESCE((SELECT code FROM samples WHERE id = p_sample_id), p_sample_id::text);
    END IF;

    v_code := next_assay_code(p_assay_date);
    INSERT INTO assay_results (id, code, inbound_batch_id, output_batch_id, assay_date, lab_name,
                               certificate_ref, sample_ref, is_final, notes,
                               weight_basis, moisture_pct, result_party, sample_id,
                               created_by, updated_by)
    VALUES (v_id, v_code, p_inbound_batch_id, p_output_batch_id, p_assay_date, p_lab_name,
            p_certificate_ref, p_sample_ref, p_is_final, p_notes,
            p_weight_basis, p_moisture_pct, p_result_party, p_sample_id,
            v_user, v_user);

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        -- 【PROC-6 顺手修的一处 PROC-4 漏网】这里原本写着
        --     v_metal NOT IN ('ni','co','li','mn','cu','al','fe')
        -- —— **那是那份金属清单的第九个副本**,而 PROC-4 声称已经清干净了。
        -- 它没有:PROC-4 的 S1 只查了 pg_constraint,【没有查函数体】。
        -- 线上实测函数体里还有四份(见 docs/known-issues.md),本刀只修它正在
        -- 重建的这一支 —— 另外三支按名排期,不在这一刀里顺手动。
        -- 现在它读字典,于是"加一种物质"真的只要一行。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;
        v_pct := (v_el->>'content_pct')::numeric;
        IF v_pct IS NULL OR v_pct < 0 OR v_pct > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;
        INSERT INTO assay_result_metals (assay_result_id, metal, content_pct)
        VALUES (v_id, v_metal, v_pct);
        v_count := v_count + 1;
    END LOOP;

    -- ── MES-6a-2(Step 0 Q3 · Q4):指标。在字典里才收(停用与否由表单的选单管,D5 —— 与上面金属那一段同一个判据);
    --   一个指标一行;值 ≥ 0,【没有上限、没有判定】—— 一个限是一条标准,而 Q3 说没有(V17 在 MES-6b)。
    FOR v_el IN SELECT * FROM jsonb_array_elements(COALESCE(p_indicators, '[]'::jsonb))
    LOOP
        v_ind := v_el->>'indicator';
        IF v_ind IS NULL OR NOT EXISTS (SELECT 1 FROM assay_indicators WHERE code = v_ind) THEN
            RAISE EXCEPTION 'INDICATOR_INVALID|%', COALESCE(v_ind, '?');
        END IF;
        IF v_ind = ANY (v_iseen) THEN
            RAISE EXCEPTION 'DUPLICATE_INDICATOR|%', v_ind;
        END IF;
        v_iseen := v_iseen || v_ind;
        BEGIN
            v_val := (v_el->>'value')::numeric;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'INDICATOR_VALUE_INVALID|%|%', v_ind, COALESCE(v_el->>'value', '?');
        END;
        IF v_val IS NULL OR v_val < 0 THEN
            RAISE EXCEPTION 'INDICATOR_VALUE_INVALID|%|%', v_ind, COALESCE(v_el->>'value', '?');
        END IF;
        INSERT INTO assay_result_indicators (assay_result_id, indicator, value) VALUES (v_id, v_ind, v_val);
        v_icount := v_icount + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'assay_result_id', v_id,
        'code', v_code,
        'metal_count', v_count,
        'indicator_count', v_icount
    );
END;
$function$

;

-- 4b · 同签名替换(镜像原样):行情与引擎的按名拒 · 读者只读可计价金属 · 审计主语登记

CREATE OR REPLACE FUNCTION public.upsert_metal_prices(p_price_date date, p_prices jsonb, p_price_index text DEFAULT NULL::text, p_source text DEFAULT NULL::text, p_source_reference text DEFAULT NULL::text, p_quote_delayed boolean DEFAULT NULL::boolean)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_el       jsonb;
    v_metal    text;
    v_raw      text;
    v_price    numeric;
    v_inserted integer := 0;
    v_updated  integer := 0;
    v_skipped  integer := 0;
    v_was_ins  boolean;
BEGIN
    PERFORM require_permission('action.metal_prices');
    -- METAL-2:录入的是【哪个指数】的行情。NULL = 未声明(老序列),它是一个
    -- 可表示的状态而不是默认值 —— 界面上是一个必须选的下拉,而不是留空就当某个值。
    IF p_price_index IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM metal_price_indices WHERE code = p_price_index AND is_active) THEN
        RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', p_price_index;
    END IF;
    IF p_price_date IS NULL THEN
        RAISE EXCEPTION 'PRICE_DATE_REQUIRED';
    END IF;

    -- LME-1a:【出处必填,而且按名拒】p_source 有 DEFAULT NULL 只是为了不打断
    -- 既有调用方的参数写法 —— 它【不是】一个可以省略的参数,漏了就在这里停下。
    -- 表上那条 NOT NULL(已拿掉 DEFAULT)是兜底:它挡得住绕过本函数的直插,
    -- 但抛出来的是约束原文;这一句是给人看的那一版。
    IF p_source IS NULL OR btrim(p_source) = '' THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_REQUIRED';
    END IF;
    IF p_source NOT IN ('published_index','broker_quote','internal_estimate','unknown') THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_INVALID|%', p_source;
    END IF;
    -- 【unknown 不许用在新录入上】它是给 LME-1a 之前那些无从考证的历史行的。
    -- 允许新录入选 unknown,等于把这一列变回一句空话 —— 只是换了个词。
    IF p_source = 'unknown' THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_UNKNOWN_NOT_ALLOWED_FOR_NEW';
    END IF;
    -- 【published_index 必须说得出是哪一个】表上有同样的 CHECK;这一句先说人话。
    IF p_source = 'published_index' AND p_price_index IS NULL THEN
        RAISE EXCEPTION 'QUOTE_SOURCE_INDEX_REQUIRED';
    END IF;
    IF p_prices IS NULL OR jsonb_typeof(p_prices) <> 'array' THEN
        RAISE EXCEPTION 'NO_PRICES';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_prices)
    LOOP
        v_metal := v_el->>'metal';
        -- PROC-CLEANUP:【现读字典】。这里原本写死七个码 —— 那是 PROC-4 漏掉的三份之一。
        -- PROC-4 报的"残留 0"只对【约束】成立,它的 S1 没有查函数体。
        -- 后果是具体的:往 substances 加一行之后,外键放行,而这里按 METAL_INVALID 拒 ——
        -- 于是"加一种物质 = 加一行"这句承诺,在这条路上不成立。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        -- MES-6a-2(Step 0 Q27):行情只给按含量计价的金属 —— 氟、氯与 other 按名拒(表上的 guard_substance_role 是同一句的第二道)。
        --   放在"空值跳过"之前:一个不该有行情的码,连空着送进来都是一句错话,不是一格没填。
        IF (SELECT role FROM substances WHERE code = v_metal) <> 'payable_metal' THEN
            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_metal;
        END IF;

        -- 空值跳过而不是报错:UI 的每日录入表单常常只填了其中几个金属。
        v_raw := v_el->>'price_usd_per_tonne';
        IF v_raw IS NULL OR btrim(v_raw) = '' THEN
            v_skipped := v_skipped + 1;
            CONTINUE;
        END IF;

        v_price := v_raw::numeric;
        IF v_price IS NULL OR v_price <= 0 THEN
            RAISE EXCEPTION 'PRICE_INVALID|%|%', v_metal, v_raw;
        END IF;

        -- (metal, price_date) 唯一。软删的行也占着这个位置 —— 撞上就顺手复活它
        -- (deleted_at = NULL)并写入新价,这两种情形都算 updated。
        INSERT INTO metal_prices (metal, price_usd_per_tonne, price_date, price_index, source,
                                  source_reference, quote_delayed, created_by, updated_by)
        VALUES (v_metal, v_price, p_price_date, p_price_index, p_source,
                nullif(btrim(coalesce(p_source_reference,'')), ''), p_quote_delayed, v_user, v_user)
        ON CONFLICT (metal, price_date, price_index) DO UPDATE
        SET price_usd_per_tonne = EXCLUDED.price_usd_per_tonne,
            source              = EXCLUDED.source,
            source_reference    = EXCLUDED.source_reference,
            quote_delayed       = EXCLUDED.quote_delayed,
            deleted_at          = NULL,
            updated_by          = v_user
        RETURNING (xmax = 0) INTO v_was_ins;

        IF v_was_ins THEN
            v_inserted := v_inserted + 1;
        ELSE
            v_updated := v_updated + 1;
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'price_date', p_price_date,
        'price_index', p_price_index,
        'source', p_source,
        'inserted', v_inserted,
        'updated', v_updated,
        'skipped', v_skipped
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.calculate_metal_price_from_terms(p_terms jsonb, p_metals jsonb, p_quantity_kg numeric, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ref          date;
    v_index        text;
    v_index_ccy    text;
    v_index_known  boolean;
    v_legs         jsonb;
    v_basis        text;
    v_avg_days     integer;
    v_payables     jsonb;
    v_el           jsonb;
    v_metal        text;
    v_content      numeric;
    v_seen         text[] := ARRAY[]::text[];
    v_payable      numeric;
    v_stated       boolean;   -- ASY-2:本金属在条款里【有没有】被提到
    v_price        numeric;
    v_price_date   date;
    v_from         date;
    v_to           date;
    v_contained    numeric;
    v_payable_kg   numeric;
    v_value        numeric;
    v_lines        jsonb := '[]'::jsonb;
    v_skipped      text[] := ARRAY[]::text[];
    v_unpaid       text[] := ARRAY[]::text[];
    v_gross        numeric := 0;
    v_treatment    numeric;
    v_discount     numeric;
    v_net          numeric;
    v_unit         numeric;
BEGIN
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    v_ref := p_reference_date;
    IF p_terms IS NULL OR jsonb_typeof(p_terms) <> 'object' THEN
        RAISE EXCEPTION 'PRICING_TERMS_INVALID';
    END IF;
    -- METAL-2:条款声明的指数。NULL = 未声明,只看同样未标注指数的行情。
    v_index    := p_terms->>'price_index';
    -- METAL-2:【报价币种没声明就不许算钱】本函数是 USD 进 USD 出(FIN-15 记过:
    -- 换算属于路径,不属于本函数)。一个指数若没声明它按什么货币报价,把它的数字
    -- 当成 USD 就是替这个市场宣称了一件没人说过的事 —— 那与编造一个汇率是同一件事,
    -- 而 THE FX RULE 对编造汇率的答复是:拒绝,并说出缺的是什么。
    -- 未声明指数(v_index IS NULL)的老序列不走这道闸:它按 USD 记了一整年,
    -- 这一点由 metal_prices.price_usd_per_tonne 这个列名本身承担(见迁移抬头)。
    IF v_index IS NOT NULL THEN
        SELECT i.quote_currency, true INTO v_index_ccy, v_index_known
        FROM metal_price_indices i WHERE i.code = v_index AND i.is_active;
        IF NOT COALESCE(v_index_known, false) THEN
            RAISE EXCEPTION 'PRICE_INDEX_UNKNOWN|%', v_index;
        END IF;
        IF v_index_ccy IS NULL THEN
            RAISE EXCEPTION 'INDEX_CURRENCY_NOT_STATED|%', v_index;
        END IF;
    END IF;
    v_basis    := p_terms->>'price_basis';
    v_avg_days := (p_terms->>'average_days')::integer;
    v_payables := COALESCE(p_terms->'payables', '{}'::jsonb);
    -- MES-6a-2(MES-6a Step 0 Q27,Tim):【条款】里只许有按含量计价的金属 —— 一个惩罚元素或 other 写进计价系数,按名拒。
    --   (公式与承诺副本的表上守卫已经拦住了它们;这一句守着把条款现拼出来交给本函数的那几条路,例如产出报价的现价预设。)
    SELECT k INTO v_metal FROM jsonb_object_keys(CASE WHEN jsonb_typeof(v_payables) = 'object' THEN v_payables ELSE '{}'::jsonb END) k
      JOIN substances s ON s.code = k WHERE s.role <> 'payable_metal' ORDER BY k LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_metal;
    END IF;

    -- 2. 数量
    IF p_quantity_kg IS NULL OR p_quantity_kg <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;

    -- 3. 金属清单
    IF p_metals IS NULL OR jsonb_typeof(p_metals) <> 'array' OR jsonb_array_length(p_metals) = 0 THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    FOR v_el IN SELECT * FROM jsonb_array_elements(p_metals)
    LOOP
        v_metal := v_el->>'metal';
        -- PROC-CLEANUP:【现读字典】。这里原本写死七个码 —— 那是 PROC-4 漏掉的三份之一。
        -- PROC-4 报的"残留 0"只对【约束】成立,它的 S1 没有查函数体。
        -- 后果是具体的:往 substances 加一行之后,外键放行,而这里按 METAL_INVALID 拒 ——
        -- 于是"加一种物质 = 加一行"这句承诺,在这条路上不成立。
        IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances WHERE code = v_metal) THEN
            RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
        END IF;
        -- MES-6a-2(Q27 · Q28):要计价的含量清单里也只许有按含量计价的金属。这里【拒】,不悄悄跳过 ——
        --   计价器上的人送来一个氟,是一句错话;而一份同时测了氟的化验,由读它的那几支(按化验应用 / 试算、按已承诺条款计价、
        --   产出报价)先经 payable_metals_only 拿掉惩罚元素再交进来 —— 跳过与否由读者决定,本函数只认一件事。
        IF (SELECT role FROM substances WHERE code = v_metal) <> 'payable_metal' THEN
            RAISE EXCEPTION 'SUBSTANCE_NOT_PAYABLE|%', v_metal;
        END IF;
        IF v_metal = ANY (v_seen) THEN
            RAISE EXCEPTION 'DUPLICATE_METAL|%', v_metal;
        END IF;
        v_seen := v_seen || v_metal;

        v_content := (v_el->>'content_pct')::numeric;
        IF v_content IS NULL OR v_content < 0 OR v_content > 100 THEN
            RAISE EXCEPTION 'CONTENT_INVALID|%|%', v_metal, COALESCE((v_el->>'content_pct'), '?');
        END IF;

        -- 4. 商务条款:条款里没有这个金属 = 完全不计价(payable 0),记入 unpaid_metals。
        --    注意与 skipped 的区别:unpaid 是"没谈价",skipped 是"没行情"。
        -- ASY-2:【条款里没有这个金属】与【条款写明 0%】是两件事,不能都印成 0。
        -- v_stated 把这个区别一路带到输出行:未约定的行 payable/payable_kg/value
        -- 一律给 NULL(界面渲染成"—"),0 从此只属于真的谈成了零的条款。
        -- payable_pct 的 CHECK 是 >= 0,所以"明确 0%"是可表示的、正当的一种条款。
        v_stated := v_payables ? v_metal;
        IF v_stated THEN
            v_payable := (v_payables->>v_metal)::numeric;
        ELSE
            v_payable := 0;
            v_unpaid := v_unpaid || v_metal;
        END IF;

        -- 5. 行情:spot 取参考日之前最近一条;average 取窗口内均值(窗口内无行 → NULL)。
        --
        -- ★★★【PRICE-1:本支的 'average' 与 index_period_average() 是【两条不同的
        --       规矩】,不是同一条规矩的两份实现 —— 不要"顺手"把它们合并】★★★
        --   本支:窗口是 `ref-(avg_days-1) … ref`,一段**回看的滚动窗口**;
        --   **不看任何日历**;把窗口里**碰巧有的那些行**取平均;一行都没有时
        --   把该金属记进 skipped_metals 而**不**中止。
        --   **这样做是对的**,而且是 AGENTS.md 明文维护的裁定:
        --   allocate_processing_costs 走的是**生产**那条路,
        --   「缺一条行情不该让生产停下来」。
        --   index_period_average:窗口是**合同约定的那个自然月**(M+n);
        --   **必须**看 index_market_calendar;要求**每一个交易日都有报价**,
        --   缺一天就 QP_QUOTE_MISSING。
        --   **主语不同**:本支的产出是一个【物理事实的成本摊派】,
        --   那一支的产出是一张【要钱的单据】。生产不能因为缺一条行情而停,
        --   而结算不能带着缺一条行情往下走。
        --   (这段话在 index_period_average.sql 里也有一份,位置对称 ——
        --    会来合并它们的人可能从任何一侧进来。)
        v_price := NULL; v_price_date := NULL; v_from := NULL; v_to := NULL; v_legs := NULL;
        IF v_basis = 'spot' THEN
            -- METAL-3:【读的时候换算,按报价自己那一天】。报价按发布原样存
            -- (SMM 存 CNY),换成本函数的 USD 基准是 metal_quote_to_usd 的事 ——
            -- 一处实现,spot 与 average 共用;缺汇率它自己抛 FX_RATE_MISSING。
            SELECT c.usd, mp.price_date, jsonb_build_array(c.leg)
            INTO v_price, v_price_date, v_legs
            FROM metal_prices mp
            CROSS JOIN LATERAL metal_quote_to_usd(mp.price_usd_per_tonne,
                COALESCE(v_index_ccy, 'USD'), mp.price_date) c
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL AND mp.price_date <= v_ref
              -- METAL-2:只看本条款声明的那个指数。IS NOT DISTINCT FROM 让
              -- 【未声明】只匹配【未标注】,而不是匹配任何一条。
              AND mp.price_index IS NOT DISTINCT FROM v_index
            ORDER BY mp.price_date DESC
            LIMIT 1;
        ELSE
            -- price_from / price_to 报【实际参与均值的行】的日期范围,而不是名义窗口 ——
            -- 结算单据上要能看出这个均价到底由哪几天的行情撑起来。
            -- METAL-3:【每条各按自己那天换算,再取平均】,不是先平均再换 ——
            -- 先平均再换会让窗口内的一次汇率波动污染窗口里的每一天。
            -- v_legs 逐条记下出处,于是这个均价可以被重导出,而不是被相信。
            SELECT avg(c.usd), min(mp.price_date), max(mp.price_date),
                   COALESCE(jsonb_agg(c.leg ORDER BY mp.price_date), '[]'::jsonb)
            INTO v_price, v_from, v_to, v_legs
            FROM metal_prices mp
            CROSS JOIN LATERAL metal_quote_to_usd(mp.price_usd_per_tonne,
                COALESCE(v_index_ccy, 'USD'), mp.price_date) c
            WHERE mp.metal = v_metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_index   -- METAL-2:同上
              AND mp.price_date BETWEEN (v_ref - (v_avg_days - 1)) AND v_ref;
        END IF;

        -- 无可用行情 → 跳过(贡献 0),记入 skipped_metals;沿用 allocate_processing_costs
        -- 的先例:缺行情从来不是硬错误。
        IF v_price IS NULL THEN
            v_skipped := v_skipped || v_metal;
        END IF;

        -- 6. 逐行数量与金额
        v_contained  := round(p_quantity_kg * v_content / 100.0, 4);
        v_payable_kg := round(v_contained * v_payable / 100.0, 4);
        v_value      := CASE WHEN v_price IS NULL THEN 0
                             ELSE round(v_payable_kg / 1000.0 * v_price, 2) END;
        v_gross := v_gross + v_value;

        -- 缺行情/未计价的金属同样出现在 lines 里(金额 0、价格 NULL)——
        -- 结算单据要能逐项交代,不能让它们凭空消失。
        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal,
            'content_pct', v_content,
            -- 未约定 → NULL("未列明"),而不是 0("谈定不付")。金额同理:
            -- 没有条款算不出金额,没有行情也算不出 —— 两种 NULL 都由界面渲染成"—",
            -- 上方的灰字/琥珀提示分别说明是哪一种。汇总仍按 0 累加(贡献确实为零)。
            'payable_pct', CASE WHEN v_stated THEN v_payable END,
            'contained_kg', v_contained,
            'payable_kg', CASE WHEN v_stated THEN v_payable_kg END,
            'price_index', v_index,
            -- METAL-3:换算出处。CNY 原始数、两条腿的汇率、各自实际取自哪一天、
            -- 以及价种(mid)—— 与 price_history 记 original_price / fx_rate /
            -- rate_as_of / rate_type 是同一套做法:数要能被重导出,而不是被相信。
            'fx_legs', COALESCE(v_legs, '[]'::jsonb),
            'quote_currency', COALESCE(v_index_ccy, 'USD'),
            'price_usd_per_tonne', v_price,
            'price_date', v_price_date,
            'price_from', v_from,
            'price_to', v_to,
            'metal_value_usd', CASE WHEN v_stated AND v_price IS NOT NULL THEN v_value END
        );
    END LOOP;

    -- 7. 汇总
    v_gross     := round(v_gross, 2);
    v_treatment := round(p_quantity_kg / 1000.0 * (p_terms->>'treatment_charge_usd_per_tonne')::numeric, 2);
    v_discount  := round(v_gross * (p_terms->>'flat_discount_pct')::numeric / 100.0, 2);
    v_net       := round(v_gross - v_treatment - v_discount, 2);
    v_unit      := round(v_net / p_quantity_kg, 4);

    RETURN jsonb_build_object(
        'formula_id', (p_terms->>'formula_id')::uuid,
        'formula_code', p_terms->>'formula_code',
        'formula_name', p_terms->>'formula_name',
        'price_index', v_index,
        'price_basis', v_basis,
        'average_days', v_avg_days,
        -- FIN-27:这个数按【哪一份条款】算出来的,以及那份条款的费率本身 ——
        -- 出处要能重导出,就不能只给导出后的金额(FIN-26 的同一条道理)。
        'terms_source', p_terms->>'terms_source',
        'commitment_id', p_terms->>'commitment_id',
        'treatment_charge_usd_per_tonne', (p_terms->>'treatment_charge_usd_per_tonne')::numeric,
        'flat_discount_pct', (p_terms->>'flat_discount_pct')::numeric,
        'reference_date', v_ref,
        'quantity_kg', p_quantity_kg,
        'lines', v_lines,
        'gross_value_usd', v_gross,
        'treatment_usd', v_treatment,
        'discount_usd', v_discount,
        'net_value_usd', v_net,
        'unit_price_usd_per_kg', v_unit,
        -- 低品位料确实可能"不值它的处理费";照实返回,由调用方决定接不接这单。
        'negative_value', (v_net < 0),
        'skipped_metals', to_jsonb(v_skipped),
        'unpaid_metals', to_jsonb(v_unpaid)
    );
END;
$function$;

CREATE OR REPLACE FUNCTION public.apply_assay_result(p_assay_result_id uuid, p_pricing_formula_id uuid DEFAULT NULL::uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_assay    record;
    v_batch    record;
    v_commit   uuid;
    v_csrc     uuid;
    v_ccode    text;
    v_live     uuid;
    v_formula  uuid;
    v_fcode    text;
    v_metals   jsonb;
    v_calc     jsonb;
    v_unit     numeric;
    v_rep      jsonb := NULL;
    v_priced   boolean := false;
    v_status   text;
    v_prior    uuid;
    v_note     text := NULL;
    v_open     receipt_price_requests%ROWTYPE;
    v_disp     uuid;
BEGIN
    PERFORM require_permission('action.apply_assay');
    SELECT * INTO v_assay FROM assay_results
    WHERE id = p_assay_result_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', COALESCE(p_assay_result_id::text, '?');
    END IF;
    -- PROC-1:产出化验不走这条路 —— 这里的第 2-5 步全是围着应付转的,
    -- 而产出批没有应付。拆函数,不在函数里藏 IF。
    IF v_assay.output_batch_id IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_IS_OUTPUT|%', v_assay.code;
    END IF;
    IF v_assay.applied_at IS NOT NULL THEN
        RAISE EXCEPTION 'ASSAY_ALREADY_APPLIED|%', v_assay.code;
    END IF;

    SELECT * INTO v_batch FROM inbound_batches
    WHERE id = v_assay.inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_assay.inbound_batch_id;
    END IF;

    -- 0a. ★ MES-6a-1(MES-0 Q62 · MES-6a Step 0 Q18,Tim):这一批挂着一件【开着的】化验争议时,应用任何一份化验都按名拒 ——
    --     争议没结,"哪一份说了算"就还没定,而应用正是在替人做那个选择。放在批次锁之后、任何改动之前;
    --     preview_assay_price 用同一句拒(fixture 40 的那条规矩:试算拒的地方提交也拒)。结案或撤回之后放开。
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.inbound_batch_id = v_batch.id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先在争议页上结案(点名哪一份说了算)或撤回,再应用';
    END IF;

    -- 0. ★ ROLE-1 Batch 4b(Tim 的 Q3 · Q5 · Q6):这张收货挂着一张在等 CFO 的定价申请时 ——
    --    · 来源不是化验(手工 / 按承诺条款 / 收货台):应用按名拒 RECEIPT_PRICE_REQUEST_OPEN,
    --      一个等着批的手工价不许被一份化验从脚下换掉含量;
    --    · 来源是化验:本次取代它 —— 先撤回那一张(理由写明被哪一份取代),本次再提自己的。
    --    放在改含量【之前】:含量守卫(guard_inbound_batch_metals_price_request)在有在等的申请时拒一切写。
    SELECT * INTO v_open FROM receipt_price_requests
     WHERE inbound_batch_id = v_batch.id AND status = 'submitted';
    IF FOUND THEN
        IF v_open.source <> 'assay' THEN
            RAISE EXCEPTION 'RECEIPT_PRICE_REQUEST_OPEN|%|%', v_batch.code, v_open.label;
        END IF;
        PERFORM receipt_price_withdraw_internal(v_open.id,
            'Superseded by assay ' || v_assay.code || ' applied');
    END IF;

    -- 1. 批次含量 = 本化验的含量(删后重插)。分摊、估值、回收率读的都是
    --    inbound_batch_metals —— 它必须始终是"当前最可信的真相";化验行本身留作历史。
    --    PROC-1:抄进的行带出处 —— content_source='assay',指回这份单据。
    DELETE FROM inbound_batch_metals WHERE inbound_batch_id = v_batch.id;
    INSERT INTO inbound_batch_metals (inbound_batch_id, metal, content_pct,
                                      content_source, source_assay_id, created_by, updated_by)
    SELECT v_batch.id, arm.metal, arm.content_pct, 'assay', p_assay_result_id, v_user, v_user
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- MES-6a-2(Step 0 Q28):交给计价引擎的只有按含量计价的金属 —— 一份同时测了氟、氯的化验照常落含量(上一步原样抄全部),
    --   而惩罚元素不进计价(引擎对它们按名拒;不计价的东西本来就不该出现在一张按含量付钱的清单里)。
    SELECT payable_metals_only(jsonb_agg(jsonb_build_object('metal', arm.metal, 'content_pct', arm.content_pct)))
    INTO v_metals
    FROM assay_result_metals arm
    WHERE arm.assay_result_id = p_assay_result_id;

    -- 2. 【结算条款 = 承诺时抄下的副本】(FIN-27)。解析次序与从前解析公式同构:
    --    批次自己的承诺 → 它那条采购行的承诺。活公式在这里【一次都不读】。
    v_commit := resolve_pricing_commitment(v_batch.id);

    IF p_pricing_formula_id IS NOT NULL THEN
        -- 结算时才指名公式(无采购单的现场收货):那一刻【就是】承诺时刻,现在抄。
        -- 已经有副本了就不许被顶掉 —— 副本一旦落下,它就是记录。
        IF v_commit IS NULL THEN
            v_commit := commit_pricing_terms(p_pricing_formula_id, NULL, v_batch.id);
        ELSE
            SELECT c.source_formula_id, c.source_formula_code INTO v_csrc, v_ccode
            FROM pricing_term_commitments c WHERE c.id = v_commit;
            IF v_csrc IS DISTINCT FROM p_pricing_formula_id THEN
                RAISE EXCEPTION 'PRICING_TERMS_ALREADY_COMMITTED|%|%', v_batch.code, v_ccode;
            END IF;
        END IF;
    END IF;

    IF v_commit IS NOT NULL THEN
        -- 3. 与计价器同一份算术(calculate_metal_price_from_terms),条款来自副本;
        --    再走与手工计价【同一条】重计价路径(reprice_inbound_batch)—— 价差分录、
        --    price_history、1200/5000 拆账三件事只存在一份实现。
        --    参考日默认化验日:结算价随行情,行情看化验那天。
        SELECT c.source_formula_id, c.source_formula_code INTO v_formula, v_fcode
        FROM pricing_term_commitments c WHERE c.id = v_commit;

        v_calc := calculate_metal_price_from_terms(
            pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity,
            COALESCE(p_reference_date, v_assay.assay_date));
        v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;

        IF v_unit > 0 THEN
            -- ★ ROLE-1 Batch 4b:算出来的价不再当场过账 —— 在第 7 步提一张申请(来源 assay),
            --   等本次的含量、取代链与 applied_at 都落定之后(指纹要看见"它就是最近一份已应用的化验")。
            v_priced := true;
        ELSE
            -- 低品位料可能"不值它的处理费"(净值 ≤ 0)。负价不入价格机器 ——
            -- 含量照常落地,价格留给人决断。
            v_note := 'computed price not positive: ' || COALESCE(v_unit::text, '?');
        END IF;
    ELSE
        -- 4. 没有副本。有活公式引用【却没有副本】= FIN-27 之前留下的承诺,当时没记
        --    条款 —— 点名拒。悄悄退回去读活公式正是本切要拆掉的行为,而把今天的
        --    公式当成当时谈定的条款,是编造一份承诺(D:不回填)。
        --    完全没有公式引用的批次照旧:手工定价的采购本来就由人定价,不是错误。
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        v_note := 'no pricing formula resolved';
    END IF;

    -- 5. 批次挂上这张公式。★ ROLE-1 Batch 4b(Tim 的 Q3):pricing_status 【不在这里】升 final ——
    --    只在 CFO 批准本次提的那张申请时(receipt_price_post_internal),而且只当这份化验 is_final。
    UPDATE inbound_batches
    SET pricing_formula_id = COALESCE(v_formula, pricing_formula_id),
        updated_by = v_user
    WHERE id = v_batch.id;

    -- 6. 取代链:此前已执行且未被取代的化验,superseded_by 指向本次
    -- code 作平局裁决:applied_at 在同一事务里可能相同(now() 冻结),
    -- 而编号无缝且单调 —— 排序必须确定
    -- ★ MES-6a-1(D4 · Step 0 Q20):只取代【同一出具方】的上一份 —— 应用一份对手方或仲裁的结果【不】把我们的那一份标成
    --   superseded(assay_results.superseded_by 的列注释:"对手方的结果不是对我们结果的取代")。此前这里不看出具方,
    --   一旦有人应用对手方的结果就会静静地盖掉我们自己测到的东西(今天线上从没应用过一份非 ours 的进料化验,所以它从没开过火)。
    SELECT id INTO v_prior FROM assay_results
    WHERE inbound_batch_id = v_batch.id AND id <> p_assay_result_id
      AND result_party = v_assay.result_party
      AND applied_at IS NOT NULL AND superseded_by IS NULL AND deleted_at IS NULL
    ORDER BY applied_at DESC, code DESC LIMIT 1;
    IF v_prior IS NOT NULL THEN
        UPDATE assay_results SET superseded_by = p_assay_result_id, updated_by = v_user
        WHERE id = v_prior;
    END IF;

    UPDATE assay_results
    SET applied_at = now(), applied_by = v_user, updated_by = v_user
    WHERE id = p_assay_result_id;

    -- 7. ★ ROLE-1 Batch 4b(Tim 的 Q3):同一事务里提一张定价申请,来源 assay,提单人 = 按应用的这个人。
    --    提交时照批准那一刻的同一支过账试跑;二级除了提单人再没有别人批得动 → 整次应用按名拒
    --    (RECEIPT_PRICE_NO_OTHER_DECIDER,Tim 的 Q1)。审批关着时当场过账,is_final 时同时升 final。
    IF v_priced THEN
        v_rep := receipt_price_submit_internal(v_batch.id, v_unit, 'USD', 'assay', p_assay_result_id,
                                               v_commit, 'Assay ' || v_assay.code || ' applied');
    END IF;
    SELECT pricing_status INTO v_status FROM inbound_batches WHERE id = v_batch.id;

    -- 完整分解:界面展示的、向供应商/审计师解释调整的,就是这一份 —— 每个数都留
    RETURN jsonb_build_object(
        'assay_result_id', p_assay_result_id,
        'code', v_assay.code,
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        -- ★ ROLE-1 Batch 4b:priced = 这一次【已经过了账】(只在审批关着时);
        --   price_requested = 提了一张定价申请,它的编号与状态在 price_request 里。
        'priced', COALESCE(v_rep->>'status' = 'approved', false),
        'price_requested', v_priced,
        'price_request', v_rep,
        'superseded_request_id', v_open.id,
        'formula_code', v_fcode,
        -- FIN-27:结算按【哪一份承诺】算的 —— 供应商问起来要指得出那份副本
        'commitment_id', v_commit,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'in_stock_ratio', v_rep->'in_stock_ratio',
        'inventory_share_usd', v_rep->'inventory_share_usd',
        'cost_share_usd', v_rep->'cost_share_usd',
        'journal_code', v_rep->'journal_code',
        'pricing_status', v_status,
        'note', v_note
    );
END;
$function$
;

CREATE OR REPLACE FUNCTION public.preview_assay_price(p_inbound_batch_id uuid, p_metals jsonb, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
    v_disp   uuid;
BEGIN
    PERFORM require_permission('action.apply_assay');
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;
    -- ★ MES-6a-1(MES-6a Step 0 Q18):与 apply_assay_result 同一句拒 —— 这一批挂着一件开着的化验争议(fixture 40 F 臂:两侧同一个码)
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.inbound_batch_id = v_batch.id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先在争议页上结案(点名哪一份说了算)或撤回,再应用';
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        RETURN jsonb_build_object('calc', NULL, 'impact', NULL);
    END IF;

    -- MES-6a-2(Q28):与 apply_assay_result 同一句 —— 惩罚元素不进计价(fixture 40 的规矩:试算与应用算的是同一份清单)。
    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), payable_metals_only(p_metals), v_batch.quantity, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 净值 ≤ 0 时不试算:apply_assay_result 那时也不定价(落含量、记 note),
    -- 【这是警告不是拒绝】—— 页面的琥珀提示照旧,按钮保持可用。
    IF v_unit > 0 THEN
        -- 计价口径是 USD/kg(行情与处理费都按 USD/吨),提交也是按 USD 递给
        -- reprice_inbound_batch 的 —— 币种在这里说出来,两边才对得上。
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit, 'USD');
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;

CREATE OR REPLACE FUNCTION public.committed_terms_price(p_inbound_batch_id uuid, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_metals jsonb;
    v_calc   jsonb;
BEGIN
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
            COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
    END IF;

    -- MES-6a-2(Q28):批次含量里的惩罚元素(氟、氯)不进计价 —— 它们记得下,但不按含量付钱。
    SELECT payable_metals_only(jsonb_agg(jsonb_build_object('metal', ibm.metal, 'content_pct', ibm.content_pct)))
    INTO v_metals
    FROM inbound_batch_metals ibm WHERE ibm.inbound_batch_id = v_batch.id;
    IF v_metals IS NULL THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity, p_reference_date);

    RETURN v_calc || jsonb_build_object('commitment_id', v_commit, 'batch_code', v_batch.code);
END;
$function$;

CREATE OR REPLACE FUNCTION public.price_output_sale(p_output_batch_id uuid, p_formula_id uuid, p_currency text, p_quantity numeric, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    -- 【收钱进来 → tt_buy】。改这一处等于把整个卖方报价换到错误的一边 ——
    -- fixture 38 A 臂在 tt_buy 与 tt_sell 不同的日子上钉着它。
    v_side       constant text := 'tt_buy';
    v_batch      record;
    v_metals     jsonb;
    v_terms      jsonb;
    v_mode       text;
    v_default_index text;
    v_formula_code text;
    v_formula_dir  text;
    v_formula_active boolean;
    v_formula_deleted timestamptz;
    v_result     jsonb;
    v_skipped    text[];
    v_usd_price  numeric;
    v_usd        record;
    v_doc        record;
    v_factor     numeric;
    v_unit_ccy   numeric;
BEGIN
    -- 报价就是价格信息(与 calculate_metal_price 同一道门)
    PERFORM require_permission('data.view_prices');

    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;
    IF p_quantity IS NULL OR p_quantity <= 0 THEN
        RAISE EXCEPTION 'QUANTITY_INVALID';
    END IF;
    IF p_currency IS NULL OR NOT EXISTS (SELECT 1 FROM currencies c WHERE c.code = p_currency) THEN
        RAISE EXCEPTION 'CURRENCY_INVALID|%', COALESCE(p_currency, '?');
    END IF;

    SELECT ob.id, ob.code INTO v_batch
    FROM output_batches ob WHERE ob.id = p_output_batch_id AND ob.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', COALESCE(p_output_batch_id::text, '?');
    END IF;

    -- 金属含量来自产出批自己的化验(output_batch_metals)—— 卖的是这批货的含量
    -- MES-6a-2(MES-6a Step 0 Q28):报价只按【按含量计价的金属】算 —— 产出批上记着的氟、氯不进来(它们没有行情,
    --   进来就是 METAL_PRICE_MISSING,把每一张报价都挡住)。一批只记了惩罚元素的,照"没有含量"拒。
    SELECT COALESCE(jsonb_agg(jsonb_build_object('metal', m.metal, 'content_pct', m.content_pct)), '[]'::jsonb)
    INTO v_metals
    FROM output_batch_metals m JOIN substances s ON s.code = m.metal AND s.role = 'payable_metal'
    WHERE m.output_batch_id = p_output_batch_id;
    IF v_metals = '[]'::jsonb THEN
        RAISE EXCEPTION 'NO_METAL_CONTENT|%', v_batch.code;
    END IF;

    IF p_formula_id IS NOT NULL THEN
        v_mode := 'formula';
        SELECT code, direction, is_active, deleted_at
        INTO v_formula_code, v_formula_dir, v_formula_active, v_formula_deleted
        FROM pricing_formulas WHERE id = p_formula_id;
        IF NOT FOUND OR v_formula_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', p_formula_id;
        END IF;
        IF NOT v_formula_active THEN
            RAISE EXCEPTION 'FORMULA_INACTIVE|%', v_formula_code;
        END IF;
        -- 买方公式不能拿来卖:方向是公式自己声明的商务属性
        IF v_formula_dir NOT IN ('sale', 'both') THEN
            RAISE EXCEPTION 'FORMULA_DIRECTION|%|%', v_formula_code, v_formula_dir;
        END IF;
        v_terms := pricing_terms_of_formula(p_formula_id);
    ELSE
        -- ── 现货预设:【填出同一份 terms,走同一台引擎】——————————————————————
        -- 100% 应付、零处理费、零折扣、spot 基准。这不是第四条算术分支:
        -- 下面这份 jsonb 与 pricing_terms_of_formula 的输出同构,进的是同一个
        -- calculate_metal_price_from_terms。fixture 38 B 臂断言它与显式的
        -- 100%/0/0 公式给出同一个数 —— 那正是"预设而非分支"的证明。
        v_mode := 'spot_preset';
        -- METAL-2:现货预设【没有合同可以继承指数】—— 它不是一笔谈定的交易,
        -- 而是"照今天的牌价先算个数"。所以它用 pricing_settings 里的房屋约定。
        -- 【这是一个默认值在替一条缺席的条款站位,不是正确答案】:真正谈成的单子
        -- 会自己声明指数,而这里只是没有人可问。读这个数时要知道它靠的是约定。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;
        SELECT jsonb_build_object(
            'price_index', v_default_index,
            'price_basis', 'spot',
            'average_days', NULL,
            'treatment_charge_usd_per_tonne', 0,
            'flat_discount_pct', 0,
            'payables', COALESCE(jsonb_object_agg(m.metal, 100), '{}'::jsonb))
        INTO v_terms
        FROM output_batch_metals m JOIN substances s ON s.code = m.metal AND s.role = 'payable_metal'
        WHERE m.output_batch_id = p_output_batch_id;
    END IF;

    v_result := calculate_metal_price_from_terms(v_terms, v_metals, p_quantity, p_reference_date);

    -- 报价路径:缺行情即拒(quoting 侧的处置 —— 一份按零价卖出去的报价比停一下更坏;
    -- 分摊侧的"跳过继续"在 allocate_processing_costs,两边注释互指,不要统一)
    SELECT COALESCE(array_agg(x), ARRAY[]::text[]) INTO v_skipped
    FROM jsonb_array_elements_text(COALESCE(v_result->'skipped_metals', '[]'::jsonb)) x;
    IF array_length(v_skipped, 1) > 0 THEN
        -- METAL-2:点名【哪个指数】。两个序列之后,"没有行情"最常见的真相是
        -- "这个金属在【那个】指数上没有行情"—— 另一个指数上很可能正躺着一条好数字,
        -- 而按零计价把它算成不值钱。消息里不写指数,人就会去翻错的那张表。
        RAISE EXCEPTION 'METAL_PRICE_MISSING|%|%|%', array_to_string(v_skipped, ','),
            p_reference_date, COALESCE(v_terms->>'price_index', '(未声明指数)');
    END IF;

    v_usd_price := (v_result->>'unit_price_usd_per_kg')::numeric;

    -- ── USD → 单据币种:与买路径同一扇门(fx_rate_asof),【边】不同 ————————————
    SELECT a.rate, a.as_of INTO v_usd FROM fx_rate_asof('USD', p_reference_date, v_side) a;
    IF v_usd.rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|USD|%|%', p_reference_date, v_side;
    END IF;
    SELECT a.rate, a.as_of INTO v_doc FROM fx_rate_asof(p_currency, p_reference_date, v_side) a;
    IF v_doc.rate IS NULL THEN
        RAISE EXCEPTION 'FX_RATE_MISSING|%|%|%', p_currency, p_reference_date, v_side;
    END IF;
    v_factor := v_usd.rate / v_doc.rate;
    v_unit_ccy := round(v_usd_price * v_factor, 4);

    RETURN jsonb_build_object(
        'unit_price_ccy', v_unit_ccy,
        'currency', p_currency,
        'quantity_kg', p_quantity,
        'breakdown', v_result,
        -- 出处:足以重导出这个数(FIN-26 的标准:重导不出的出处只是标签)。
        -- price_series 恒为 'metal_prices':每金属只有一条序列,不冒称 LME/SMM。
        'provenance', jsonb_build_object(
            'mode', v_mode,
            'formula_id', CASE WHEN p_formula_id IS NOT NULL THEN p_formula_id::text END,
            'formula_code', v_formula_code,
            'terms', v_terms,
            'metals', v_metals,
            'metal_lines', v_result->'lines',
            'price_series', 'metal_prices',
            'quantity_kg', p_quantity,
            'reference_date', p_reference_date,
            'unit_price_usd_per_kg', v_usd_price,
            'fx', jsonb_build_object(
                'side', v_side,
                'usd_rate', v_usd.rate, 'usd_as_of', v_usd.as_of,
                'doc_rate', v_doc.rate, 'doc_as_of', v_doc.as_of,
                'factor', v_factor)
        )
    );
END;
$function$;

-- db/functions/sale_settlement_compute.sql
-- SETTLE-1:一次销售最终结算的算法。CLEANUP-A 加了第二道闸(module.output.view)——
-- 闸问的和身体读的从前不是同一条权限。它【今天拦不到任何人】,而那正是它的理由:
-- 角色改一次就会无声地重新打开它。
--
-- ★【TOOLS-1 ④(2026-09-03):两处基准换算搬进 convert_weight_basis /
--   convert_grade_basis】★ 函数体其余部分【一个字节没动】——
--   `pg_get_functiondef` 的 diff 就是那两行。理由与证据见那两支函数的抬头、
--   db/fixtures/187(新旧逐点比对)与 db/fixtures/149(结算那条路,提取后重跑通过)。

CREATE OR REPLACE FUNCTION public.sale_settlement_compute(p_sales_order_id uuid, p_output_batch_id uuid, p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:一次销售最终结算的**算法** —— 四条条款是**同一条公式**里的四项。
--
-- ★★【一处实现,两个调用者】★★ 本支只**算**,不写;record_sale_settlement 调它
--   再落一行。本仓库为"两份实现在写下来那天一致、之后悄悄分开"付过**四次**账
--   (AGENTS.md 那条预览规则),所以预览与落库读的是同一段算术。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【公式(index-pricing-spec §3),四条条款各占一项】
--     (结算重量 × 含量 × 计价系数) × 计价期均价      ← 重量基准 / PRICE-1 的条款
--   − 精炼费(按【含金属】吨数)                       ← contract_refining_charges
--   − 惩罚(按【结算重量】吨数,超阈值部分)           ← contract_penalty_elements
--   而"用谁的化验"决定了上面的**含量**从哪一行来       ← result_party / settling_party
--
-- ★★【为什么湿基与干基结算出【不同的钱】】★★
--   含金属是**不变量**(换算对了的话,湿基算与干基算得到同一个含量),
--   所以**金属价值与精炼费不随基准变**。变的是**惩罚** ——
--   它按**结算重量**收,而水是随货一起进来的。
--   于是同一批货按湿基结算比按干基**多罚**,而那是对的。
--   **这也正是 GO-3 那个"钱的错误"之所以是钱的错误。**
--
-- 拒绝(全部按名,全部双语):
--   SETTLEMENT_PERMISSION_DENIED|<code>        没有权限(而不是让 RLS 报成"数据缺了")
--   SO_NOT_FOUND / OUTPUT_BATCH_NOT_FOUND / ASSAY_NOT_FOUND
--   SETTLEMENT_NO_CONTRACT_TERMS|<so>          这张单没挂合同,没有可依据的冻结条款
--   SETTLEMENT_TERMS_NOT_SET|<contract>        挂了合同,但那份合同没有结算口径
--   ASSAY_NOT_FOR_BATCH|<assay>|<batch>        选的化验不是这个批次的
--   ★ ASSAY_DISPUTE_OPEN|<batch>|<争议>        这一批挂着一件开着的化验争议(MES-6a-1,Q21)
--   ★ ASSAY_WEIGHT_BASIS_NOT_STATED|<assay>    化验没说按哪种重量报 ← 本刀最要紧的那条
--   ASSAY_PARTY_NOT_THE_SETTLING_PARTY|…       选的化验不是合同约定的那一方(仲裁除外)
--   RESULTS_IN_DISPUTE|…                       两方结果不一致,而没有声明容差
--   RESULTS_EXCEED_SPLITTING_LIMIT|…           不一致超过了声明的容差 → 该走仲裁
--   SETTLEMENT_MOISTURE_NOT_STATED|<assay>     要换算基准却没有水分
--   SETTLEMENT_PAYABLE_NOT_STATED|<metal>      没有计价系数(PRICE-1 的条款)
--   SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|<event> 基准事件的日期在卖方向还记不下来
--   REFINING_CHARGE_NOT_FILED|<contract>|<metal>   声明了按金属收,却没填那一行
--   PENALTY_ELEMENTS_NOT_FILED|<contract>          声明了按元素罚,却一行都没填
DECLARE
    v_st        jsonb;     -- 冻结的结算口径
    v_pricing   jsonb;     -- 冻结的计价条款(PRICE-1)
    v_terms     record;
    v_batch     record;
    v_assay     record;
    v_basis     text;
    v_gross     numeric;
    v_moist     numeric;
    v_swt       numeric;   -- 结算重量
    v_other     record;
    v_lim       numeric;
    v_maxdiff   numeric;
    v_el        jsonb;
    v_ccode     text;
    v_pt_event  text;
    v_pt_months integer;
    v_pt_index  text;
    v_metal     text;
    v_content   numeric;
    v_content_s numeric;
    v_contained numeric;
    v_payable   numeric;
    v_pay_kg    numeric;
    v_price     numeric;
    v_qp        record;
    v_rc        numeric;
    v_base_date date;
    v_lines     jsonb := '[]'::jsonb;
    v_pens      jsonb := '[]'::jsonb;
    v_mv        numeric := 0;
    v_rcs       numeric := 0;
    v_pen       numeric := 0;
    v_thr       numeric;
    v_rate      numeric;
    v_over      numeric;
    v_amt       numeric;
    v_disp      uuid;
BEGIN
    IF p_sales_order_id IS NULL OR p_output_batch_id IS NULL OR p_assay_result_id IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_ARGUMENTS_REQUIRED';
    END IF;
    -- 【权限按名拒,不让 RLS 把行藏起来报成"数据缺了"】PRICE-1 的 fu1 是这一课,
    -- 这里一开始就写上,而不是等 fixture 再抓一次。
    IF NOT has_permission('module.customers.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.customers.view'
          USING HINT = '看得见销售结算要有客户模块的查看权限 —— 这不是数据缺失,是权限';
    END IF;
    -- ★【第二道闸(CLEANUP-A)—— 它今天【拦不到任何人】,而那正是它的理由】★
    -- 上面那道闸问的是 module.customers.view,而本支接下来要读的是
    -- output_batches / assay_results / assay_result_metals —— 这三张的 RLS
    -- 策略问的都是 module.output.view。**闸问的和身体读的不是同一条权限。**
    -- 本支是 SECURITY INVOKER,所以一个只有 customers.view 的读者会走过第一道闸,
    -- 然后【读到零行化验金属】,而金属循环一次都不执行 → metal_value = 0、
    -- refining_charge = 0 → **amount_usd 结算成 0.00,附一张空的 breakdown**。
    -- 那是一个不报错的、可以被当成"这批货不值钱"的数字。
    --
    -- 【实测:今天线上没有任何角色能走到那一步,而这不是不修的理由】
    -- 持 customers.view 的五个角色(admin/auditor/finance/gm/sales)【全部】
    -- 也持 output.view,所以今天这条路复现不了;线上 contract_document_terms
    -- 还是零行,4 张化验单全在进料侧,函数在金属循环之前就按名拒了。
    -- **但这道闸关的不是"现在错着",是"角色改一次就会无声地重新打开它"** ——
    -- 而重新打开的那一天,没有任何东西会响。所以它现在就该在这里。
    -- 【fixture 会构造一个只有 customers.view 的读者来钉住它;那不是线上缺陷的证据。】
    IF NOT has_permission('module.output.view'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.output.view'
          USING HINT = '结算要读产出批次与它的化验结果 —— 那要产出模块的查看权限。'
                       '没有它,化验金属会读成零行,而结算金额会算成 0.00:'
                       '一个不报错、看起来像"这批货不值钱"的数字。';
    END IF;

    -- ── 冻结的条款副本(【抄】,不回查合同现在怎么写)────────────────────────
    SELECT * INTO v_terms FROM contract_document_terms WHERE sales_order_id = p_sales_order_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SETTLEMENT_NO_CONTRACT_TERMS|%', p_sales_order_id
          USING HINT = '这张销售单没有挂在任何合同之下 —— 结算口径是合同条款,没有合同就没有口径';
    END IF;
    v_st := v_terms.settlement_terms;
    v_pricing := v_terms.pricing_terms;
    v_ccode := v_terms.contract_code;
    IF v_st IS NULL OR jsonb_typeof(v_st) <> 'object' OR v_st = '{}'::jsonb THEN
        RAISE EXCEPTION 'SETTLEMENT_TERMS_NOT_SET|%', v_ccode
          USING HINT = '这份合同没有结算口径(重量基准 / 谁的化验说了算 / 精炼费与惩罚的口径)—— 先在合同上写明,再重新挂接';
    END IF;

    SELECT * INTO v_batch FROM output_batches WHERE id = p_output_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_BATCH_NOT_FOUND|%', p_output_batch_id; END IF;
    SELECT * INTO v_assay FROM assay_results WHERE id = p_assay_result_id AND deleted_at IS NULL;
    IF NOT FOUND THEN RAISE EXCEPTION 'ASSAY_NOT_FOUND|%', p_assay_result_id; END IF;
    IF v_assay.output_batch_id IS DISTINCT FROM p_output_batch_id THEN
        RAISE EXCEPTION 'ASSAY_NOT_FOR_BATCH|%|%', v_assay.code, v_batch.code;
    END IF;

    -- ── ★ MES-6a-1(MES-6a Step 0 Q21,Tim):这一批挂着一件【开着的】化验争议时,结算按名拒 ───────────────
    -- 下面那两道推出来的拒绝(RESULTS_IN_DISPUTE / RESULTS_EXCEED_SPLITTING_LIMIT)一字未改:它们看的是两份数字,
    -- 这一道看的是一件被人立起来的争议 —— 立了就等它结案或撤回。本支是 INVOKER:assay_disputes 的读策略给
    -- module.output.view(上面第二道闸刚问过它),所以一个走得到这里的读者不会因为读不到而把它放过去(INVOKER-JOIN-5 那一族)。
    SELECT d.id INTO v_disp FROM assay_disputes d WHERE d.output_batch_id = p_output_batch_id AND d.status = 'open';
    IF FOUND THEN
        RAISE EXCEPTION 'ASSAY_DISPUTE_OPEN|%|%', v_batch.code, v_disp
          USING HINT = '这一批有一件开着的化验争议 —— 先结案(点名哪一份说了算)或撤回,再结算';
    END IF;

    -- ── ★ 化验必须说出它按哪种重量报 ★ ─────────────────────────────────────
    -- GO-3:一张按干基出的化验单被乘在湿重上,含金属被**高估**,而没有任何东西会响。
    -- **留空 = 没有人说过**,而不是"按惯例是干基" —— 所以这里拒,不猜。
    IF v_assay.weight_basis IS NULL THEN
        RAISE EXCEPTION 'ASSAY_WEIGHT_BASIS_NOT_STATED|%', v_assay.code
          USING HINT = '这份化验没有说明它按湿基还是干基报 —— 而两者会结算出不同的金额,所以不能猜';
    END IF;

    -- ── 谁的化验说了算 ────────────────────────────────────────────────────
    -- 仲裁结果【总是】可以结算:它是那条升级路径的终点。
    IF v_assay.result_party <> 'umpire'
       AND v_assay.result_party IS DISTINCT FROM (v_st->>'settling_party') THEN
        RAISE EXCEPTION 'ASSAY_PARTY_NOT_THE_SETTLING_PARTY|%|%|%',
            v_assay.code, v_assay.result_party, (v_st->>'settling_party');
    END IF;

    -- ── 两方结果不一致时,【系统不自己选】────────────────────────────────
    -- ★ 让系统按容差自动选,等于让系统**决定谁的数字是钱**;而容差为空时,
    --   它还得**编一个默认值**才做得到那件事。所以:指出,不选。
    IF v_assay.result_party <> 'umpire' THEN
        SELECT a.code, a.id INTO v_other
          FROM assay_results a
         WHERE a.output_batch_id = p_output_batch_id AND a.deleted_at IS NULL
           AND a.id <> p_assay_result_id
           AND a.result_party IN ('ours', 'counterparty')
           AND a.result_party <> v_assay.result_party
         ORDER BY a.assay_date DESC LIMIT 1;
        IF FOUND THEN
            v_lim := (v_st->>'splitting_limit_pct')::numeric;
            -- 逐元素比,取最大差
            SELECT max(abs(x.content_pct - y.content_pct)) INTO v_maxdiff
              FROM assay_result_metals x JOIN assay_result_metals y
                ON y.metal = x.metal AND y.assay_result_id = v_other.id
             WHERE x.assay_result_id = p_assay_result_id;
            IF v_maxdiff IS NOT NULL AND v_maxdiff > 0 THEN
                IF v_lim IS NULL THEN
                    RAISE EXCEPTION 'RESULTS_IN_DISPUTE|%|%|%', v_assay.code, v_other.code, v_maxdiff
                      USING HINT = '两方的化验结果不一致,而这份合同没有声明容差 —— 要么在合同里写明容差,要么记录一份仲裁结果并按它结算;系统不会替你选哪一方的数字是钱';
                ELSIF v_maxdiff > v_lim THEN
                    RAISE EXCEPTION 'RESULTS_EXCEED_SPLITTING_LIMIT|%|%|%|%', v_assay.code, v_other.code, v_maxdiff, v_lim
                      USING HINT = '两方结果的差距超过了合同声明的容差 —— 按合同该送第三方复检,并用仲裁结果结算';
                END IF;
            END IF;
        END IF;
    END IF;

    -- ── 重量基准:换算,或按名拒 ──────────────────────────────────────────
    v_basis := v_st->>'sale_weight_basis';
    v_gross := v_batch.quantity;
    v_moist := v_assay.moisture_pct;
    IF v_assay.weight_basis <> v_basis AND v_moist IS NULL THEN
        RAISE EXCEPTION 'SETTLEMENT_MOISTURE_NOT_STATED|%', v_assay.code
          USING HINT = '化验按一种基准报、合同按另一种结算,换算要用水分 —— 而这份化验没有水分,所以算不了';
    END IF;
    -- TOOLS-1 ④:换算搬进 convert_weight_basis(表达式逐字未改)。一份实现,两个调用方。
    v_swt := convert_weight_basis(v_gross, 'as_received', v_basis, v_moist);

    -- ── 逐金属:含量 → 应付量 → 计价期均价 → 金额;并扣精炼费 ────────────
    -- MES-6a-2(MES-6a Step 0 Q28,Tim):这一圈只走【按含量计价的金属】—— 化验上的氟、氯不要计价条款、不收精炼费
    --   (此前它们在这里会按名拒 SETTLEMENT_PAYABLE_NOT_STATED / REFINING_CHARGE_NOT_FILED,一份测了氟的化验就结算不了);
    --   它们只在下面惩罚那一圈被读。
    FOR v_metal, v_content IN
        SELECT m.metal, m.content_pct FROM assay_result_metals m
          JOIN substances s ON s.code = m.metal AND s.role = 'payable_metal'
         WHERE m.assay_result_id = p_assay_result_id ORDER BY m.metal
    LOOP
        -- 把含量换算到【结算基准】上。含金属因此是不变量 —— 见抬头。
        -- TOOLS-1 ④:换算搬进 convert_grade_basis(表达式逐字未改)。
        v_content_s := convert_grade_basis(v_content, v_assay.weight_basis, v_basis, v_moist);
        v_contained := round(v_swt * v_content_s / 100.0, 4);

        SELECT (e->>'payable_pct')::numeric INTO v_payable
          FROM jsonb_array_elements(COALESCE(v_pricing, '[]'::jsonb)) e
         WHERE e->>'metal' = v_metal;
        IF v_payable IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_PAYABLE_NOT_STATED|%', v_metal
              USING HINT = '计价系数是一条合同条款(PRICE-1 的 contract_pricing_terms)—— 没有它就不知道买方按含量的多大比例付钱';
        END IF;
        v_pay_kg := round(v_contained * v_payable / 100.0, 4);

        -- 计价期均价 —— **调 PRICE-1 那一支,不另写一份**(两份实现会悄悄分开)
        SELECT e->>'base_event', (e->>'qp_months')::int, e->>'index_code'
          INTO v_pt_event, v_pt_months, v_pt_index
          FROM jsonb_array_elements(v_pricing) e WHERE e->>'metal' = v_metal;
        -- 【卖方向今天只记得下"化验完成"这一个事件日期】发货日与到货日在这一侧
        -- 还没有落点,所以按它们定基准月的合同**按名拒**,而不是拿一个别的日期顶替。
        v_base_date := CASE WHEN v_pt_event = 'assay_complete' THEN v_assay.assay_date END;
        IF v_base_date IS NULL THEN
            RAISE EXCEPTION 'SETTLEMENT_BASE_EVENT_DATE_UNKNOWN|%', COALESCE(v_pt_event, '(none)')
              USING HINT = '卖方向今天记得下来的事件日期只有【化验完成】—— 发货日与到货日还没有落点,所以按它们定基准月的合同结算不了';
        END IF;
        SELECT qp.qp_from, qp.qp_to INTO v_qp FROM quotational_period(v_base_date, v_pt_months) qp;
        v_price := (index_period_average(v_pt_index, v_metal, v_qp.qp_from, v_qp.qp_to)
                    ->>'avg_usd_per_tonne')::numeric;
        v_mv := v_mv + round(v_pay_kg / 1000.0 * v_price, 2);

        -- 精炼费:按【含金属】吨数 —— 所以它**不随基准变**
        v_rc := 0;
        IF v_st->>'refining_charge_basis' = 'per_metal' THEN
            SELECT (e->>'usd_per_tonne_of_metal')::numeric INTO v_rc
              FROM jsonb_array_elements(COALESCE(v_st->'refining_charges', '[]'::jsonb)) e
             WHERE e->>'metal' = v_metal;
            IF v_rc IS NULL THEN
                RAISE EXCEPTION 'REFINING_CHARGE_NOT_FILED|%|%', v_ccode, v_metal
                  USING HINT = '这份合同声明了按金属收精炼费,却没有填这一种金属的费率 —— 【声明了有】与【填了多少】是两件事,而只有后者算得出钱';
            END IF;
            v_rcs := v_rcs + round(v_contained / 1000.0 * v_rc, 2);
        END IF;

        v_lines := v_lines || jsonb_build_object(
            'metal', v_metal, 'content_pct_assay', v_content,
            'content_pct_settlement', round(v_content_s, 6),
            'contained_kg', v_contained, 'payable_pct', v_payable,
            'payable_kg', v_pay_kg, 'price_usd_per_tonne', v_price,
            'qp_from', v_qp.qp_from, 'qp_to', v_qp.qp_to,
            'refining_charge_usd_per_tonne_of_metal', v_rc);
    END LOOP;

    -- ── 惩罚:按【结算重量】吨数 —— 所以它**随基准变** ────────────────────
    IF v_st->>'penalty_basis' = 'per_element' THEN
        IF COALESCE(jsonb_array_length(v_st->'penalty_elements'), 0) = 0 THEN
            RAISE EXCEPTION 'PENALTY_ELEMENTS_NOT_FILED|%', v_ccode
              USING HINT = '这份合同声明了按元素罚,却一条惩罚条款都没有填 —— 【声明了有】与【填了哪些】是两件事';
        END IF;
        FOR v_el IN SELECT e FROM jsonb_array_elements(v_st->'penalty_elements') e LOOP
            v_thr  := (v_el->>'threshold_pct')::numeric;
            v_rate := (v_el->>'usd_per_tonne_per_pct_over')::numeric;
            SELECT m.content_pct INTO v_content FROM assay_result_metals m
             WHERE m.assay_result_id = p_assay_result_id AND m.metal = v_el->>'substance';
            IF v_content IS NULL THEN CONTINUE; END IF;   -- 这份化验没测这个元素
            v_content_s := CASE
                WHEN v_assay.weight_basis = v_basis THEN v_content
                WHEN v_assay.weight_basis = 'dry' AND v_basis = 'as_received'
                    THEN v_content * (1 - v_moist / 100.0)
                ELSE v_content / (1 - v_moist / 100.0) END;
            v_over := v_content_s - v_thr;
            IF v_over > 0 THEN
                v_pen := v_pen + round(v_swt / 1000.0 * v_over * v_rate, 2);
                v_pens := v_pens || jsonb_build_object(
                    'substance', v_el->>'substance', 'threshold_pct', v_thr,
                    'content_pct_settlement', round(v_content_s, 6),
                    'pct_over', round(v_over, 6), 'rate', v_rate);
            END IF;
        END LOOP;
    END IF;

    v_amt := round(v_mv - v_rcs - v_pen, 2);
    RETURN jsonb_build_object(
        'sales_order_id', p_sales_order_id, 'output_batch_id', p_output_batch_id,
        'assay_result_id', p_assay_result_id, 'assay_code', v_assay.code,
        'settling_party_used', v_assay.result_party,
        'weight_basis_used', v_basis,
        'assay_weight_basis', v_assay.weight_basis,
        'gross_weight_kg', v_gross, 'moisture_pct', v_moist,
        'settlement_weight_kg', v_swt,
        'metal_value_usd', v_mv, 'refining_charge_usd', v_rcs,
        'penalty_usd', v_pen, 'amount_usd', v_amt,
        'breakdown', jsonb_build_object('metals', v_lines, 'penalties', v_pens),
        'terms_snapshot', v_st);
END
$function$;

CREATE OR REPLACE FUNCTION public.allocate_processing_costs(p_run_id uuid, p_basis text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- Cost allocation. Metals with a usable price (deleted_at IS NULL, price_date <= run
-- process_date) contribute to metal value; metals WITHOUT one contribute 0 and are
-- recorded in allocation_snapshot.skipped_metals (the former missing-price hard error is gone).
-- NO_METAL_VALUE still blocks when the total metal value across all legs is 0.
-- (Phase 1 follow-up 1, 2026-07-03.)
-- cut 2a (2026-07-06): 10a 资本化分录(借 1220 / 贷 1200 材料 + 贷 5xxx 费用;
-- 重分摊 = 冲旧 + 重挂);10b 给无 COGS 的既有销售按原 sale_date 补挂 COGS。
DECLARE
    v_user                 uuid := auth.uid();
    v_run                  processing_runs%ROWTYPE;
    v_basis                text;
    v_process_date         date;
    v_material             numeric;
    v_process              numeric;
    v_total                numeric;
    v_inputs_without_price integer;
    v_total_basis          numeric;
    v_total_metal_value    numeric;
    v_bad_code             text;
    v_bad_metal            text;
    v_prices_used          jsonb;
    v_default_index        text;
    v_skipped_metals       jsonb;
    v_outputs              jsonb;
    v_sum_alloc            numeric;
    v_snapshot             jsonb;
    v_ct                   record;
    v_sale                 record;
    v_cap_lines            jsonb;
    v_cap_total            numeric;
    v_cap_je               jsonb;
    v_cap_entry_id         uuid;
    v_cogs                 numeric;
    v_cogs_je              jsonb;
    -- FIN-24:差额法用
    v_prior                jsonb;      -- 分摊前各产出腿的 allocated(差额的"已记录"侧)
    v_rec_src              jsonb;      -- 已记录的各来源(material / 各 cost_type)
    v_rec_total            numeric;
    v_by_source            jsonb;      -- 本次各来源(写进 snapshot,下次的"已记录")
    v_delta                numeric;
    v_leg                  record;
    v_d1220                numeric := 0;
    v_d5000                numeric := 0;
    v_d5200                numeric := 0;
    v_l1220                numeric;
    v_l5000                numeric;
    v_other                numeric;
    v_cred_total           numeric := 0;
    v_deb_total            numeric;
    v_cap_status           text;
    -- FIN-25:再加工
    v_material_in          numeric;   -- 进料批投料(→ 1200)
    v_material_re          numeric;   -- 产出批投料(→ 1220 解除上游)
    v_upstream_incomplete  boolean;
    v_re_without_price     integer;
    -- PROC-COST-1:状态改变型分支
    v_state_changing       boolean;
    v_sc_out_inputs        integer;
    v_sc_in_inputs         integer;
    v_sc_basis_total       numeric;
    v_sc_rows              jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    -- 1. Lock the run; must exist and be a live committed run.
    SELECT * INTO v_run FROM processing_runs WHERE id = p_run_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RUN_NOT_FOUND|%', p_run_id;
    END IF;
    IF v_run.deleted_at IS NOT NULL OR v_run.status <> 'committed' THEN
        RAISE EXCEPTION 'RUN_NOT_COMMITTED|%', v_run.status;
    END IF;

    -- PROC-COST-1:那条"无处可落"的拒绝在这里【换成了真正的去处】——
    -- 状态改变型的分支在第 6 步之后(它需要 v_material / v_process 都已算出)。
    -- 仍然拒绝的四种情形在分支里逐一按名点出,理由见本迁移的 2e 段。

    -- 2. Resolve + validate basis.
    v_basis := COALESCE(p_basis, v_run.allocation_basis);
    IF v_basis NOT IN ('weight','metal_value') THEN
        RAISE EXCEPTION 'INVALID_BASIS|%', v_basis;
    END IF;
    v_process_date := v_run.process_date;

    -- 3. Unit guard: all math assumes kg.
    SELECT ib.code INTO v_bad_code
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id AND ib.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    SELECT ob.code INTO v_bad_code
    FROM processing_outputs po
    JOIN output_batches ob ON ob.id = po.output_batch_id
    WHERE po.run_id = p_run_id AND ob.unit <> 'kg'
    LIMIT 1;
    IF FOUND THEN
        RAISE EXCEPTION 'UNIT_NOT_KG|%', v_bad_code;
    END IF;

    -- 4. Material cost(FIN-25 起两路):进料批按 inbound.unit_price;产出批
    --    (再加工)按上游 processing_outputs.unit_cost_base。NULL 价照旧计 0 并
    --    计数 —— 【允许,不拒绝】:车间按天走,财务分摊按月走,拒绝会让车间等
    --    财务。零不静默:cost_incomplete 标记打在本单产出上,逐级传染(见 9c),
    --    上游补分摊后本单过期,重跑即修复。
    -- FRT-1:材料成本 = 【落地成本】,不只是单价 —— 单价 + 分摊到该批的单位运费。
    -- 运费资本化进批次之后,这里若仍只读 unit_price,运费就停在 1200/5000,
    -- 永远走不到产出批的 unit_cost_base,batch_margin 会继续停在运费之前的那个数
    -- (而运费那张分录本身完全正确)。这正是"资本化的错误藏在存货里"最具体的一种。
    SELECT COALESCE(SUM(pi.quantity_consumed
             * (COALESCE(ib.unit_price, 0)
                -- ★ ROLE-1 Batch 3a:读 _all —— 【算一笔要过账的钱不许问权限】(inbound_batch_landed_unit_cost
                -- 的同一条规矩)。此前读带判据的屏幕读取器,靠的是分摊的人碰巧看得见;一个 NULL 加数会
                -- 让 SUM 跳过整条投料腿(fixture 163 D)。
                + CASE WHEN ib.quantity > 0 THEN batch_freight_base_all(ib.id) / ib.quantity ELSE 0 END
                -- PROC-COST-1:第三个成本组件 —— 该批身上已资本化的加工成本
                -- (放电等状态改变型工序留下的)。【不加这一项,成本就走不出去】:
                -- 它是进料批上的资本化成本【唯一】能到达损益表的那条路。
                + CASE WHEN ib.quantity > 0 THEN batch_processing_cost_base_all(ib.id) / ib.quantity ELSE 0 END)), 0),
           COUNT(*) FILTER (WHERE ib.unit_price IS NULL)
      INTO v_material_in, v_inputs_without_price
    FROM processing_inputs pi
    JOIN inbound_batches ib ON ib.id = pi.inbound_batch_id
    WHERE pi.run_id = p_run_id;

    SELECT COALESCE(SUM(pi.quantity_consumed * COALESCE(po_up.unit_cost_base, 0)), 0),
           COUNT(*) FILTER (WHERE po_up.unit_cost_base IS NULL),
           COALESCE(bool_or(po_up.unit_cost_base IS NULL OR po_up.cost_incomplete), false)
      INTO v_material_re, v_re_without_price, v_upstream_incomplete
    FROM processing_inputs pi
    JOIN processing_outputs po_up ON po_up.output_batch_id = pi.output_batch_id
    WHERE pi.run_id = p_run_id;
    v_inputs_without_price := v_inputs_without_price + COALESCE(v_re_without_price, 0);
    v_material := v_material_in + v_material_re;

    -- 5. Process cost = Σ live cost entries.
    SELECT COALESCE(SUM(amount_base), 0) INTO v_process
    FROM processing_cost_entries
    WHERE run_id = p_run_id AND deleted_at IS NULL;

    -- 6. Total.
    v_total := v_material + v_process;

    -- ════════════════════════════════════════════════════════════════════════
    -- PROC-COST-1:【状态改变型 —— 成本资本化回投料批】
    -- 没有产出腿,于是收件人是那批【还在那里的】原料本身。深度放电不产出任何
    -- 新东西:料进去、料出来,只是不带电了 —— 所以它仍然是原料,成本落在 1200。
    -- 【只有加工成本资本化,材料成本【不】动】那批料的价值早就在 1200 上了;
    -- 再借一次 1200 就是拿 1200 对自己重复计数。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT NOT k.produces_outputs INTO v_state_changing
      FROM operation_types ot
      JOIN operation_kinds k ON k.code = ot.kind_code
     WHERE ot.code = v_run.operation_type_code;
    v_state_changing := COALESCE(v_state_changing, false);

    IF v_state_changing THEN
        -- 【拒绝 1】金属价值基准按【产出批的金属含量】拆分,而这里没有产出批。
        -- 那不是"算出来是零",是那个基准在这里根本没有可读的数。
        IF v_basis = 'metal_value' THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_BASIS|%|%', v_run.code, v_basis
              USING HINT = '金属价值基准读的是产出批的金属含量(output_batch_metals),而状态改变型工序没有产出批。按质量(weight)分摊。';
        END IF;

        SELECT count(*) FILTER (WHERE pi.output_batch_id IS NOT NULL),
               count(*) FILTER (WHERE pi.inbound_batch_id IS NOT NULL)
          INTO v_sc_out_inputs, v_sc_in_inputs
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id;

        -- 【拒绝 2】成本载体按 inbound_batch_id 记地址,自产产出批不在那个地址空间里。
        -- **按名拒绝,不许悄悄把成本丢掉** —— 要建这条路,先决定产出批的资本化载体
        -- 是什么(产出批已有 unit_cost_base,那是另一种形状,不是这一张台账)。
        IF v_sc_out_inputs > 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_OUTPUT_INPUT|%|%', v_run.code, v_sc_out_inputs
              USING HINT = '成本载体 batch_processing_cost_allocations 按进料批记地址,自产产出批不在它的地址空间里。这条路要建,先决定产出批的资本化载体是什么 —— 在那之前按名拒绝,而不是悄悄把这笔成本丢掉。';
        END IF;

        -- 【拒绝 3】没有投料批,资本化没有收件人。
        IF v_sc_in_inputs = 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_INPUT|%', v_run.code
              USING HINT = '这张单没有进料批投料,资本化没有收件人。';
        END IF;

        SELECT COALESCE(SUM(pi.quantity_consumed), 0) INTO v_sc_basis_total
          FROM processing_inputs pi
         WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL;
        IF v_sc_basis_total <= 0 THEN
            RAISE EXCEPTION 'ALLOCATION_STATE_CHANGING_NO_BASIS|%', v_run.code
              USING HINT = '投料量合计为零,按质量分摊没有可用的分母。';
        END IF;

        -- 【拒绝 4 与既有路径同一条】资本化分录被人工冲销 → 基准与总账已分道。
        IF v_run.capitalization_entry_id IS NOT NULL THEN
            SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
            IF v_cap_status <> 'posted' THEN
                RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
            END IF;
            -- 【重分摊 = 冲旧 + 重挂,而这在这里是安全的 —— 论证只在这里成立】
            -- FIN-24 禁止转化型这么做,是因为成本已顺着产出批流向已售份额,而已过账
            -- 的 COGS 从不重述。状态改变型【没有产出批】:成本停在 1200 上一批仍然
            -- 是原料的货上,没有任何下游把它当成本消费掉。若那批料后来被一张转化型
            -- 加工单吃掉,那张单会因【第七过期源】而过期,重跑即修正。
            PERFORM reverse_journal_entry_internal(v_run.capitalization_entry_id,
                reversal_date_for(v_run.capitalization_entry_id),
                'Re-allocation ' || v_run.code);
            UPDATE processing_runs
               SET capitalization_entry_id = NULL, capitalized_cost_base = 0
             WHERE id = p_run_id;
        END IF;

        -- ── 台账:先删后插(幂等)。按投料量拆,最大份额吸收进位余数 ────────────
        -- 【零成本不写行 —— 一面为零而举的旗,等于喊狼来了】fu3:载体行是
        -- 第七过期源。一张【一分钱成本都没有】的放电单若也写下载体行,
        -- 它会把吃过那批料的下游单标成过期 —— 而那张单要重跑出来的数
        -- 与它现在的数【一模一样】。本仓库对无条件举旗已有成文处置
        -- (fixture 54:含量没变就不举旗,"没人看的旗和没有旗是同一样东西")。
        -- 【先删仍然无条件执行】:300 → 0 的重分摊必须真的把那一行拿掉。
        DELETE FROM batch_processing_cost_allocations WHERE run_id = p_run_id;

        IF round(v_process, 2) <> 0 THEN
        WITH legs AS (
            SELECT pi.inbound_batch_id AS ib, SUM(pi.quantity_consumed) AS q
              FROM processing_inputs pi
             WHERE pi.run_id = p_run_id AND pi.inbound_batch_id IS NOT NULL
             GROUP BY pi.inbound_batch_id
        ),
        calc AS (
            SELECT ib, q,
                   round(v_process * q / v_sc_basis_total, 2) AS raw,
                   row_number() OVER (ORDER BY q DESC, ib) AS rn
              FROM legs
        ),
        adj AS (
            SELECT c.*, (round(v_process, 2) - SUM(c.raw) OVER ()) AS rem FROM calc c
        )
        INSERT INTO batch_processing_cost_allocations
            (run_id, inbound_batch_id, amount_base, basis_qty, basis_total_qty)
        SELECT p_run_id, ib, raw + CASE WHEN rn = 1 THEN rem ELSE 0 END, q, v_sc_basis_total
          FROM adj;
        END IF;

        SELECT jsonb_agg(jsonb_build_object(
                   'inbound_batch_id', a.inbound_batch_id,
                   'amount_base', a.amount_base,
                   'basis_qty', a.basis_qty)
               ORDER BY a.inbound_batch_id)
          INTO v_sc_rows
          FROM batch_processing_cost_allocations a WHERE a.run_id = p_run_id;

        -- ── 分录:借 1200 / 贷 5xxx —— 【重分类,不是新成本】────────────────────
        -- 电费在录入那一刻就已经进了总账(fin_journal_cost_entry:借 5110 / 贷 2200)。
        -- 这一步不新增任何金额,它把已经在 COGS 里的钱拨进存货。
        v_cap_lines := '[]'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
             ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type),
                    'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF round(v_process, 2) <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object(
                'account_code', '1200',
                'side', CASE WHEN v_process > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(round(v_process, 2)),
                'line_memo', 'capitalised onto input batch — state-changing run')) || v_cap_lines;
            v_cap_je := post_journal_entry(CURRENT_DATE, 'Capitalize ' || v_run.code,
                'allocation', p_run_id, v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        -- 【快照】capitalized_by_source 只列各 cost_type,【故意没有 material 一项】——
        -- 材料没有被资本化(它早就在 1200 上了),写进去会让后来的人以为它进过账。
        v_by_source := '{}'::jsonb;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
              FROM processing_cost_entries
             WHERE run_id = p_run_id AND deleted_at IS NULL
             GROUP BY cost_type
        LOOP
            v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
        END LOOP;

        UPDATE processing_runs
        SET material_cost_base   = round(v_material, 2),
            process_cost_base    = round(v_process, 2),
            total_cost_base      = round(v_total, 2),
            allocation_basis     = v_basis,
            allocation_snapshot  = jsonb_build_object(
                'capitalized_by_source', v_by_source,
                'capitalised_component', 'process_only',
                'capitalised_onto', 'input_batches',
                'destination_account', '1200',
                'basis', v_basis,
                'computed_at', now(),
                'inputs_without_price', v_inputs_without_price,
                'allocations', COALESCE(v_sc_rows, '[]'::jsonb)),
            allocated_at         = now(),
            allocated_by         = v_user,
            capitalized_cost_base   = round(v_process, 2),
            capitalization_entry_id = v_cap_entry_id,
            updated_at           = now(),
            updated_by           = v_user
        WHERE id = p_run_id;

        RETURN jsonb_build_object(
            'run_id', p_run_id,
            'basis', v_basis,
            'state_changing', true,
            'material_cost_base', round(v_material, 2),
            'process_cost_base', round(v_process, 2),
            'total_cost_base', round(v_total, 2),
            'capitalized_cost_base', round(v_process, 2),
            'capitalised_onto', COALESCE(v_sc_rows, '[]'::jsonb),
            'inputs_without_price', v_inputs_without_price,
            'outputs', '[]'::jsonb
        );
    END IF;

    -- 7. Basis totals. Metals without a usable price contribute 0 (LEFT JOIN + COALESCE)
    --    and are recorded in skipped_metals; only a zero grand total blocks (NO_METAL_VALUE).
    IF v_basis = 'metal_value' THEN
        -- METAL-2:分摊【没有交易可以继承指数】—— 一张加工单不是一笔谈定的买卖,
        -- 没有对手方、没有条款,所以它按 pricing_settings 的房屋约定取价。
        -- 【这是默认值在替一条缺席的条款站位,不是"这批成本按某个声明的指数结算了"】。
        -- 快照里一并记下用的是哪个指数,免得日后有人把它读成一条谈定的条款。
        SELECT default_metal_index INTO v_default_index FROM pricing_settings WHERE id;

        SELECT COALESCE(SUM(
                 po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0)
               ), 0)
          INTO v_total_metal_value
        FROM processing_outputs po
        JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
        JOIN substances sx ON sx.code = obm.metal AND sx.role = 'payable_metal'   -- MES-6a-2(Q28):只按含量计价的金属有金属价值
        LEFT JOIN LATERAL (
            SELECT mp.price_usd_per_tonne
            FROM metal_prices mp
            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.price_date <= v_process_date
            ORDER BY mp.price_date DESC
            LIMIT 1
        ) pr ON true
        WHERE po.run_id = p_run_id;

        IF COALESCE(v_total_metal_value, 0) = 0 THEN
            RAISE EXCEPTION 'NO_METAL_VALUE';
        END IF;

        v_total_basis := v_total_metal_value;

        SELECT COALESCE(jsonb_agg(
                   jsonb_build_object('metal', metal,
                                      'price_usd_per_tonne', price_usd_per_tonne,
                                      'price_date', price_date)
                   ORDER BY metal), '[]'::jsonb)
          INTO v_prices_used
        FROM (
            SELECT DISTINCT ON (mp.metal) mp.metal, mp.price_usd_per_tonne, mp.price_date
            FROM metal_prices mp
            WHERE mp.deleted_at IS NULL AND mp.price_date <= v_process_date
              AND mp.price_index IS NOT DISTINCT FROM v_default_index   -- METAL-2
              AND mp.metal IN (
                  SELECT DISTINCT obm.metal
                  FROM processing_outputs po
                  JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
                  JOIN substances sx ON sx.code = obm.metal AND sx.role = 'payable_metal'   -- MES-6a-2(Q28)
                  WHERE po.run_id = p_run_id AND obm.content_pct > 0
              )
            ORDER BY mp.metal, mp.price_date DESC
        ) q;

        -- Metals present (content > 0) on this run with NO usable price row: excluded from
        -- value (they contributed 0 above) and reported in the snapshot as skipped.
        SELECT COALESCE(jsonb_agg(m ORDER BY m), '[]'::jsonb)
          INTO v_skipped_metals
        FROM (
            SELECT DISTINCT obm.metal AS m
            FROM processing_outputs po
            JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
            -- MES-6a-2(Q28):氟、氯没有行情是因为它们【不计价】,不是"缺了一条行情" —— 不进 skipped_metals
            JOIN substances sx ON sx.code = obm.metal AND sx.role = 'payable_metal'
            WHERE po.run_id = p_run_id AND obm.content_pct > 0
              AND NOT EXISTS (
                  SELECT 1 FROM metal_prices mp
                  WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                    AND mp.price_date <= v_process_date
              )
        ) s;
    ELSE
        SELECT COALESCE(SUM(quantity_produced), 0) INTO v_total_basis
        FROM processing_outputs WHERE run_id = p_run_id;
        v_total_metal_value := NULL;
        v_prices_used := '[]'::jsonb;
        v_skipped_metals := '[]'::jsonb;
    END IF;

    -- FIN-24:差额法的"已记录"侧 —— 在下面的 UPDATE 改写之前,把各产出腿
    -- 当前的 allocated 拍下来。目标 − 已记录 = 应过账的差额(与重估/折旧同形)。
    SELECT COALESCE(jsonb_object_agg(po.output_batch_id::text,
                    COALESCE(po.allocated_cost_base, 0)), '{}'::jsonb)
      INTO v_prior
    FROM processing_outputs po WHERE po.run_id = p_run_id;

    -- 8 + 9. Allocate (largest-share row absorbs the rounding remainder), persist legs,
    --        and collect the per-output result — all in one statement.
    WITH legs AS (
        SELECT po.id AS leg_id, po.output_batch_id, po.quantity_produced,
               CASE WHEN v_basis = 'weight' THEN po.quantity_produced::numeric
                    ELSE COALESCE((
                        SELECT SUM(po.quantity_produced * obm.content_pct / 100.0 / 1000.0 * COALESCE(pr.price_usd_per_tonne, 0))
                        FROM output_batch_metals obm
                        JOIN substances sx ON sx.code = obm.metal AND sx.role = 'payable_metal'   -- MES-6a-2(Q28)
                        LEFT JOIN LATERAL (
                            SELECT mp.price_usd_per_tonne
                            FROM metal_prices mp
                            WHERE mp.metal = obm.metal AND mp.deleted_at IS NULL
                              AND mp.price_date <= v_process_date
                            ORDER BY mp.price_date DESC
                            LIMIT 1
                        ) pr ON true
                        WHERE obm.output_batch_id = po.output_batch_id
                    ), 0)
               END AS basis_value
        FROM processing_outputs po
        WHERE po.run_id = p_run_id
    ),
    calc AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               round(v_total * basis_value / NULLIF(v_total_basis, 0), 2) AS alloc_raw,
               row_number() OVER (ORDER BY basis_value DESC, leg_id) AS rn
        FROM legs
    ),
    adj AS (
        SELECT c.*, (round(v_total, 2) - SUM(alloc_raw) OVER ()) AS remainder
        FROM calc c
    ),
    final AS (
        SELECT leg_id, output_batch_id, quantity_produced, basis_value,
               alloc_raw + CASE WHEN rn = 1 THEN remainder ELSE 0 END AS allocated
        FROM adj
    ),
    upd AS (
        UPDATE processing_outputs po
        SET allocated_cost_base = f.allocated,
            unit_cost_base = round(f.allocated / f.quantity_produced, 4)
        FROM final f
        WHERE po.id = f.leg_id
        RETURNING f.output_batch_id, f.basis_value, f.allocated, po.unit_cost_base
    )
    SELECT jsonb_agg(
               jsonb_build_object(
                   'output_batch_id', output_batch_id,
                   'share', round(basis_value / NULLIF(v_total_basis, 0), 6),
                   'allocated_cost_base', allocated,
                   'unit_cost_base', unit_cost_base)
               ORDER BY output_batch_id),
           COALESCE(SUM(allocated), 0)
      INTO v_outputs, v_sum_alloc
    FROM upd;

    -- 9b. Snapshot + run header.
    -- FIN-24:by_source = 本次各来源的入账口径(材料 + 逐 cost_type,各 2 位),
    -- 下一次差额跑的"已记录"就从这里读 —— recorded,不再从分录反推。
    v_by_source := jsonb_build_object('material', round(v_material_in, 2));
    IF round(v_material_re, 2) <> 0 THEN
        -- 再加工材料单列一源:首挂贷 1220(解除上游产出),差额与 material 同贷 5000
        v_by_source := v_by_source || jsonb_build_object('material_reprocessed', round(v_material_re, 2));
    END IF;
    FOR v_ct IN
        SELECT cost_type, round(sum(amount_base), 2) AS amt
        FROM processing_cost_entries
        WHERE run_id = p_run_id AND deleted_at IS NULL
        GROUP BY cost_type
    LOOP
        v_by_source := v_by_source || jsonb_build_object(v_ct.cost_type, v_ct.amt);
    END LOOP;

    v_snapshot := jsonb_build_object(
        'capitalized_by_source', v_by_source,
        'basis', v_basis,
        'computed_at', now(),
        'inputs_without_price', v_inputs_without_price,
        'total_output_metal_value_usd',
            CASE WHEN v_basis = 'metal_value' THEN round(v_total_metal_value, 2) ELSE NULL END,
        'prices_used', v_prices_used,
        -- METAL-2:用的是哪个指数,以及它【是房屋约定而不是条款】。
        -- 读快照的人必须能分清这两件事:这批成本不是"按 LME 结算"的,
        -- 它是"在没有条款可循时,按当时的房屋约定取了 LME 的价"。
        'price_index', v_default_index,
        'price_index_is_house_default', true,
        'skipped_metals', v_skipped_metals
    );

    -- 9c(FIN-25):不完整成本标记 —— 任何投料无价、或上游产出自己就带着标记,
    --    本单全部产出打上 cost_incomplete。零永不静默,层层传染;上游补分摊后
    --    本单过期(状态视图第三支),重跑即清。
    UPDATE processing_outputs
    SET cost_incomplete = (v_inputs_without_price > 0 OR v_upstream_incomplete)
    WHERE run_id = p_run_id;

    -- FIN-36c:告诉基准触发器"这次基准变动是【跟着重分摊一起发生的】,不是漂移"。
    -- 与年结用 evoltrya.close_ctx 穿过期间锁是同一个惯用法(post_journal_entry)。
    -- 【为什么不靠时间戳判断】now() 是事务时间:同一个事务里两次分摊拿到相同的
    -- allocated_at,任何"看 allocated_at 变没变"的判据都会失效(fixture 就在一个
    -- 事务里跑)。显式的上下文标记不受事务边界影响。
    PERFORM set_config('evoltrya.alloc_ctx', '1', true);

    UPDATE processing_runs
    SET material_cost_base   = round(v_material, 2),
        process_cost_base    = round(v_process, 2),
        total_cost_base      = round(v_total, 2),
        allocation_basis    = v_basis,
        allocation_snapshot = v_snapshot,
        allocated_at        = now(),
        allocated_by        = v_user,
        updated_at          = now(),
        updated_by          = v_user
    WHERE id = p_run_id;

    -- 标记只覆盖上面那一条 UPDATE:同一事务里【之后】的裸改基准仍算漂移
    PERFORM set_config('evoltrya.alloc_ctx', '', true);

    -- ════════════════════════════════════════════════════════════════════════
    -- 10a.【FIN-24:首挂全额,此后差额 —— 不再全额冲销重挂】
    -- 旧实现重述资本化(1220 按新价整体改写)而已过账 COGS 从不重述:卖掉份额的
    -- 价差留在库存里,卖得越多错得越多;材料价差贷 1200,而 reprice 早把已耗份额
    -- 记进了 5000 —— 两处叠加 = 重复计数 + 1200 变负(实测:100kg@1 全耗、重定价
    -- 到 2、重分摊 → 1220=200 但 5000 多挂 100、1200=−100)。
    -- 差额法(与重估/折旧同形):目标 − 已记录,只过差额,第二次跑为零。
    --   * 每个产出批按【自己】的处置比例拆(Part B:一炉多批、各卖各的):
    --       在库 + 已售未挂COGS → 1220(后者价值仍躺在 1220,10b 随后按新单位成本解除)
    --       已售已挂COGS       → 5000(COGS 补差)
    --       注销/盘亏           → 5200(处置在产出粒度可知,注销总额是运营信号,
    --                              不并进材料成本 —— Tim 的裁定,推翻了与 reprice
    --                              一致性的论证;reprice 在进料粒度分不出注销与
    --                              耗用、整体进 5000 的不精确,另记 known-issues)
    --   * 贷方:材料差额 → 5000(reprice 把已耗价差停在那里;5000 同时是 COGS
    --     科目,已售份额的借方与之同户恰好互抵 —— 这一巧合是本设计的支点);
    --     费用差额 → 各自成本科目(fin_cost_account)。
    --   * 产出批喂回再加工在 schema 上【不可表示】(processing_inputs 只指
    --     inbound_batches)—— 处置只有在库/已售/注销三种。粉线大概率多段加工,
    --     真建了再加工必须先扩这套拆分(known-issues 有账)。
    -- ════════════════════════════════════════════════════════════════════════
    v_rec_total := COALESCE(v_run.capitalized_cost_base, 0);
    IF v_run.capitalization_entry_id IS NOT NULL THEN
        SELECT status INTO v_cap_status FROM journal_entries WHERE id = v_run.capitalization_entry_id;
        IF v_cap_status <> 'posted' THEN
            -- 资本化分录被人工冲销:存量"已记录"与总账已分道,差额法的基准不再可信。
            -- 这是【唯一】剩下的红色情形:人工冲销是人做的决定,修复也该是人工分录。
            RAISE EXCEPTION 'ALLOCATION_LEDGER_DIVERGED|%', v_run.code;
        END IF;
    END IF;

    IF v_run.capitalization_entry_id IS NULL THEN
        -- ── 首挂:全额资本化(原路径)────────────────────────────────────────
        v_cap_lines := '[]'::jsonb;
        v_cap_total := 0;
        IF round(v_material_in, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1200', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_in, 2));
            v_cap_total := v_cap_total + round(v_material_in, 2);
        END IF;
        -- FIN-25:再加工材料 —— 解除的是上游产出的 1220,不是原料的 1200。
        -- 同科目 Dr(资本化进本单产出)/Cr(解除上游)两腿并存,净额即增量。
        IF round(v_material_re, 2) <> 0 THEN
            v_cap_lines := v_cap_lines || jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', round(v_material_re, 2), 'line_memo', 're-processed input relieved');
            v_cap_total := v_cap_total + round(v_material_re, 2);
        END IF;
        FOR v_ct IN
            SELECT cost_type, round(sum(amount_base), 2) AS amt
            FROM processing_cost_entries
            WHERE run_id = p_run_id AND deleted_at IS NULL
            GROUP BY cost_type
            ORDER BY cost_type
        LOOP
            IF v_ct.amt > 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            ELSIF v_ct.amt < 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object('account_code', fin_cost_account(v_ct.cost_type), 'side', 'debit', 'currency', base_currency_code(), 'amount_ccy', -v_ct.amt);
                v_cap_total := v_cap_total + v_ct.amt;
            END IF;
        END LOOP;

        v_cap_entry_id := NULL;
        IF v_cap_total <> 0 THEN
            v_cap_lines := jsonb_build_array(
                jsonb_build_object('account_code', '1220',
                                   'side', CASE WHEN v_cap_total > 0 THEN 'debit' ELSE 'credit' END,
                                   'currency', base_currency_code(), 'amount_ccy', abs(v_cap_total))
            ) || v_cap_lines;
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Capitalize ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            v_cap_entry_id := (v_cap_je->>'entry_id')::uuid;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = v_cap_total,
            capitalization_entry_id = v_cap_entry_id
        WHERE id = p_run_id;
    ELSE
        -- ── 差额路径 ─────────────────────────────────────────────────────────
        -- 已记录的各来源:优先 snapshot(FIN-24 起写入);老单从已过账的资本化
        -- 分录行反推 —— 1200 行 = 材料,5xxx 行按 fin_cost_account 的反向映射。
        v_rec_src := v_run.allocation_snapshot->'capitalized_by_source';
        IF v_rec_src IS NULL THEN
            SELECT COALESCE(jsonb_object_agg(q.src, q.amt), '{}'::jsonb) INTO v_rec_src FROM (
                SELECT CASE a.code
                           WHEN '1200' THEN 'material'
                           WHEN '5100' THEN 'labour'
                           WHEN '5110' THEN 'electricity'
                           WHEN '5120' THEN 'gas'
                           WHEN '5130' THEN 'depreciation'
                           WHEN '5140' THEN 'consumables'
                           WHEN '5150' THEN 'waste_treatment'
                           WHEN '5190' THEN 'other'
                       END AS src,
                       round(SUM(jl.credit) - SUM(jl.debit), 2) AS amt
                FROM journal_lines jl JOIN accounts a ON a.id = jl.account_id
                WHERE jl.entry_id = v_run.capitalization_entry_id AND a.code <> '1220'
                GROUP BY a.code) q
            WHERE q.src IS NOT NULL;
        END IF;

        -- 贷方:逐来源差额。材料 → 5000(不是 1200!—— reprice 已把已耗价差记在
        -- 5000,这里把属于未售产出的部分从 5000 拨进 1220,双方不再叠加);
        -- 费用 → 各自成本科目。负差翻借方。
        v_cap_lines := '[]'::jsonb;
        v_cred_total := 0;
        FOR v_ct IN
            SELECT key AS src, (v_by_source->>key)::numeric - COALESCE((v_rec_src->>key)::numeric, 0) AS d
            FROM jsonb_object_keys(v_by_source) AS key
            UNION
            SELECT key, 0 - (v_rec_src->>key)::numeric
            FROM jsonb_object_keys(v_rec_src) AS key
            WHERE v_by_source->>key IS NULL
            ORDER BY 1
        LOOP
            IF v_ct.d <> 0 THEN
                v_cap_lines := v_cap_lines || jsonb_build_object(
                    'account_code', CASE WHEN v_ct.src IN ('material', 'material_reprocessed') THEN '5000' ELSE fin_cost_account(v_ct.src) END,
                    'side', CASE WHEN v_ct.d > 0 THEN 'credit' ELSE 'debit' END,
                    'currency', base_currency_code(), 'amount_ccy', abs(v_ct.d),
                    'line_memo', 'allocation delta: ' || v_ct.src);
                v_cred_total := v_cred_total + v_ct.d;
            END IF;
        END LOOP;

        -- 借方:逐产出批的差额,按该批自己的处置比例拆
        FOR v_leg IN
            SELECT po.output_batch_id, po.quantity_produced AS qty,
                   po.allocated_cost_base AS new_alloc,
                   COALESCE((v_prior->>po.output_batch_id::text)::numeric, 0) AS old_alloc,
                   ob.remaining_qty,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NOT NULL), 0) AS sold_cogs,
                   COALESCE((SELECT SUM(sr.quantity) FROM sales_records sr
                             WHERE sr.output_batch_id = po.output_batch_id
                               AND sr.cogs_entry_id IS NULL), 0) AS sold_nocogs,
                   -- FIN-25 第四处置:被下游加工消耗的份额 → 5000 停车
                   --(与 reprice 对已耗进料完全同构:下游过期后重跑,其材料差额
                   -- 贷 5000 收回停车 —— 传导靠既有过期旗逐级走,不递归)
                   COALESCE((SELECT SUM(pi2.quantity_consumed) FROM processing_inputs pi2
                             WHERE pi2.output_batch_id = po.output_batch_id), 0) AS consumed_proc
            FROM processing_outputs po
            JOIN output_batches ob ON ob.id = po.output_batch_id
            WHERE po.run_id = p_run_id
        LOOP
            v_delta := round(v_leg.new_alloc - v_leg.old_alloc, 2);
            IF v_delta = 0 OR v_leg.qty = 0 THEN CONTINUE; END IF;
            v_other := GREATEST(0, v_leg.qty - v_leg.remaining_qty - v_leg.sold_cogs - v_leg.sold_nocogs - v_leg.consumed_proc);
            v_l1220 := round(v_delta * (v_leg.remaining_qty + v_leg.sold_nocogs) / v_leg.qty, 2);
            v_l5000 := round(v_delta * (v_leg.sold_cogs + v_leg.consumed_proc) / v_leg.qty, 2);
            -- 5200 取残差,保证三桶之和恰等于该批差额
            v_d1220 := v_d1220 + v_l1220;
            v_d5000 := v_d5000 + v_l5000;
            v_d5200 := v_d5200 + (v_delta - v_l1220 - v_l5000);
        END LOOP;

        -- 强制配平:Σ借(三桶)与 Σ贷(逐来源)各自取整后可差一两分 ——
        -- 差额并进 1220 桶(金额最大、且是"目标状态"侧,与 8+9 步的
        -- largest-share-absorbs 同一习惯)。
        v_deb_total := v_d1220 + v_d5000 + v_d5200;
        v_d1220 := v_d1220 + round(v_cred_total - v_deb_total, 2);

        IF v_d1220 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '1220',
                'side', CASE WHEN v_d1220 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d1220),
                'line_memo', 'in-stock share')) || v_cap_lines;
        END IF;
        IF v_d5000 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5000',
                'side', CASE WHEN v_d5000 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5000),
                'line_memo', 'sold/consumed share — COGS catch-up / re-processing park')) || v_cap_lines;
        END IF;
        IF v_d5200 <> 0 THEN
            v_cap_lines := jsonb_build_array(jsonb_build_object('account_code', '5200',
                'side', CASE WHEN v_d5200 > 0 THEN 'debit' ELSE 'credit' END,
                'currency', base_currency_code(), 'amount_ccy', abs(v_d5200),
                'line_memo', 'written-off share')) || v_cap_lines;
        END IF;

        -- 幂等出口:没有任何差额 → 不过账(allocated_at 照常刷新,过期标记消除)
        IF jsonb_array_length(v_cap_lines) > 0 THEN
            v_cap_je := post_journal_entry(
                CURRENT_DATE,
                'Re-allocation delta ' || v_run.code,
                'allocation', p_run_id,
                v_cap_lines);
            -- 差额分录记进 snapshot 的留痕数组;capitalization_entry_id 仍指首挂
            v_snapshot := v_snapshot || jsonb_build_object('delta_entry_ids',
                COALESCE(v_run.allocation_snapshot->'delta_entry_ids', '[]'::jsonb)
                    || to_jsonb((v_cap_je->>'entry_id')::text));
            UPDATE processing_runs SET allocation_snapshot = v_snapshot WHERE id = p_run_id;
        END IF;

        UPDATE processing_runs
        SET capitalized_cost_base = round(v_rec_total + v_cred_total, 2)
        WHERE id = p_run_id;
    END IF;

    -- 10b. cut 2a:COGS 补挂 —— 只补此前无 COGS 分录的销售(cogs_entry_id IS NULL),
    --      用最新 unit_cost_base,按各自原 sale_date(撞期间锁则 PERIOD_LOCKED 直接抛出)。
    --      已挂 COGS 不追溯重述(标准成本式简化;重述属人工冲销决策)。
    FOR v_sale IN
        SELECT sr.id, sr.quantity, sr.sale_date, ob.code AS batch_code, po.unit_cost_base
        FROM sales_records sr
        JOIN processing_outputs po ON po.output_batch_id = sr.output_batch_id AND po.run_id = p_run_id
        JOIN output_batches ob ON ob.id = sr.output_batch_id
        WHERE sr.cogs_entry_id IS NULL
        ORDER BY sr.sale_date, sr.created_at
    LOOP
        v_cogs := round(v_sale.quantity * v_sale.unit_cost_base, 2);
        IF v_cogs <> 0 THEN
            v_cogs_je := post_journal_entry(
                v_sale.sale_date,
                'COGS ' || v_sale.batch_code,
                'sale', v_sale.id,
                jsonb_build_array(
                    jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                    jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
            UPDATE sales_records SET cogs_entry_id = (v_cogs_je->>'entry_id')::uuid WHERE id = v_sale.id;
        END IF;
    END LOOP;

    -- 10. Return.
    RETURN jsonb_build_object(
        'run_id', p_run_id,
        'basis', v_basis,
        'material_cost_base', round(v_material, 2),
        'process_cost_base', round(v_process, 2),
        'total_cost_base', round(v_total, 2),
        'inputs_without_price', v_inputs_without_price,
        'outputs', COALESCE(v_outputs, '[]'::jsonb)
    );
END;
$function$;

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1 · M3 · M6)多了三列:
--   view_codes   【任一】即可进(M1)—— 与页面守卫同一组码。一页只认一个码时就是一个元素的数组。
--                warehouse_request:/inventory 那一块(module.inventory.view)与财务(module.finance.view)都读它。
--   root_rule    (AUDIT-TRAIL-1d-1 多了两种:'collection' —— M11,一张表整张是一条记录;'gate:<名字>' —— M12,比表的规则更窄)
--                'table'(默认):根行还要过它自己那张表的读规则,过不了 → TRAIL_NOT_PERMITTED。
--                'page'(M3):页面的码就是门;根行自己的那几次改动照子行的规矩走 —— 读者过不了根表的读规则,
--                那几条就是 Restricted(Q4)。equipment 用它:根表 fixed_assets 只给财务读,而这一页给加工的人。
--   root_columns 非空(M6):根行只取这几列的改动(一块面板只管它自己编辑的那几个字段,Q25 的同一条规矩)。
--                NULL = 整行。1b-3 的三个阈值面板会用到它;本刀先建好,fixture 237 用一个临时主语证它。
-- view_codes 与页面守卫逐字同一组码:
--   purchase_order → /purchasing/orders/[id]        requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id]     requireModule(MOD.processing) = module.processing.view
--   operation_type → /operation/operation-types/[code] requireModule(MOD.processing) = module.processing.view(MES-4a)
--   role           → /settings/roles/[id]           requireManagePermissions()     = action.manage_permissions
--   inbound_batch  → /inbound/[id]/edit             requireModule(MOD.inbound)     = module.inbound.view
--   output_batch   → /output/[id]/edit              requireModule(MOD.output)      = module.output.view
--   work_order     → /operation/orders/[id]         requireModule(MOD.processing)  = module.processing.view
--   stocktake      → /stocktakes/[id]               requireModule(MOD.stocktakes)  = module.stocktakes.view
--   equipment      → /operation/equipment/[id]      requireModule(MOD.processing)  = module.processing.view
--   shift_handover → /operation/handovers/[id]      requireModule(MOD.processing)  = module.processing.view
--   warehouse_request → /inventory 的申请一块        requireModule(MOD.inventory)   = module.inventory.view(+ 财务)
-- AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a 的商务那一半):
--   quote          → /sales/quotes/[id]              requireModule(MOD.sales)       = module.sales.view
--   sales_order    → /sales/orders/[id]              requireModule(MOD.sales)       = module.sales.view
--   shipment       → /sales/shipments/[id]           action.ship_goods,否则 requireModule(MOD.sales)(M1:任一)
--   customer       → /sales/customers/[id]           requireModule(MOD.customers)   = module.customers.view
--   commission_agreement → /sales/commissions/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   supplier       → /suppliers/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   container      → /logistics/containers/[id]      requireModule(MOD.logistics)   = module.logistics.view
--   forwarder      → /logistics/forwarders/[id]      requireModule(MOD.logistics)   = module.logistics.view
--                    根表是 suppliers(读规则 module.suppliers.view)—— M3:页面的码是门,根行自己的改动逐行判
--   lane · port    → /logistics/lanes(只有清单页,按条合起来,见 app/components/trail/ListTrail.tsx)module.logistics.view
--   company_licence → /purchasing/licences(只有清单页)门是 module.purchasing.view,而这张表的读规则是
--                    module.suppliers.view —— 这一块只画在持 suppliers.view 的那一支里(页面本来就那样分),所以登记后者
-- AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a 的主数据与工具):
--   material       → /materials/[id]/edit(只有这一页,Q2)requireModule(MOD.materials) = module.materials.view
--   storage_location → /inventory/locations/[id]/edit(只有这一页)requireModule(MOD.inventory) = module.inventory.view
--   metal_price    → /tools/pricing/metal-prices/[id]/edit(只有这一页)requireEditPermission('action.metal_prices')
--   pricing_formula → /tools/pricing/formulas/[id]/edit(只有这一页)requireModule(MOD.pricing) = module.pricing.view
--   task           → /tools/tasks/[id]                requireModule(MOD.tasks)       = module.tasks.view
--                    私人任务也读得到(Q3):根行要过 tasks 自己的读规则(团队任务 · 自己的 · 或持 module.tasks.view_all)——
--                    那正是"谁打得开这一页"的同一个判据,而遮蔽那一步本来就先问任务隐私
--   processing_settings → /operation/orders 的工单阈值面板          module.processing.view;M6:只取面板编辑的两列
--   pricing_settings    → /tools/pricing/metal-prices 的异常阈值面板  module.pricing.view;M6:只取那一列
--   receiving_settings  → /purchasing/discrepancies 的收货阈值面板   module.inbound.view(面板只画在这一支里);M6:三列
--                    三张都是单行表,主键 id boolean —— M5:页面传 'true',读法按根行自己的类型重建那个键
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第一刀:账上的单据):
--   journal_entry   → /finance/journal/[id]             requireModule(MOD.finance)     = module.finance.view
--   invoice         → /finance/invoices/[id]            requireModule(MOD.finance)     = module.finance.view
--   credit_note     → /finance/credit-notes/[id]        requireModule(MOD.finance)     = module.finance.view
--   payment         → /finance/payments/[id]            requireModule(MOD.finance)     = module.finance.view
--   payment_request → /finance/payment-requests/[id]    requireModule(MOD.finance)     = module.finance.view
--                    (行内转账、代扣税缴纳与它们的冲销也住在这一页 —— 它们没有自己的页,Q17)
--   expense         → /finance/expenses/[id]            requireModule(MOD.finance)     = module.finance.view
--   payable         → /finance/payables/[batchId]       requireModule(MOD.finance)     = module.finance.view
--                    根表是 inbound_batches(读规则 module.inbound.view)—— M3:页面的码是门(Q5,forwarder 的先例);
--                    M6:只取应付那几列(数量、单价、供应商、采购单、计价状态、到货日、注销三列)—— 批次的仓库那一面
--                    (化验、安全状态、库位……)住在 /inbound/[id]/edit 的 inbound_batch 上,不在应付页上再说一遍。
--                    注销那三列必须在里面:M6 丢掉 root_columns 之外的戳(record_trail),不在里面注销就看不见(Q5 的横幅)。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第二刀:其余的单据与合同):
--   sale            → /finance/receivables/[saleId]     requireModule(MOD.finance)     = module.finance.view
--   freight         → /finance/freight/[id]             requireModule(MOD.finance)     = module.finance.view
--                    (根表的读规则是 inbound.view OR finance.view,再加一条 finance.edit 的 ALL —— 页面的码过得了,不需要 M3)
--   fixed_asset     → /finance/assets/[id]              requireModule(MOD.finance)     = module.finance.view
--                    根表与 equipment 同一张 fixed_assets(supplier / forwarder 的先例:一张表两个主语,Q10)——
--                    equipment 的门是加工,这一页的门是财务;根表的读规则就是 finance.view,所以是 'table'
--   bank_statement  → /finance/bank/statements/[id]     requireModule(MOD.finance)     = module.finance.view
--                    删掉的对账单也读得到(Q6:持 data.view_deleted 的人只读打开;根表的读规则不过滤已删的行)
--   gst_period      → /finance/gst/[periodId]           requireModule(MOD.finance)     = module.finance.view
--   fx_rate         → /finance/fx/[id]/edit(只有这一页,Q2)requireModule(MOD.finance) = module.finance.view
--                    撤回了的汇率也读得到(Q7:页面对本来的读者只读打开)
--   management_pack → /finance/packs/[id]               requireModule(MOD.finance)     = module.finance.view
--   contract        → /contracts/[id]                   requireModule(MOD.suppliers)   = module.suppliers.view
--                    根表的读规则按方向:卖方合同要 customers.view、买方合同要 suppliers.view —— 页面在 RLS 下读、读不到就 404,
--                    所以 'table' 与页面同一个答案(看不见的合同对他而言不存在)
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第三刀:期末、设置与清单页上的记录):
--   finance_lock    → /finance/settings 锁期面板之下 · /finance/close 关账史之下(Q25 · Q29)  module.finance.view
--                    根表 finance_settings(单行,id boolean —— M5,页面传 'true');M6:只取 locked_before 一列;
--                    月结 / 反结(period_closes)经 M7 整张表属于这一行(两张表之间一个键都没有,Q3)
--   finance_gst     → /finance/settings GST 面板之下                                       module.finance.view
--                    同一行(M5);M6:只取 gst_registered、gst_registration_no 两列 —— 两块面板各看各的(Q25);
--                    这一行上没有面板的六列(gst_rate_pct · system_start_date · 三个财年列 · default_allocation_basis)
--                    哪一块都不取,只在 /settings/change-history 上找得到(Q4);审批方针那四列归 AT-1d(Q2)
--   company_profile → /finance/company                                                     requireModule(MOD.finance)
--                    单行(M5),整行 —— 一块面板编辑整行;银行那五列按 HISTORY-1 的规则对不持 data.view_banking 的人遮
--   year_close      → /finance/close 年结那一块(清单块,ListTrail)                          module.finance.view
--   journal_request → /finance/journal 每一张申请卡片里(Q17,一张一块)                     module.finance.view
--   expense_claim   → /finance/claims 每一张报销单一块(Q20)                                module.finance.view
--   my_expense_claim → /me 报销人自己那几张(Q20 的另一半)—— ★ M8:没有页面码(view_codes 为空数组),
--                    根行自己那张表的读规则就是门(expense_claims:module.finance.view 或者【这张单说的就是你】);
--                    只许与 'table' 同用(record_trail 里拒绝 'page' —— 那会对每一个人敞开)。
--                    审批留痕那一支(approval_log 的 expense_claim)不给本人开口子,所以本人看到的是 Restricted(Q4)
--   bank_transfer   → /finance/bank 转账那一块(清单块)                                     module.finance.view
--   wht_remittance  → /finance/wht 缴纳那一块(清单块)                                      module.finance.view
--   cash_forecast · cash_forecast_line → /finance/cash-forecast(清单块,Q16:冻结 + 作废旧的一张是一次操作)
--   bank_import_profile → /finance/bank/import(清单块,删掉的也读)                         module.finance.view
--   (重估 / 折旧 / 工资付款 / 加工成本结算的批次与批量汇率【不】另立主语:它们各自的清单块读 journal_entry · expense ·
--    fx_rate 那几个现成主语,Q16 的 op_key 把一次操作并成一条 —— Q18 · Q19)
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第一刀:机制、设置与员工):
--   account         → /settings/accounts 每一行一块(Q24)        requireManagePermissions()     = action.manage_permissions
--                    ★ M9:根表 auth.users 不在 public 里 —— trail_log_only_tables() 给它一份安全投影与声明的读码;
--                    事件(建立 / 停用 / 恢复 / 失败 / 回滚)住在 change_log(record_account_event)
--   approval_policy → /settings/approvals(Q25,1c 的 Q2 挪过来)requireFunction(FN.approvals) = action.manage_permissions
--                    同一行 finance_settings(M5);M6:只取它编辑的四列;修改史 finance_settings_history 经 M7 整张属于这一行。
--                    根表的读规则是 module.finance.view —— 'table':读者两个码都要(线上唯一持 manage_permissions 的 admin 两个都有,Q23)
--   employee        → /hr/employees/[id]                        requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这就是你】—— 与页面同一个答案
--   department      → /hr/departments/[id]/edit(只有这一页)   requireModule(MOD.hr)          = module.hr.view
--   training_record → /hr/training/[id]/edit(只有这一页,Q29) requireModule(MOD.hr)          = module.hr.view
--   import_batch    → /settings/import 的批次一块(清单块,Q24) can('action.bulk_import')      = action.bulk_import
--   dictionary_*    → /settings/dictionaries 每一段一块(Q4)    每一段自己的查看码(registry.ts 的 viewPermission)
--                    ★ M11:'collection' —— 没有根行,那张字典表的每一行、change_log 里它的每一行都属于这一块;根键照写那张表的主键
--                    (code),record_trail 不用它。
--   ☞ M12('gate:reviewer')本刀没有主语用它(它的第一个用户是 AT-1d-3 的 /my-reviews —— 1d-3 已接上,见下面 my_review);fixture 244 用一个临时主语证它。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第二刀:请假与考勤):
--   leave_request     → /hr/leave/[id]                  requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这张单说的就是你】—— 与页面同一个答案
--   my_leave_request  → /me 本人那几张(Q14,M8:没有页面码 —— 根行自己的读规则就是门;审批与消耗那几行对本人是 Restricted)
--   leave_grant       → /hr/leave/grants 那一块(清单块,按年)         module.hr.view
--   leave_types       → /hr/leave/types(M11 集合,根键 code)         module.hr.view
--   public_holidays   → /hr/leave/holidays(M11 集合 —— 假期是【硬删】的,一行删掉之后只剩变更记录里那一份影像)
--   medical_claim     → /hr/claims/[id]                 requireModule(MOD.hr)          = module.hr.view
--   my_medical_claim  → /me 本人那几张(Q14,M8)
--   overtime_batch    → /hr/overtime/[id]               requireFunction(FN.overtime)   = M1:hr.view · overtime_enter · overtime_approve
--                    (与页面守卫、与 overtime_batches 的读规则逐字同一组码)
--   attendance_period → /hr/attendance/[id]             requireModule(MOD.hr)          = module.hr.view
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第三刀:工资与评审):
--   payroll_period      → /hr/payroll/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 hr.view —— 与页面同一个答案;工资行的金额对不持 data.view_pay 的人照遮蔽规则说 Restricted
--   performance_review  → /hr/reviews/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或审核人 或【这是你的、已批】—— 页面读 performance_reviews_masked,
--                      同一个谓词,读不到就 notFound;所以 auditor / finance(hr.view,不持 view_reviews)两边都进不去
--   my_review           → /my-reviews/[id](审核人那一页,没有模块守卫)  M8 + M12:没有页面码,root_rule 'gate:reviewer' ——
--                      根行先过表的读规则,【再】过 trail_root_gate('reviewer'):只给这一份评审点名的审核人,
--                      不给被评审的本人(他在批准之后经"own approved"那一条读得到行,但这一段不是给他的,Q5)
--   review_cycle        → /hr/reviews/cycles 那一块(清单块,每一轮一条)   module.hr.view(Q6:没有成员 —— 开轮时铺下的那几份评审
--                      不挂进来,轮次那一块只说"开了 / 关了";每一份评审自己的那一段以"Annual review opened (cycle …)"开头)
--   review_rating_scale → /hr/reviews/scale(M11 集合,根键 code)      module.hr.view
--   kpi_entry           → /hr/kpi/score 那一块(清单块,选中那一个月的条目;只在 canSeeScores 那一支里画)  module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或本人 —— 不持 view_reviews 的读者在页面那一支就进不来
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
-- MES-1(2026-10-06,MES-1 Step 0 Q21 · Q22,Tim):
--   device          → /operation/devices/[id]           requireModule(MOD.processing) = module.processing.view
--                     成员 gateway_keys(钥匙的发放与撤销;哈希被 never 规则遮住)。收件箱、传输日志与中断不进变更记录(MES-0 Q14),
--                     所以不在这里 —— 设备页把中断单独列成一块(Q21)。
--   ingest_settings → /operation/devices 上的传输上限面板  module.processing.view;单行设置作根(M5),修改史就是变更记录(Q22)
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q31,Tim):
--   electricity_allocation → /finance/electricity/[id]   requireModule(MOD.finance) = module.finance.view
--                     成员 electricity_allocation_lines(一炉一行;它在加工单上也出现,但家在这里)。金额由 change_log_mask_rules 遮(data.view_prices)。
--                     MES-5b-2:成员加 electricity_allocation_reversals(一张单最多一行;它在它覆盖过的每一炉上也出现,家在这里)。
-- MES-5b-3(2026-10-09):
--   blending_plan   → /operation/blending/[id]         requireModule(MOD.processing)  = module.processing.view
--                     成员 blending_plan_targets(目标品位)与 blending_plan_lines(候选批次),都住在这里。没有金额,不遮。
--                     (MES-5b-2 也把 operation_type_output_forms 挂到 operation_type 下 —— V37 的改动从此在工序页自己的审计记录上。)
--   electricity_settings   → /finance/electricity 上的 V25 那一块  module.finance.view;单行设置作根(M5)
-- MES-6a-1(2026-10-09,MES-6a Step 0 Q39):
--   sample          → /quality/samples/[id]          requireFunction(FN.qualitySamples) = module.quality.view
--                     成员 sample_events(保管记录,住在这里)。样品与它的保管记录也出现在它那一批的记录上(进料 / 产出主语,家不在那里)。
--   assay_dispute   → /quality/disputes/[id]         requireFunction(FN.qualityDisputes) = module.quality.view。没有成员;也出现在它那一批的记录上。
--   quality_settings → /quality/samples 上的 V16 那一块   module.quality.view;单行设置作根(electricity_settings 的先例)
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order',    ARRAY['module.purchasing.view'],    'purchase_orders',    'id', 'table', NULL::text[]),
        ('processing_run',    ARRAY['module.processing.view'],    'processing_runs',    'id', 'table', NULL),
        ('role',              ARRAY['action.manage_permissions'], 'roles',              'id', 'table', NULL),
        ('inbound_batch',     ARRAY['module.inbound.view'],       'inbound_batches',    'id', 'table', NULL),
        ('output_batch',      ARRAY['module.output.view'],        'output_batches',     'id', 'table', NULL),
        ('work_order',        ARRAY['module.processing.view'],    'work_orders',        'id', 'table', NULL),
        ('stocktake',         ARRAY['module.stocktakes.view'],    'stocktakes',         'id', 'table', NULL),
        ('equipment',         ARRAY['module.processing.view'],    'fixed_assets',       'id', 'page',  NULL),
        ('shift_handover',    ARRAY['module.processing.view'],    'shift_handovers',    'id', 'table', NULL),
        ('warehouse_request', ARRAY['module.inventory.view', 'module.finance.view'], 'warehouse_requests', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-2
        ('quote',             ARRAY['module.sales.view'],         'quotes',             'id', 'table', NULL),
        ('sales_order',       ARRAY['module.sales.view'],         'sales_orders',       'id', 'table', NULL),
        ('shipment',          ARRAY['module.sales.view', 'action.ship_goods'], 'shipments', 'id', 'table', NULL),
        ('customer',          ARRAY['module.customers.view'],     'customers',          'id', 'table', NULL),
        ('commission_agreement', ARRAY['module.suppliers.view'],  'commission_agreements', 'id', 'table', NULL),
        ('supplier',          ARRAY['module.suppliers.view'],     'suppliers',          'id', 'table', NULL),
        ('container',         ARRAY['module.logistics.view'],     'containers',         'id', 'table', NULL),
        ('forwarder',         ARRAY['module.logistics.view'],     'suppliers',          'id', 'page',  NULL),
        ('lane',              ARRAY['module.logistics.view'],     'lanes',              'id', 'table', NULL),
        ('port',              ARRAY['module.logistics.view'],     'ports',              'id', 'table', NULL),
        ('company_licence',   ARRAY['module.suppliers.view'],     'company_compliance', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-3
        ('material',          ARRAY['module.materials.view'],     'materials',          'id', 'table', NULL),
        ('storage_location',  ARRAY['module.inventory.view'],     'storage_locations',  'id', 'table', NULL),
        ('metal_price',       ARRAY['action.metal_prices'],       'metal_prices',       'id', 'table', NULL),
        ('pricing_formula',   ARRAY['module.pricing.view'],       'pricing_formulas',   'id', 'table', NULL),
        ('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL),
        ('processing_settings', ARRAY['module.processing.view'],  'processing_settings', 'id', 'table',
            ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']),
        ('pricing_settings',  ARRAY['module.pricing.view'],       'pricing_settings',   'id', 'table',
            ARRAY['metal_price_change_warn_pct']),
        ('receiving_settings', ARRAY['module.inbound.view'],      'receiving_settings', 'id', 'table',
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']),
        -- AUDIT-TRAIL-1c-1
        ('journal_entry',     ARRAY['module.finance.view'],       'journal_entries',    'id', 'table', NULL),
        ('invoice',           ARRAY['module.finance.view'],       'invoices',           'id', 'table', NULL),
        ('credit_note',       ARRAY['module.finance.view'],       'credit_notes',       'id', 'table', NULL),
        ('payment',           ARRAY['module.finance.view'],       'payments',           'id', 'table', NULL),
        ('payment_request',   ARRAY['module.finance.view'],       'payment_requests',   'id', 'table', NULL),
        ('expense',           ARRAY['module.finance.view'],       'expenses',           'id', 'table', NULL),
        ('payable',           ARRAY['module.finance.view'],       'inbound_batches',    'id', 'page',
            ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']),
        -- AUDIT-TRAIL-1c-2
        ('sale',              ARRAY['module.finance.view'],       'sales_records',      'id', 'table', NULL),
        ('freight',           ARRAY['module.finance.view'],       'freight_documents',  'id', 'table', NULL),
        ('fixed_asset',       ARRAY['module.finance.view'],       'fixed_assets',       'id', 'table', NULL),
        ('bank_statement',    ARRAY['module.finance.view'],       'bank_statements',    'id', 'table', NULL),
        ('gst_period',        ARRAY['module.finance.view'],       'gst_periods',        'id', 'table', NULL),
        ('fx_rate',           ARRAY['module.finance.view'],       'fx_rates',           'id', 'table', NULL),
        ('management_pack',   ARRAY['module.finance.view'],       'management_packs',   'id', 'table', NULL),
        ('contract',          ARRAY['module.suppliers.view'],     'contracts',          'id', 'table', NULL),
        -- AUDIT-TRAIL-1c-3
        ('finance_lock',      ARRAY['module.finance.view'],       'finance_settings',   'id', 'table', ARRAY['locked_before']),
        ('finance_gst',       ARRAY['module.finance.view'],       'finance_settings',   'id', 'table',
            ARRAY['gst_registered', 'gst_registration_no']),
        ('company_profile',   ARRAY['module.finance.view'],       'company_profile',    'id', 'table', NULL),
        ('year_close',        ARRAY['module.finance.view'],       'year_closes',        'id', 'table', NULL),
        ('journal_request',   ARRAY['module.finance.view'],       'journal_requests',   'id', 'table', NULL),
        ('expense_claim',     ARRAY['module.finance.view'],       'expense_claims',     'id', 'table', NULL),
        ('my_expense_claim',  ARRAY[]::text[],                    'expense_claims',     'id', 'table', NULL),
        ('bank_transfer',     ARRAY['module.finance.view'],       'bank_transfers',     'id', 'table', NULL),
        ('wht_remittance',    ARRAY['module.finance.view'],       'wht_remittances',    'id', 'table', NULL),
        ('cash_forecast',     ARRAY['module.finance.view'],       'cash_forecasts',     'id', 'table', NULL),
        ('cash_forecast_line', ARRAY['module.finance.view'],      'cash_forecast_lines', 'id', 'table', NULL),
        ('bank_import_profile', ARRAY['module.finance.view'],     'bank_import_profiles', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-1
        ('account',           ARRAY['action.manage_permissions'], 'auth.users',         'id', 'table', NULL),
        ('approval_policy',   ARRAY['action.manage_permissions'], 'finance_settings',   'id', 'table',
            ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']),
        ('employee',          ARRAY['module.hr.view'],            'employees',          'id', 'table', NULL),
        ('department',        ARRAY['module.hr.view'],            'departments',        'id', 'table', NULL),
        ('training_record',   ARRAY['module.hr.view'],            'training_records',   'id', 'table', NULL),
        ('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table', NULL),
        ('dictionary_substances',          ARRAY['module.materials.view'], 'substances',             'code', 'collection', NULL),
        ('dictionary_battery_chemistries', ARRAY['module.materials.view'], 'battery_chemistries',    'code', 'collection', NULL),
        ('dictionary_material_kinds',      ARRAY['module.materials.view'], 'material_kinds',         'code', 'collection', NULL),
        ('dictionary_inbound_safety_states', ARRAY['module.materials.view'], 'inbound_safety_states', 'code', 'collection', NULL),
        ('dictionary_laboratories',        ARRAY['module.inbound.view'],   'laboratories',           'code', 'collection', NULL),
        ('dictionary_inbound_source_reasons', ARRAY['module.inbound.view'], 'inbound_source_reasons', 'code', 'collection', NULL),
        -- MES-3a(2026-10-06,MES-3a Step 0 Q4 · Q12):NEA 废物类别字典 —— 与其余六本同一个形状(清单块,/settings/dictionaries)
        ('dictionary_nea_waste_categories', ARRAY['module.materials.view'], 'nea_waste_categories', 'code', 'collection', NULL),
        -- MES-3b(2026-10-07):危险品 UN 编号字典(module.materials.view)· 标签模板字典(module.inventory.view)
        ('dictionary_dangerous_goods_codes', ARRAY['module.materials.view'], 'dangerous_goods_codes', 'code', 'collection', NULL),
        ('dictionary_label_templates',      ARRAY['module.inventory.view'], 'label_templates',       'code', 'collection', NULL),
        -- MES-4a(2026-10-07,MES-4a Step 0 Q33):一道工序 —— 它的参数与指标、挂着的机器、配方与每一版、容差(根行自己那几列);
        --   页面 /operation/operation-types/[code],门 module.processing.view;根键 code(成员按 operation_type_code 挂在它下面)。
        --   异常事件种类字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('operation_type',    ARRAY['module.processing.view'],    'operation_types',    'code', 'table', NULL),
        ('dictionary_processing_event_types', ARRAY['module.processing.view'], 'processing_event_types', 'code', 'collection', NULL),
        --   班次字典 —— MES-4a 把它放进 /settings/dictionaries(新的"时刻"字段:V6 · V7 的去处),于是它也有一段清单块的记录。
        ('dictionary_shifts', ARRAY['module.processing.view'], 'shifts', 'code', 'collection', NULL),
        -- MES-4b(2026-10-07,MES-4b Step 0 Q3 · Q21):电芯结构字典与交叉污染流字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('dictionary_cell_constructions', ARRAY['module.processing.view'], 'cell_constructions', 'code', 'collection', NULL),
        ('dictionary_contamination_streams', ARRAY['module.processing.view'], 'contamination_streams', 'code', 'collection', NULL),
        -- MES-6a-2(2026-10-10,MES-6a Step 0 Q3 · Q39):化验指标字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries;读与那一节同一个码)。
        ('dictionary_assay_indicators', ARRAY['module.materials.view'], 'assay_indicators', 'code', 'collection', NULL),
        -- AUDIT-TRAIL-1d-2
        ('leave_request',     ARRAY['module.hr.view'],            'leave_requests',     'id', 'table', NULL),
        ('my_leave_request',  ARRAY[]::text[],                    'leave_requests',     'id', 'table', NULL),
        ('leave_grant',       ARRAY['module.hr.view'],            'leave_grants',       'id', 'table', NULL),
        ('leave_types',       ARRAY['module.hr.view'],            'leave_types',        'code', 'collection', NULL),
        ('public_holidays',   ARRAY['module.hr.view'],            'public_holidays',    'id', 'collection', NULL),
        ('medical_claim',     ARRAY['module.hr.view'],            'medical_claims',     'id', 'table', NULL),
        ('my_medical_claim',  ARRAY[]::text[],                    'medical_claims',     'id', 'table', NULL),
        ('overtime_batch',    ARRAY['module.hr.view', 'action.overtime_enter', 'action.overtime_approve'], 'overtime_batches', 'id', 'table', NULL),
        ('attendance_period', ARRAY['module.hr.view'],            'attendance_periods', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-3
        ('payroll_period',      ARRAY['module.hr.view'],          'payroll_periods',     'id', 'table', NULL),
        ('performance_review',  ARRAY['module.hr.view'],          'performance_reviews', 'id', 'table', NULL),
        ('my_review',           ARRAY[]::text[],                  'performance_reviews', 'id', 'gate:reviewer', NULL),
        ('review_cycle',        ARRAY['module.hr.view'],          'review_cycles',       'id', 'table', NULL),
        ('review_rating_scale', ARRAY['module.hr.view'],          'review_rating_scale', 'code', 'collection', NULL),
        ('kpi_entry',           ARRAY['module.hr.view'],          'kpi_entries',         'id', 'table', NULL),
        -- MES-1
        ('device',              ARRAY['module.processing.view'],  'devices',             'id', 'table', NULL),
        ('ingest_settings',     ARRAY['module.processing.view'],  'ingest_settings',     'id', 'table', NULL),
        -- MES-2(2026-10-06,MES-2 Step 0 Q33):地磅单 —— 收货或物流查看码任一(与表的读策略逐字同一对,Q22)
        ('weighbridge_ticket',  ARRAY['module.inbound.view', 'module.logistics.view'], 'weighbridge_tickets', 'id', 'table', NULL),
        -- MES-5a-2(2026-10-08,MES-5a Step 0 Q31):一张电费单的分摊(/finance/electricity/[id],财务查看码)· 分摊的设定(V25,单行设置作根)
        ('electricity_allocation', ARRAY['module.finance.view'],  'electricity_allocations', 'id', 'table', NULL),
        ('electricity_settings',   ARRAY['module.finance.view'],  'electricity_settings',    'id', 'table', NULL),
        -- MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划(/operation/blending/[id],加工查看码 —— 与表的读策略同一个)
        ('blending_plan',          ARRAY['module.processing.view'], 'blending_plans',        'id', 'table', NULL),
        -- MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品 · 一件化验争议(质量查看码 —— 页面的门;行再过一次它自己那张表的读规则)·
        --   质量的设定(V16,单行设置作根)
        ('sample',                 ARRAY['module.quality.view'],   'samples',               'id', 'table', NULL),
        ('assay_dispute',          ARRAY['module.quality.view'],   'assay_disputes',        'id', 'table', NULL),
        ('quality_settings',       ARRAY['module.quality.view'],   'quality_settings',      'id', 'table', NULL)
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
$function$;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        -- ── MES-6a-1(2026-10-09,MES-6a Step 0 Q39):一份样品的保管记录住在那份样品下;样品、它的保管记录与化验争议也出现在它们那一批上
        --    (家在样品 / 争议自己那里)。──
        ('sample',             1, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     44, 'samples',                          'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     45, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     46, 'assay_disputes',                   'inbound_batches',              'inbound_batch_id',    '{}'::jsonb, 'down', true, false),
        ('output_batch',      42, 'samples',                          'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('output_batch',      43, 'sample_events',                    'samples',                      'sample_id',           '{}'::jsonb, 'down', true, false),
        ('output_batch',      44, 'assay_disputes',                   'output_batches',               'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-6a-2(2026-10-10,MES-6a Step 0 Q39):一份化验的指标(残粉 · 箔纯度 · 粒径)与它的金属行同一个形状 ——
        --    住在那份化验挂着的那一批下(化验没有自己的主语;它的金属行也是这样挂的)。──
        ('inbound_batch',     47, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true),
        ('output_batch',      45, 'assay_result_indicators',          'assay_results',                'assay_result_id',     '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 5 · 换掉的视图(镜像原样,同列):回收率只算可计价金属 ─────────────────────────────────────

-- db/views/processing_metal_recovery_all.sql
-- AUD-1:processing_metal_recovery 的【无判据基视图】,理由与 batch_lineage_all
-- 逐字相同 —— 属主权限替不了体内那句 has_permission(它按调用者解析)。
-- 【不授权给任何人】;对外读 processing_metal_recovery。
--
-- 语义与拆分前逐字不变:判据是每次调用的常量,挪到外层不影响这里那个
-- 按 run 分区的窗口函数(run_recovery_computable)。
--
-- PROC-WIRE-1B-ii:recovery_blocked_by 多一个取值 output_not_applicable ——
-- 状态改变型工序按定义没有产出腿,说它"产出没测过"会教人去补一份根本不存在的化验。
-- 没有工序类型的单仍然报 output_not_measured(说不出"不适用"的时候不许猜它)。
--
-- NOTE: introduced by db/migrations/2026-08-17-aud1-traceability-report.sql
-- (body lifted verbatim from processing_metal_recovery: REC-1 / PROC-1 / FIN-25 /
--  OPS-14 的全部要点都在那一份的抬头,不在这里重抄一遍).

CREATE OR REPLACE VIEW public.processing_metal_recovery_all AS
 WITH ins AS (
         SELECT pi.run_id,
            m.metal,
            sum(pi.quantity_consumed * m.content_pct / 100.0) AS input_metal_kg,
                CASE
                    WHEN min(COALESCE(m.content_source, 'unknown'::text)) = max(COALESCE(m.content_source, 'unknown'::text)) THEN min(COALESCE(m.content_source, 'unknown'::text))
                    ELSE 'mixed'::text
                END AS input_source
           FROM processing_inputs pi
             JOIN LATERAL ( SELECT ibm.metal,
                    ibm.content_pct,
                    ibm.content_source
                   FROM inbound_batch_metals ibm
                  WHERE ibm.inbound_batch_id = pi.inbound_batch_id
                UNION ALL
                 SELECT obm.metal,
                    obm.content_pct,
                    obm.content_source
                   FROM output_batch_metals obm
                  WHERE obm.output_batch_id = pi.output_batch_id) m ON true
          -- MES-6a-2(MES-6a Step 0 Q28):回收率只算按含量计价的金属 —— 氟、氯是惩罚元素,"回收了多少氟"不是一个要的数
          WHERE EXISTS (SELECT 1 FROM substances s WHERE s.code = m.metal AND s.role = 'payable_metal')
          GROUP BY pi.run_id, m.metal
        ), outs AS (
         SELECT po.run_id,
            obm.metal,
            sum(po.quantity_produced * obm.content_pct / 100.0) AS output_metal_kg,
                CASE
                    WHEN min(obm.content_source) = max(obm.content_source) THEN min(obm.content_source)
                    ELSE 'mixed'::text
                END AS output_source
           FROM processing_outputs po
             JOIN output_batch_metals obm ON obm.output_batch_id = po.output_batch_id
          WHERE EXISTS (SELECT 1 FROM substances s WHERE s.code = obm.metal AND s.role = 'payable_metal')
          GROUP BY po.run_id, obm.metal
        )
 SELECT r.id AS run_id,
    r.code AS run_code,
    r.process_date,
    COALESCE(i.metal, o.metal) AS metal,
    i.input_metal_kg,
    o.output_metal_kg,
    i.metal IS NOT NULL AS input_measured,
    o.metal IS NOT NULL AS output_measured,
        CASE
            WHEN i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric THEN round(o.output_metal_kg / i.input_metal_kg * 100::numeric, 2)
            ELSE NULL::numeric
        END AS recovery_pct,
        CASE
            WHEN i.metal IS NULL THEN 'input_not_measured'::text
            -- ★ PROC-WIRE-1B-ii:【不适用】与【没测】是两句话,两种下一步动作。
            --   状态改变型工序没有产出腿 —— 没有东西可测,不是"忘了测"。
            WHEN o.metal IS NULL AND k.produces_outputs IS FALSE THEN 'output_not_applicable'::text
            WHEN o.metal IS NULL THEN 'output_not_measured'::text
            WHEN i.input_metal_kg = 0::numeric THEN 'input_measured_zero'::text
            ELSE NULL::text
        END AS recovery_blocked_by,
    i.metal IS NOT NULL AND o.metal IS NOT NULL AND o.output_metal_kg > i.input_metal_kg AS conservation_warning,
    bool_or(i.metal IS NOT NULL AND o.metal IS NOT NULL AND i.input_metal_kg > 0::numeric) OVER (PARTITION BY r.id) AS run_recovery_computable,
    i.input_source,
    o.output_source
   FROM ins i
     FULL JOIN outs o ON o.run_id = i.run_id AND o.metal = i.metal
     JOIN processing_runs r ON r.id = COALESCE(i.run_id, o.run_id)
     -- 【两条都 LEFT JOIN】没有工序类型的单(线上 13 张)必须原样走到
     -- output_not_measured —— 说不出"不适用"的时候不许猜它。
     LEFT JOIN operation_types ot ON ot.code = r.operation_type_code
     LEFT JOIN operation_kinds k ON k.code = ot.kind_code
  WHERE r.status = 'committed'::text AND r.deleted_at IS NULL;

COMMENT ON VIEW public.processing_metal_recovery_all IS
    'AUD-1:processing_metal_recovery 的【无判据基视图】,理由与 batch_lineage_all 逐字相同。【不授权给任何人】;对外读 processing_metal_recovery。PROC-WIRE-1B-ii:recovery_blocked_by 多一个取值 output_not_applicable —— 状态改变型工序按定义没有产出腿,说它"产出没测过"会教人去补一份根本不存在的化验。没有工序类型的单仍然报 output_not_measured(说不出"不适用"的时候不许猜它)。';

-- ── 6 · 六支守卫上表(与各自的表镜像逐字同一份)· 惩罚条款的表注释改掉那句过期的「氟与氯不在字典里」 ──────────────────────
CREATE TRIGGER trg_metal_prices_substance_role
    BEFORE INSERT OR UPDATE OF metal ON public.metal_prices
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('payable_metal', 'metal');
CREATE TRIGGER trg_pricing_formula_metals_substance_role
    BEFORE INSERT OR UPDATE OF metal ON public.pricing_formula_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('payable_metal', 'metal');
CREATE TRIGGER trg_pricing_term_commitment_metals_substance_role
    BEFORE INSERT OR UPDATE OF metal ON public.pricing_term_commitment_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('payable_metal', 'metal');
CREATE TRIGGER trg_contract_pricing_terms_substance_role
    BEFORE INSERT OR UPDATE OF metal ON public.contract_pricing_terms
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('payable_metal', 'metal');
CREATE TRIGGER trg_contract_refining_charges_substance_role
    BEFORE INSERT OR UPDATE OF metal ON public.contract_refining_charges
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('payable_metal', 'metal');
CREATE TRIGGER trg_contract_penalty_elements_substance_role
    BEFORE INSERT OR UPDATE OF substance ON public.contract_penalty_elements
    FOR EACH ROW EXECUTE FUNCTION public.guard_substance_role('penalty_element', 'substance');
COMMENT ON TABLE public.contract_penalty_elements IS
    'SETTLE-1:有害元素惩罚 —— **物质 + 阈值 + 费率**,三样都是合同条款,逐物质一行。前置条件(substances 字典)已完成,所以这里挂的是**外键而不是又一列自由文本**(F7:自由文本迟早要变字典,拖延很贵)。★★**费率的形状是【一种】写法,不是唯一一种**★★:本表表达「超过阈值后,每超 1 个百分点、每吨**结算重量**收多少美元」;真实合同还有阶梯、封顶、按批一口价等写法 —— **Tim 没有给条款清单**,所以本刀只建这一种,并把这句话写在这里,好让下一个拿到真合同的人知道该在哪儿加,而不是以为这就是全部。★**惩罚按结算重量收,所以它随湿基/干基变**★(与 RC 相反,RC 按含金属吨数、而含金属是不变量)—— 两条合起来解释了为什么同一批货按湿基与按干基结算出**不同的金额**。★**曾经的具名缺席,已经补上**★:访谈点名的头两个惩罚元素是**氟与氯**;MES-6a-2(2026-10-10)把它们加进了 substances(role = penalty_element),而本表从那一刀起【只】收惩罚元素(守卫 guard_substance_role,别的按名拒 SUBSTANCE_NOT_PENALTY_ELEMENT|<码>)。阈值以 % 记(屏幕上旁带 ppm),费率仍是每超 1 个百分点。';

-- ── 7 · 单据登记的豁免:assay_indicators 有 code 列,但它是一份字典,不是单据(与 db/tables/document_type_exceptions.sql 那一行逐字同一份)──
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('assay_indicators',              '化验指标的目录(MES-6a-2):code 是指标代号(残粉 · 箔纯度 · D10 / D50 / D90),化验的指标行引用它');

-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份;种子在绑定之前,与重建同一个次序)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.assay_indicators
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.assay_indicators
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.assay_result_indicators
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('assay_result_id', 'indicator');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.assay_result_indicators
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 9 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_substance_role() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_substance_role() TO service_role;
REVOKE EXECUTE ON FUNCTION public.guard_substance_role() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.payable_metals_only(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.payable_metals_only(jsonb) TO service_role;
REVOKE EXECUTE ON FUNCTION public.payable_metals_only(jsonb) FROM authenticated;

-- ── 10 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes6a2_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE mes6a2_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

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
    IF (SELECT md5(COALESCE(string_agg((to_jsonb(t) - 'role')::text, '|' ORDER BY (to_jsonb(t) - 'role')::text), '')) FROM substances t WHERE t.code NOT IN ('f', 'cl')) IS DISTINCT FROM (SELECT substances FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM metal_prices t) IS DISTINCT FROM (SELECT metal_prices FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM pricing_formulas t) IS DISTINCT FROM (SELECT pricing_formulas FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM pricing_formula_metals t) IS DISTINCT FROM (SELECT pricing_formula_metals FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM pricing_term_commitments t) IS DISTINCT FROM (SELECT pricing_term_commitments FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM pricing_term_commitment_metals t) IS DISTINCT FROM (SELECT pricing_term_commitment_metals FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contracts t) IS DISTINCT FROM (SELECT contracts FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_pricing_terms t) IS DISTINCT FROM (SELECT contract_pricing_terms FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_refining_charges t) IS DISTINCT FROM (SELECT contract_refining_charges FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_penalty_elements t) IS DISTINCT FROM (SELECT contract_penalty_elements FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_grade_specs t) IS DISTINCT FROM (SELECT contract_grade_specs FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM contract_settlement_terms t) IS DISTINCT FROM (SELECT contract_settlement_terms FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM material_required_metals t) IS DISTINCT FROM (SELECT material_required_metals FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM blending_plan_targets t) IS DISTINCT FROM (SELECT blending_plan_targets FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_results t) IS DISTINCT FROM (SELECT assay_results FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_result_metals t) IS DISTINCT FROM (SELECT assay_result_metals FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batches t) IS DISTINCT FROM (SELECT inbound_batches FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batches t) IS DISTINCT FROM (SELECT output_batches FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM inbound_batch_metals t) IS DISTINCT FROM (SELECT inbound_batch_metals FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM output_batch_metals t) IS DISTINCT FROM (SELECT output_batch_metals FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM receipt_price_requests t) IS DISTINCT FROM (SELECT receipt_price_requests FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM price_history t) IS DISTINCT FROM (SELECT price_history FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT processing_runs FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journal_entries FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_allocations t) IS DISTINCT FROM (SELECT payment_allocations FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM payment_requests t) IS DISTINCT FROM (SELECT payment_requests FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_orders t) IS DISTINCT FROM (SELECT sales_orders FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sales_settlements t) IS DISTINCT FROM (SELECT sales_settlements FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM samples t) IS DISTINCT FROM (SELECT samples FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM sample_events t) IS DISTINCT FROM (SELECT sample_events FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM assay_disputes t) IS DISTINCT FROM (SELECT assay_disputes FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM materials t) IS DISTINCT FROM (SELECT materials FROM mes6a2_rows_before)
       OR (SELECT md5(COALESCE(string_agg((to_jsonb(t))::text, '|' ORDER BY (to_jsonb(t))::text), '')) FROM suppliers t) IS DISTINCT FROM (SELECT suppliers FROM mes6a2_rows_before) THEN
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
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_metal_prices_substance_role' AND tgrelid = 'public.metal_prices'::regclass) OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pricing_formula_metals_substance_role' AND tgrelid = 'public.pricing_formula_metals'::regclass) OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_pricing_term_commitment_metals_substance_role' AND tgrelid = 'public.pricing_term_commitment_metals'::regclass) OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_contract_pricing_terms_substance_role' AND tgrelid = 'public.contract_pricing_terms'::regclass) OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_contract_refining_charges_substance_role' AND tgrelid = 'public.contract_refining_charges'::regclass) OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_contract_penalty_elements_substance_role' AND tgrelid = 'public.contract_penalty_elements'::regclass) THEN
        RAISE EXCEPTION 'MES6A2_PROOF|a substance-role guard is missing';
    END IF;
    IF to_regprocedure('public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid)') IS NOT NULL OR to_regprocedure('public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb)') IS NULL
       OR (SELECT count(*) FROM pg_proc WHERE proname = 'record_assay_result' AND pronamespace = 'public'::regnamespace) <> 1
       OR pg_get_function_arguments('public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb)'::regprocedure) NOT LIKE '%p_indicators jsonb DEFAULT NULL::jsonb'
       OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_assay_result(date, jsonb, text, text, text, boolean, text, uuid, uuid, text, numeric, text, uuid, jsonb)'::regprocedure, 'EXECUTE') THEN
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
    IF has_function_privilege('authenticated', 'public.guard_substance_role()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_substance_role()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A2_PROOF|public.guard_substance_role() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.payable_metals_only(jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.payable_metals_only(jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES6A2_PROOF|public.payable_metals_only(jsonb) must be a function nobody outside can call';
    END IF;
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
