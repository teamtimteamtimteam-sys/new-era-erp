-- FIN-35:汇率列不许默认成 1:1
--
-- purchase_orders.fx_rate 带着 DEFAULT 1。那正是 FX 规则花了几切次清掉的 `?? 1`,
-- 只不过这次写成了 schema 的 DEFAULT —— 而 check-currency-literals 看不见它,
-- 因为它找的是币种【代码】,这是一个汇率【数值】。
--
-- 【它是死的,而且有毒 —— 与 OPS-11 对 28 处 'fx_rate', 1 的判词一模一样】
-- 唯一的写入路径 create_purchase_order 从来不吃这个默认值:
--   * 调用方敢传汇率就 RAISE FX_RATE_NOT_ACCEPTED;
--   * 自己去 fx_rate_for(p_currency, p_order_date, 'tt_sell') 取,缺牌价就
--     FX_RATE_MISSING|ccy|date|type 点名拒绝。
-- 所以删掉它【不改变任何现有行为】。留着它的唯一效果是:将来任何一条别的写入路径
-- —— 一次直接 INSERT、一个新函数、一次数据修补 —— 都会静悄悄拿到平价,
-- 而平价在一张非本位币单据上永远是错的,且看起来完全正常。
--
-- 【NOT NULL 留着,当兜底】删掉默认值之后,漏传汇率的 INSERT 会撞 NOT NULL 而失败,
-- 而不是拿到一个编出来的 1。真正带名字的拒绝在上游(FX_RATE_MISSING),
-- 这一层是"没有默认值可拿"的结构保证。
--
-- 【没有加"非本位币不得为 1"的 CHECK,理由要写下来】① CHECK 必须 IMMUTABLE,
-- 读不了 currencies.is_base(AGENTS.md 与 OPS-11 都记过这条);② 更要紧的是
-- PO-2026-0001 那一行【当时是对的】—— 它 2026-07-31 成立,而 FIN-0 把本位币从 USD
-- 换成 SGD 是 2026-08-04,那天以前 USD 单据的 1:1 是【正确的记录】。
-- 加一条今天的约束去追认昨天的历史,就是 db/migrations 被排除在币种扫描之外的同一条道理。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

ALTER TABLE public.purchase_orders ALTER COLUMN fx_rate DROP DEFAULT;

COMMENT ON COLUMN public.purchase_orders.fx_rate IS
    '本单据成立时的折本位币汇率(create_purchase_order 按 order_date 的 tt_sell 取,缺牌价即拒)。【没有默认值,这是有意的 —— FIN-35】:汇率的默认值只能是一个假设,而假设出来的 1:1 在非本位币单据上永远是错的,还看起来完全正常。NOT NULL 是兜底,带名字的拒绝在 fx_rate_for。';

COMMIT;
