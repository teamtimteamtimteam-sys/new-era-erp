-- db/tables/index_market_calendar.sql
-- PRICE-1:一个指数【哪几天开市】—— 这套系统里【唯一】能说出"那天市场是关着的"的东西。
--
-- ════════════════════════════════════════════════════════════════════════════
-- ★★【它为什么必须存在,而不是拿 public_holidays 凑合】★★
--
-- §6 第 4 条裁定:计价期均价**只算交易日**。而"只算交易日"要求系统分得开
-- **三个状态**,今天它一个都分不开:
--     ① 那天市场关着     ② 那天有报价     ③ 那天该有报价,但没人录
--
-- 唯一现成的日历是 `public_holidays`,而它**只有新加坡**(实测:14 行,全部
-- country='SG')。`is_business_day(date, country)` 虽然带国别参数,但库里没有
-- 任何非 SG 的行 —— 所以 `is_business_day(d,'GB')` 对**每一个英国银行假日**
-- 都会返回 true,而那是一次**空集造成的假答案**,不是一个答案。
--
-- ★【而拿 SG 日历当代理,失败的方向是错的】★ 这一条是本刀最要紧的判断:
--   · 某天**市场开着、而新加坡放假** → SG 代理说"非工作日" → 那一天被
--     **静悄悄地从均值里剔掉**。均价于是由"它碰巧有的那些天"撑起来 ——
--     **那正是本刀存在的理由要消灭的那个缺陷**(一个会跳过的均值)。
--   · 对比 FX 那条回溯(AGENTS.md 记着的 London/Singapore 近似):它用同一份
--     SG 日历,而**它失败的方向是【拒绝】** —— 英国银行假日会让它多拒一次,
--     保守、且自己会喊出来。
--   **同一份坏日历,在那里买到的是一次多余的拒绝,在这里买到的是一个错的数字。**
--   一个错的数字不会喊,而它会被开成发票。所以这里不用它。
--
-- ★★【为什么每一天都存,而不是只存休市日】★★
--   只存休市日的话,"没有行"就等于"开市" —— 于是一张**还没人加载过的空日历**
--   会宣称**每一天都开市**,而那是一次空集造成的假答案(与上面 is_business_day
--   撞的是同一堵墙)。逐日存下来之后,三个状态才真的分得开:
--     · 有行 + is_trading_day = true   → 那天开市
--     · 有行 + is_trading_day = false  → **那天市场关着**(这一条此前无处可说)
--     · **没有行**                      → **我们不知道那天开不开市** → 均价【按名拒】
--   第三条是重点:**"不知道"必须是一个可以被说出来的状态**,而不是被当成
--   "开市"或"休市"里更方便的那一个。
--
-- ★★【它出厂是【空的】,而那是刻意的】★★
--   本刀**没有**往里灌 LME / SMM 的 2026 年假日 —— 我手上没有权威来源,
--   而编一份出来正是本仓库明令禁止的那件事(把一个待答的问题伪装成已完成的数据)。
--   **今天的实际后果,写在这里而不是留给人发现:在有人加载日历之前,
--   任何一个计价期的均价都会【按名拒】(QP_CALENDAR_NOT_COVERED)。**
--   那是**对的** —— 系统不知道那些天开不开市,所以它说"我不知道",
--   而不是拿它碰巧有的那几天算一个数出来。
--
-- 【它不是"没有写入方的空表"】CONTRACT-1 拒绝预建 contract_pricing_terms,
--   理由是那张表**既没有写入方也没有读者**。这一张**从第一天起就有读者** ——
--   index_period_average 的那条拒绝就读它。一张空的日历不是没人看的表单,
--   它正是让系统说得出"我不知道那天开不开市"的那个机制。
--
-- NOTE: introduced by db/migrations/2026-08-30-price1-index-linked-pricing.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.index_market_calendar (
    index_code     text NOT NULL REFERENCES public.metal_price_indices (code) ON DELETE RESTRICT,
    calendar_date  date NOT NULL,
    -- 【三态里的前两态由这一列区分;第三态是"这一行不存在"】
    is_trading_day boolean NOT NULL,
    -- 休市的理由(春节 / 银行假日 / 交易所公告)—— 写下来,好让下一个人
    -- 判断这份日历是从哪儿来的,而不是相信它。
    note           text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid(),
    PRIMARY KEY (index_code, calendar_date)
);

CREATE INDEX idx_index_market_calendar_trading
    ON public.index_market_calendar (index_code, calendar_date) WHERE is_trading_day;

ALTER TABLE public.index_market_calendar ENABLE ROW LEVEL SECURITY;
-- 【读:任何能看定价的人】市场开不开市不是商业机密,它是公开事实;
-- 而读不到它的人会看到一次 QP_CALENDAR_NOT_COVERED,那读起来像"数据缺了",
-- 不像"你没权限" —— 两者必须分得开(lib/permissions.ts 存在的理由)。
CREATE POLICY "index market calendar select by pricing permission"
    ON public.index_market_calendar AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.pricing.view'::text));
CREATE POLICY "index market calendar write by pricing permission"
    ON public.index_market_calendar AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.pricing.edit'::text))
    WITH CHECK (has_permission('module.pricing.edit'::text));

COMMENT ON TABLE public.index_market_calendar IS
    'PRICE-1:一个指数哪几天开市 —— **这套系统里唯一能说出「那天市场是关着的」的东西**。★**为什么不拿 public_holidays 凑合**★:那份日历只有新加坡(实测 14 行全是 SG),而 is_business_day(date,country) 带国别参数却没有任何非 SG 的行,所以 is_business_day(d,''GB'') 对每一个英国银行假日都返回 true —— 一次**空集造成的假答案**。★★**而拿它当代理,失败的方向是错的**★★:某天市场开着、新加坡放假,SG 代理会把**一个真实的交易日静悄悄从均值里剔掉**,于是均价由"碰巧有的那些天"撑起来 —— 正是本刀要消灭的那个缺陷。对比 FX 那条回溯用同一份 SG 日历:**它失败的方向是【拒绝】**,保守且自己会喊。同一份坏日历,在那里买到一次多余的拒绝,在这里买到一个**错的数字**,而错的数字不会喊、会被开成发票。★**为什么逐日存,不只存休市日**★:只存休市日的话"没有行"就等于"开市",于是一张空日历会宣称每天都开市 —— 同一堵空集的墙。逐日之后三态才分得开:有行+true=开市、有行+false=**关市**、**没有行=我们不知道** → 均价按名拒(QP_CALENDAR_NOT_COVERED)。★**出厂是空的,刻意的**★:本刀没有灌 LME/SMM 的假日,因为手上没有权威来源,而编一份正是把待答问题伪装成已完成数据。**实际后果:在有人加载日历之前,任何计价期均价都会按名拒** —— 那是对的。**它不是「没有写入方的空表」**:CONTRACT-1 拒绝预建 contract_pricing_terms 是因为那张表既无写入方也无读者;这一张**从第一天起就有读者**(那条拒绝就读它)。';

COMMENT ON COLUMN public.index_market_calendar.is_trading_day IS
    'PRICE-1:那天这个市场开不开。**它只区分三态里的前两态** —— 第三态「我们不知道」由**这一行不存在**表示,而那一态会让均价按名拒。所以【不要】给这一列加默认值,也不要用"没有行 = 开市"去省掉半张表:那会把"不知道"悄悄变成"知道",而这正是本表存在的理由。';
