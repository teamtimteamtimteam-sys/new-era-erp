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
    -- EQP-1c-a:>= 0 —— 一张还没有成本的卡(create_fixed_asset)记 0。仍禁负数。
    cost_ccy                  numeric NOT NULL CHECK (cost_ccy >= 0),
    currency                  text NOT NULL REFERENCES public.currencies (code),
    fx_rate                   numeric NOT NULL CHECK (fx_rate > 0),
    -- EQP-1c-a:>= 0,同上。这条 CHECK 真正在拦的是【负】成本,那一层没有放松。
    cost_base                 numeric NOT NULL CHECK (cost_base >= 0),
    useful_life_months        integer NOT NULL CHECK (useful_life_months > 0),
    residual_base             numeric NOT NULL DEFAULT 0 CHECK (residual_base >= 0),
    -- EQP-1c-a:带例外,不是放宽 —— 约束注释里写清了两句话各拦什么。
    CONSTRAINT fixed_assets_residual_below_cost
        CHECK (residual_base < cost_base OR (cost_base = 0 AND residual_base = 0)),
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
    -- EQP-1c-a:【可空】—— 由 create_fixed_asset 建出来的卡不是由一笔支出生出来的。
    -- 那条 NOT NULL 此前把"一台资产必须由一笔过账生出来"写死在列上,而设备的
    -- 真实顺序是先下单、后开票。详见列注释。
    expense_id                uuid REFERENCES public.expenses (id),
    notes                     text,
    created_at                timestamptz NOT NULL DEFAULT now(),
    created_by                uuid
);

COMMENT ON TABLE public.fixed_assets IS
    '固定资产台账(FIN-22)。【非货币】:按【购置日】汇率折入本位币并永远停在那里 —— 不重估、不重译。revalue_foreign_balances 扫 is_monetary 科目,1500/1510 都不是;【不要把 1500/1510 加进重估】,fixture 16D 断言这一条。折旧从 in_service_date 起算,不从 acquisition_date。';
COMMENT ON COLUMN public.fixed_assets.fx_rate IS
    '【购置日】的 tt_sell 牌价(record_expense 取的那一个)。资产是非货币项目:这个汇率定格成本,永不重译。';

COMMENT ON COLUMN public.fixed_assets.expense_id IS '生出这张卡的那一笔支出(record_expense 的新建模式)。**可空 —— EQP-1c-a 起。**
【为什么可空】这一列此前是 NOT NULL,它把"一台资产必须由一笔过账生出来"写死在了
列上。而设备的现实顺序是【先下单、后开票】:采购单行要引用一张【已经存在】的
资产卡(EQP-1a),那张卡在发票到来之前就必须存在,那时它还没有任何成本。
create_fixed_asset 建出来的卡因此 expense_id 为 NULL —— 它不是缺数据,
是【这张卡不是由一笔支出生出来的】。
【那条 NOT NULL 此前保证什么、现在还剩什么】它保证"每台资产都追得到一笔过账"。
那条保证被刻意退役了。仍然成立、而且更有用的是另一句:**一台资产的【成本】
永远等于它未冲销成本明细之和**(fixed_asset_cost_entries JOIN expenses,
status = ''posted'')—— fixture 77B 与 reverse_expense 里的
ASSET_COST_LEDGER_DIVERGED 各守一头。成本的可追溯性没有变松,变松的只是
"卡本身从哪来"。
【读它的人要当心】它现在可能是 NULL。/finance/assets 把资产编号做成指向这笔
支出的链接,本刀因此改成:没有出生凭证的卡不画链接。';

COMMENT ON CONSTRAINT fixed_assets_residual_below_cost ON public.fixed_assets IS 'EQP-1c-a:两句话,不是一句。
  * 成本 > 0 时,残值【严格小于】成本 —— 与本刀之前逐字相同(残值 = 成本
    意味着永远提不出折旧,那不是一台在用的机器);
  * 成本 = 0 时(create_fixed_asset 建出来、还没挂上成本的卡),残值【必须也是 0】。
【第二句为什么不能省】它拦的是"趁成本还是 0 的时候先塞一个残值进去,
等成本落下来时它已经高过成本了"。residual_base 全库只有 record_expense 的
新建支写过一次,而那一支会校验 residual < 建卡金额;create_fixed_asset 恒写 0。
两扇门合起来,残值高于成本这件事在任何时刻都不可能出现。';

CREATE INDEX idx_fixed_assets_expense ON public.fixed_assets (expense_id);
CREATE INDEX idx_fixed_assets_status ON public.fixed_assets (status);

ALTER TABLE public.fixed_assets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "fixed_assets select by permission" ON public.fixed_assets
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));
