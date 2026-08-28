-- db/tables/fixed_asset_cost_entries.sql
-- FA-1a:一台资产的成本【由哪几笔构成】—— 购置那一笔,加上运费/关税/安装调试。
--
-- NOTE: introduced by db/migrations/2026-08-16-fa1a-commissioning-and-the-lock-gate.sql.
-- First-run script (plain CREATEs).
--
-- 【投用【不再】冻结成本 —— CAPEX-1,2026-08-29,原文写的是"投用即冻结"】
-- 旧规矩:in_service_date 一有值,record_expense 就一律拒绝追加
-- (ASSET_ALREADY_IN_SERVICE)。它护住的两件事仍然成立,只是护法换了:
--   ① 已提各期会全错 —— 现在由【折旧锚点】结构性地防住
--      (fixed_asset_depreciation_anchors:锚点之前那一段是一个存下来的常数,
--       新成本乘不到它身上),而不是靠"不许加钱";
--   ② 投用后的支出是一次会计判断 —— 这一条【原样保留】,只是判断现在有地方写了:
--      必须先有一条标了资本化并写明理由的 equipment_maintenance 记录
--      (政策 4.7)。没有它,record_expense 仍然按名拒
--      (ASSET_IN_SERVICE_NEEDS_MAINTENANCE),并且指路。
-- 于是本表在【投用之后】也会长出行来,来源列 expense_id 指着那笔资本化支出。
-- 写入只经 record_expense 的资本分支;本表【没有 INSERT/UPDATE 策略】。

CREATE TABLE public.fixed_asset_cost_entries (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    asset_id     uuid NOT NULL REFERENCES public.fixed_assets (id) ON DELETE RESTRICT,
    -- 每一笔都来自一张资本性支出单 —— 资产不脱离它的应付/付款存在(FIN-22 的规矩)
    expense_id   uuid NOT NULL REFERENCES public.expenses (id),
    -- 三件套:这一笔自己的原币、自己那天的汇率、折出来的本位币额
    amount_ccy   numeric NOT NULL CHECK (amount_ccy > 0),
    currency     text    NOT NULL REFERENCES public.currencies (code),
    fx_rate      numeric NOT NULL CHECK (fx_rate > 0),
    amount_base  numeric NOT NULL CHECK (amount_base > 0),
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid,
    -- 一张支出单只能进一次(重复调用会被它挡住,而不是把成本加两遍)
    CONSTRAINT fixed_asset_cost_entries_one_per_expense UNIQUE (expense_id)
);

COMMENT ON TABLE public.fixed_asset_cost_entries IS
    'FA-1a:一台资产的成本【由哪几笔构成】。购置那一笔也在里面 —— 否则第一笔要查 expenses、后续几笔要查这里,两处读法迟早各说各话。每一笔带自己的汇率:进口机器按购置日折算、本地运费按运费日折算,两笔的原币可以不同、汇率一定不同。fixed_assets 表头那三列是【第一笔】的,cost_base 是这张表的合计。';

CREATE INDEX idx_fixed_asset_cost_entries_asset ON public.fixed_asset_cost_entries (asset_id);

ALTER TABLE public.fixed_asset_cost_entries ENABLE ROW LEVEL SECURITY;
-- 读 module.finance.view(与 fixed_assets 同一扇门);写只经 record_expense。
CREATE POLICY "fixed_asset_cost_entries select by permission" ON public.fixed_asset_cost_entries
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.finance.view'::text));
