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
    created_by                uuid,
    -- ── FIX-1 追加(ALTER 加的列排在末尾,与 attnum 顺序一致)──────────────
    -- 一个【计划】。可以在未来,不锁任何东西,**没有一条规则读它**(见列注)。
    planned_in_service_date   date
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

COMMENT ON COLUMN public.fixed_assets.planned_in_service_date IS
'FIX-1:【计划】投用日 —— 打算什么时候把它投产。

**它可以在未来。它不锁任何东西,不驱动任何规则,【没有一条规则读它】。**

【为什么要有这一列】Tim 在 in_service_date 上填了 2027-01-01,想记的是
"这条线明年投产"。**那一列装不下这个意思**:每一条规则测的都是
`in_service_date IS NOT NULL`,从不测"是不是已经到了那天"。于是那台机器被当成
【已投用】锁了起来 —— 追加成本被拒、冲销被拒、保养基线从一个负的天数起算 ——
而折旧要等到 2027 才会跑。**每一把锁都锁上了,一分钱折旧都没提。**

【给下一个人的一句话:不要让任何规则读这一列】
它一旦被某条规则读了,就又变回了 in_service_date 那个问题 ——
一个"打算"开始产生"已经发生"才该有的后果。要判断在不在役,读 in_service_date。';

COMMENT ON COLUMN public.fixed_assets.in_service_date IS
'投用日 —— 这台机器【真的开始服役】的那一天。折旧从这一天起算,不从购置日。

**它不可以在未来**(FIX-1,由 guard_asset_in_service_not_future 执行)。
投用是一件【发生过的事】;"打算什么时候投用"是 planned_in_service_date。

【为什么必须分开:FIX-1 之前它们挤在一列里,后果是实测到的】
线上 FA-2026-0001 的这一列曾是 2027-01-01。每一条规则测的都是
`IS NOT NULL`(而不是"到了没有"),于是:
  * record_expense 拒绝再追加成本(资产已"投用");
  * reverse_expense 拒绝冲销;
  * set_asset_in_service 拒绝再设;
  * 而 preview_depreciate_fixed_assets 【是】比日期的,所以折旧要等到 2027。
**锁全上,折旧全无** —— 40 万就那么冻着。

【留空 = 还没投用】那不是"不知道",是一个明确的状态:这台机器还没开始服役。';

-- FIX-1:投用日不许在未来 —— 与停机那一条是同一句话(投用是一件发生过的事)。
-- 【为什么是触发器】fixed_assets 的行会被 UPDATE(状态、成本、投用日),
-- 而 NOT VALID 会把不合规的行冻住(PROC-5 实测,八行物料至今改不动)。
-- 【只看 in_service_date】planned_in_service_date 可以在未来,那是它的全部理由。
CREATE TRIGGER trg_fixed_assets_in_service_not_future
    BEFORE INSERT OR UPDATE ON public.fixed_assets
    FOR EACH ROW EXECUTE FUNCTION public.guard_asset_in_service_not_future();
