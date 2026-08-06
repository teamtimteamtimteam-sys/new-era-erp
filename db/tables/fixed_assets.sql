-- db/tables/fixed_assets.sql
-- 固定资产台账(FIN-22)。【非货币】:按【购置日】汇率折入本位币并永远停在那里 ——
-- 不重估、不重译;revalue_foreign_balances 扫 is_monetary 科目,1500/1510 都不是,
-- 【不要把它们加进重估】(fixture 16D 断言)。折旧从 in_service_date 起算。
-- 创建入口只有一个:record_expense 的资本分支(科目 1500 ↔ p_asset 互相要求),
-- 资产不脱离其应付/付款存在。写入只经 SECURITY DEFINER 函数;无 INSERT/UPDATE 策略。
--
-- NOTE: introduced by db/migrations/2026-08-06-fin22-fixed-assets-and-depreciation.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.fixed_assets (
    id                        uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                      text NOT NULL UNIQUE,
    description               text NOT NULL,
    category                  text NOT NULL DEFAULT 'equipment'
                              CHECK (category IN ('equipment','vehicle','office','other')),
    -- 购置日 ≠ 在役日,两个都要:折旧从【在役日】起算,不从购置日
    acquisition_date          date NOT NULL,
    in_service_date           date,
    CONSTRAINT fixed_assets_service_after_acquisition
        CHECK (in_service_date IS NULL OR in_service_date >= acquisition_date),
    -- 成本:原币 + 购置日汇率 + 本位币。粉线设备是进口的,cost 会是 USD ——
    -- 按【购置日】牌价折入,之后永远停在那里。
    cost_ccy                  numeric NOT NULL CHECK (cost_ccy > 0),
    currency                  text NOT NULL REFERENCES public.currencies (code),
    fx_rate                   numeric NOT NULL CHECK (fx_rate > 0),
    cost_base                 numeric NOT NULL CHECK (cost_base > 0),
    useful_life_months        integer NOT NULL CHECK (useful_life_months > 0),
    residual_base             numeric NOT NULL DEFAULT 0 CHECK (residual_base >= 0),
    CONSTRAINT fixed_assets_residual_below_cost CHECK (residual_base < cost_base),
    -- 折旧落点:默认 6700。【不要指 5130 除非想清楚了】—— 5130 由
    -- processing_cost_entries 的 depreciation 条目喂、经分摊进批次成本;台账直接
    -- 过账到 5130 会绕开分摊,且与人工条目【重复计提】。指过去的资产必须停掉
    -- 对应的人工月度条目。
    depreciation_account_code text NOT NULL DEFAULT '6700' REFERENCES public.accounts (code),
    status                    text NOT NULL DEFAULT 'active' CHECK (status IN ('active','disposed')),
    disposal_date             date,
    disposal_proceeds_base    numeric,
    disposal_journal_id       uuid REFERENCES public.journal_entries (id),
    CONSTRAINT fixed_assets_disposal_fields CHECK (
        (status = 'active'   AND disposal_date IS NULL AND disposal_journal_id IS NULL)
     OR (status = 'disposed' AND disposal_date IS NOT NULL)
    ),
    -- 资本性支出单(创建入口;资产不脱离应付存在)
    expense_id                uuid NOT NULL REFERENCES public.expenses (id),
    notes                     text,
    created_at                timestamptz NOT NULL DEFAULT now(),
    created_by                uuid
);

COMMENT ON TABLE public.fixed_assets IS
    '固定资产台账(FIN-22)。【非货币】:按【购置日】汇率折入本位币并永远停在那里 —— 不重估、不重译。revalue_foreign_balances 扫 is_monetary 科目,1500/1510 都不是;【不要把 1500/1510 加进重估】,fixture 16D 断言这一条。折旧从 in_service_date 起算,不从 acquisition_date。';
COMMENT ON COLUMN public.fixed_assets.fx_rate IS
    '【购置日】的 tt_sell 牌价(record_expense 取的那一个)。资产是非货币项目:这个汇率定格成本,永不重译。';

CREATE INDEX idx_fixed_assets_expense ON public.fixed_assets (expense_id);
CREATE INDEX idx_fixed_assets_status ON public.fixed_assets (status);

ALTER TABLE public.fixed_assets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fixed_assets select by permission" ON public.fixed_assets
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
