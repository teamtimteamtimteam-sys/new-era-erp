-- db/tables/output_batch_states.sql
-- PROC-WIRE-1A:产出批次的【销售消耗】状态。R5 的结构那一半。
--
-- 【INSTALL SEED,不是 RUNTIME CONFIG】操作员改不动它(没有写策略),而且
-- **加一个销售状态没有意义:没有任何东西会写它** —— 那三个取值是
-- record_output_sale / ship_order 里同一句 `CASE WHEN remaining_qty = 0 …` 算出来的。
-- 所以它在 check_mirrors 的 SEED_TABLES 里逐行比对:线上多一行就是真漂移。
--
-- 【码是中文,这是刻意的】既有存储值就是这三个串,而它们已经流到界面下拉、
-- CSV 导出(机器可读的规范值)、outputQuery 的过滤白名单与两处销售函数里。
-- 本刀是【结构】变更(CHECK → 外键),不是数据变更 —— 换码要动那六个地方。
--
-- NOTE: introduced by db/migrations/2026-08-31-procwire1a-state-dictionary-and-the-processing-earmark.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.output_batch_states (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.output_batch_states IS
'PROC-WIRE-1A:产出批次的【销售消耗】状态。RUNTIME CONFIG,加一种是加一行。

【它【只】回答一个问题:这一批卖掉了多少】不回答"这批货是干什么用的"
(那是 output_batches.purpose_code),也不回答"它合不合格"(G29 的另一半,仍然开着)。

【它由机器写,不由人写】record_output_sale 与 ship_order 两处逐字相同:
`CASE WHEN remaining_qty = 0 THEN 已售罄 ELSE 部分售出 END`。
建批次的界面上那个下拉是唯一的人工入口,而它只在建批次那一刻起作用。

【码是中文,这是刻意的】既有存储值就是这三个串,而它们已经流到界面、
CSV 导出、过滤白名单与两处销售函数里。本刀是结构变更,不是数据变更 ——
换码要动的是那六个地方,那是另一刀的事。

【本表【故意】没有规则列】loss_categories 有 metal_fate/is_true_loss,是因为
那两列【就是那张字典存在的理由】。这里不同:今天关于 state 的每一条行为
都是销售函数从 remaining_qty 【算】出来的,没有一条规则读这张表。
**凭空加一列规则等于替一个没有人裁定过的问题作答** —— 那正是 W2/F4 记过账的
那种污染。要加规则列,等到有一条真的读它的行为出现那天。';

INSERT INTO public.output_batch_states (code, name_en, name_zh, sort_order, notes) VALUES
    ('库存中',   'In stock',      '库存中',   1,
     '一克都还没卖出去。**注意它【不】意味着"这批货可以卖"** —— 可售性由形态(material_forms.may_be_sold)与用途(purpose_code)两条轴回答,不由这一列。'),
    ('部分售出', 'Partially sold', '部分售出', 2,
     '卖掉了一部分,还有余量。由销售函数写入。'),
    ('已售罄',   'Sold out',      '已售罄',   3,
     '**"卖光了",【不是】"没有了"。** 一批被下游工序吃光的投料,remaining_qty 同样归零,但它【不是】这个状态 —— 消耗不碰这一列(commit_processing_run)。这条区别正是本刀不把"工序投料"塞进这条轴的理由:塞进来就得再造一个「已消耗」取值,而那等于用一条销售轴去装一件非销售的事实。');

ALTER TABLE public.output_batch_states ENABLE ROW LEVEL SECURITY;
CREATE POLICY "output_batch_states select all" ON public.output_batch_states
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- 【没有写策略,这是分类的一部分】见抬头:写入只经迁移。
GRANT SELECT ON public.output_batch_states TO authenticated;
