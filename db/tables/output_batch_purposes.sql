-- db/tables/output_batch_purposes.sql
-- PROC-WIRE-1A:这一【批】货是干什么用的 —— 可售库存,还是下游工序的投料。
--
-- 【RUNTIME CONFIG,加一种是加一行】第四条拒绝(SALE_BATCH_EARMARKED)读的是
-- is_saleable_stock 那一列,不是某个写死的码 —— 所以多一种不可售用途不必改代码。
-- 与同刀的 output_batch_states 分属两类,那不是随手放的:那一张操作员改不动
-- (加一个销售状态没有东西会写它),这一张改得动。
--
-- NOTE: introduced by db/migrations/2026-08-31-procwire1a-state-dictionary-and-the-processing-earmark.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.output_batch_purposes (
    code              text PRIMARY KEY,
    name_en           text NOT NULL,
    name_zh           text NOT NULL,
    -- 【规则列】这个用途下的批次算不算【可售库存】。**这一列就是这张字典存在的理由**,
    -- 而且它是四条拒绝里第四条唯一读的东西 —— 加一个不可售的新用途是加一行,不是改代码。
    is_saleable_stock boolean NOT NULL,
    is_active         boolean NOT NULL DEFAULT true,
    sort_order        integer NOT NULL DEFAULT 0,
    notes             text
);

COMMENT ON TABLE public.output_batch_purposes IS
'PROC-WIRE-1A:这一【批】货是干什么用的。RUNTIME CONFIG,加一种是加一行。

【为什么它必须是【批次级】,而不是挂在形态上】可售性里"这东西本身许不许卖"
那一半,PROC-BUILD-1 已经挂在形态上了(material_forms.may_be_sold,法律说的是
这个东西物理上是什么)。**剩下的那一半挂不上去**:cathode_sheet 的种子注释
自己写着「它可以进极片粉料线,也可以卖」——【同一个形态,两种角色】,
而角色是这一批的事,不是这个物质的事。

【它与 state 是两条轴,不许合并】state 答"卖掉了多少",本列答"这批是干什么的"。
一批被工序吃光的投料 remaining_qty 归零而【不是】已售罄 —— 合成一条轴就必须
凭空造一个「已消耗」销售取值,那会认下一笔从来没发生过的收入。

【G29 的质量暂扣是【第三】条轴,同样不许并进来】一批货可以既是可售库存、
又在质量暂扣上;也可以既是工序投料、又不合格。三条轴可以同时为真。
G29 仍然开着,依赖它的两处:known-issues.md:3547、contract1-handover.md:186。';

COMMENT ON COLUMN public.output_batch_purposes.is_saleable_stock IS
'PROC-WIRE-1A:这个用途下的批次算不算可售库存。**false 的那些不是"不许卖的东西",
是"这一批已经许给下游工序了"** —— 区别在于前者没有旁路,后者【释放指定即可】。
第四条拒绝(SALE_BATCH_EARMARKED)只读这一列,所以将来多一种不可售用途是加一行。';

INSERT INTO public.output_batch_purposes (code, name_en, name_zh, is_saleable_stock, sort_order, notes) VALUES
    ('saleable_stock', 'Saleable stock', '可售库存', true, 1,
     '默认。今天线上每一批都是这一种,而这正是本列敢给默认值的理由 —— 它是【现状】,不是一个猜测。'),
    ('process_feed',   'Feed for a downstream operation', '下游工序投料', false, 2,
     '【本刀的那一行】这一批被指定成下游工序的投料,所以它不是可售库存。**它【不】说这个东西不许卖** —— 正极片就是可售的(may_be_sold = true),它只是这一批已经许给了粉料线。要卖它,把指定释放掉即可,这正是它与 SALE_FORM_NOT_SALEABLE 的分界:那一条没有旁路,这一条有。');

ALTER TABLE public.output_batch_purposes ENABLE ROW LEVEL SECURITY;
CREATE POLICY "output_batch_purposes select all" ON public.output_batch_purposes
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "output_batch_purposes write by permission" ON public.output_batch_purposes
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.output_batch_purposes TO authenticated;
