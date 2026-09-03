-- PO-GST-1(2026-09-03)· 采购单开始携带税
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【为什么】FA-PO-1 查清了 GST-2 把税放在【费用/发票】那一层,采购单上一列税都没有。
-- 那描述的是【建成了什么】。**Tim 裁定建成的这个是错的。**
-- 采购单是【供应商拿到的那张纸】,它的总额必须是供应商将要开票的那个数;
-- 承诺出去的现金是含税的那一个 —— 否则差 9%。
-- 证据已经在数据里:PO-2026-0008 的取消理由原文就是 "GST not included"。
--
-- 【本刀加什么】
--   ① 一支提取出来的税额原语 tax_amount_for —— 它今天在三处内联,逐字相同。
--   ② purchase_order_lines:tax_code · tax_rate_pct · tax_amount_ccy(【行上】)
--   ③ purchase_orders:tax_total_ccy(= Σ 行税)
--   ④ 两张遮蔽表各自的【列级授权 + _masked 视图】—— 与加列同一支迁移。
--
-- ★★【estimated_total_ccy 保持【净额】,一个字节都不动 —— 这是本刀最要紧的决定】★★
-- 逐处查过,有三样东西挂在这一列上:
--   · 审批级别 approval_level_for(round(estimated_total_ccy * fx_rate, 2))
--     —— approve_purchase_order:52 · reject_purchase_order:34 ·
--        void_approval_on_amount_increase:21-22;
--   · 付款里程碑的百分比 —— 「percentage 是对该 PO 的 estimated_total_ccy 而言」
--     (purchase_order_payment_terms.sql:9 的原话);
--   · 现金预测 —— cash_forecast_data:73 拿它乘百分比。
-- **把它改成含税,这三样会【同时】移位**:审批阈值上下翻越、里程碑金额变大、
-- 预测跳 9%,而且是对【已经存在的单据】。委托书 ④ 明确要求"任何既有单据显示的
-- 总额都不应改变"。所以:净额留在原处,税另立一列,含税在【读的那一侧】相加。
-- **这三样今天仍然按净额走,而那是一个【要 Tim 裁】的问题,不是本刀的默认值** ——
-- 写进 docs/purchase-order-gst.md 的「留给 Tim 的三个决定」。
--
-- 【既有单据怎么办 —— 保守处置】既有 8 张单一列税都没有。本迁移
-- **不回填任何税**:tax_code / tax_rate_pct / tax_amount_ccy / tax_total_ccy
-- 一律留 NULL。**NULL 不是 0** —— 0 是"算过了,结果是零",NULL 是
-- "这张单是在采购单携带税之前开的"。给一张历史单据补一个它当时没有的税额,
-- 是在一张对外单据上编一个数。屏幕与 PDF 对 NULL 说的是一句具名的话,不是 0.00。
--
-- 【无破窗风险的形状】全部是 ADD COLUMN(可空、无默认值)+ GRANT + CREATE OR
-- REPLACE VIEW + CREATE OR REPLACE FUNCTION。没有 UPDATE、没有 NOT NULL、
-- 没有重写表,既有行不被触碰。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ─────────────────────────────────────────────────────────────────────────────
-- ① 税额原语 —— 【提取,不是新写】
--
-- 表达式从 record_expense 逐字符搬来:round(p_amount * v_tax_rate / 100.0, 2)。
-- 同一行今天还有另外两份:create_invoice 与 create_order_invoice:161。
-- 三份逐字相同,而它决定钱 —— TOOLS-1 提取 convert_weight_basis 时用的是同一条
-- 判据(AGENTS.md 记着本仓库为"两份实现"付过四次账)。
--
-- 【为什么取整放在这里,而不是留给调用方】"税额怎么取整"就是这个原语要回答的
-- 全部问题。把 round 留在外面,原语就退化成一次乘法,而三个调用方仍然各自
-- 决定取整 —— 那正是今天的样子。
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION public.tax_amount_for(p_amount numeric, p_rate_pct numeric)
 RETURNS numeric
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 【与 record_expense:256 / create_order_invoice:161 逐字相同】
    SELECT round(p_amount * p_rate_pct / 100.0, 2)
$function$;

COMMENT ON FUNCTION public.tax_amount_for(numeric, numeric) IS
'PO-GST-1:一笔金额按一个税率算出税额,并按【两位小数】取整 —— 全系统唯一的一份。
【它是提取出来的,不是新写的】表达式从 record_expense 逐字符搬来,同一行此前还在
create_invoice 与 create_order_invoice 里各有一份,三份逐字相同。
【取整口径】逐【行】算、逐【行】取整;单据头的税 = Σ 行税,不是 round(Σ 净额 × 税率)。
两种算法差几分,而【对方手里那张纸上印的是行】—— 原话在
create_order_invoice.sql:154,本函数不改变它,只是把它收成一处。';

-- ─────────────────────────────────────────────────────────────────────────────
-- ② 行上的三列。【税码在行上,不在表头】—— 一张单可以混税率:
--    标准税率的货,旁边一条零税率或不在范围内的行,表头一个码说不出这件事。
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.purchase_order_lines
    ADD COLUMN tax_code       text REFERENCES public.tax_codes (code),
    ADD COLUMN tax_rate_pct   numeric,
    ADD COLUMN tax_amount_ccy numeric;

COMMENT ON COLUMN public.purchase_order_lines.tax_code IS
'PO-GST-1:这一行在 GST 上是什么性质 —— 【进项侧】的码(TX/ZP/EP/BL/OP)。
下单时由供应商的 default_tax_code 播下来,经 resolve_tax_code 校验(它同时挡住
挂反了侧别的码);本行可以覆盖。**可空** —— NULL 只出现在两种行上:
本刀之前开的历史行,以及 GST 未注册时开的行。NULL【不是】"零税",
两者在 F5 上完全不同,而屏幕与 PDF 对它们说的是两句不同的话。';

COMMENT ON COLUMN public.purchase_order_lines.tax_rate_pct IS
'PO-GST-1:【下单那一天】这个税码的税率,冻在行上。
★ 为什么存下来而不是读的时候再算 ★ 税率会变 —— 新加坡 7% → 8% → 9%,
tax_rates 上三段生效期间都还在。拿今天的税率去重算一张 2023 年的单,
得到的是一个【历史上从未存在过】的数字。本仓库到处分"当时是多少"与"现在是多少"
(资产按购置日汇率定格、化验按报价期均价),税不给豁免。';

COMMENT ON COLUMN public.purchase_order_lines.tax_amount_ccy IS
'PO-GST-1:这一行的税额,以【单据币种】计,tax_amount_for 逐行取整两位小数。
表头的 tax_total_ccy = Σ 本列。**敏感列**(它是从价格推出来的钱):
随 data.view_prices 遮蔽,与 estimated_amount_ccy 同一扇门。';

-- 【遮蔽表加列 = 三件事】ADD COLUMN + 列级授权 + _masked 视图,少一件就
-- "写得进、读不出",而且【一个字的报错都不会有】(purchase_order_lines.sql
-- 抬头记着 PROC-1B-iii 主迁移漏掉后两件、由 fu1 补上那一次)。
--
-- tax_code 与 tax_rate_pct 【不敏感】:一个是分类,一个是法定税率,都不是钱。
-- tax_amount_ccy 【敏感】:它是钱,而且从被扣住的净额推得出来。
GRANT SELECT (tax_code, tax_rate_pct) ON public.purchase_order_lines TO authenticated;

CREATE OR REPLACE VIEW public.purchase_order_lines_masked WITH (security_invoker = off) AS
 SELECT id,
    purchase_order_id,
    line_no,
    material_id,
    quantity,
    unit,
    pricing_formula_id,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_unit_price
            ELSE NULL::numeric
        END AS estimated_unit_price,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_amount_ccy
            ELSE NULL::numeric
        END AS estimated_amount_ccy,
    expected_assay,
    notes,
    created_at,
    created_by,
    price_source,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN price_provenance
            ELSE NULL::jsonb
        END AS price_provenance,
    asset_id,
    deep_discharge_judgement_code,
    -- PO-GST-1:税码与税率原样透出(分类与法定税率,不是钱);
    -- 税【额】随 data.view_prices,与 estimated_amount_ccy 同一扇门。
    tax_code,
    tax_rate_pct,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_amount_ccy
            ELSE NULL::numeric
        END AS tax_amount_ccy
   FROM purchase_order_lines
  WHERE has_permission('module.purchasing.view'::text);

-- ─────────────────────────────────────────────────────────────────────────────
-- ③ 表头的税额合计。**净额那一列不动。**
-- ─────────────────────────────────────────────────────────────────────────────
ALTER TABLE public.purchase_orders
    ADD COLUMN tax_total_ccy numeric;

COMMENT ON COLUMN public.purchase_orders.tax_total_ccy IS
'PO-GST-1:这张单的税额合计,单据币种,= Σ 行 tax_amount_ccy(逐行取整后相加)。
★【estimated_total_ccy 仍然是【净额】,本刀一个字节都没动它】★ 三样东西挂在那一列上:
审批级别(approval_level_for)、付款里程碑的百分比、现金预测。把那一列改成含税,
三样会同时对【既有单据】移位。含税额 = estimated_total_ccy + COALESCE(tax_total_ccy, 0),
在读的那一侧相加。**可空**:NULL = 这张单开在本刀之前,或 GST 未注册 —— 不是零税。';

GRANT SELECT (tax_total_ccy) ON public.purchase_orders TO authenticated;

CREATE OR REPLACE VIEW public.purchase_orders_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    supplier_id,
    order_date,
    expected_delivery_date,
    currency,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN fx_rate
            ELSE NULL::numeric
        END AS fx_rate,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN estimated_total_ccy
            ELSE NULL::numeric
        END AS estimated_total_ccy,
    status,
    approval_status,
    approved_at,
    approved_by,
    incoterm,
    terms_text,
    notes,
    closed_at,
    cancelled_at,
    cancel_reason,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    deleted_by,
    delete_reason,
    cancelled_by,
    contract_id,
    -- PO-GST-1:税额是钱 —— 与 estimated_total_ccy 同一扇门。
        CASE
            WHEN has_permission('data.view_prices'::text) THEN tax_total_ccy
            ELSE NULL::numeric
        END AS tax_total_ccy
   FROM purchase_orders
  WHERE has_permission('module.purchasing.view'::text);

COMMIT;
