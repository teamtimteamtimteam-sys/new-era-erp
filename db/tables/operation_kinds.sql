-- db/tables/operation_kinds.sql
-- PROC-WIRE-1B-i:一道工序【属于哪一类】。两条规则列驱动 commit_processing_run 的分支。
--
-- 【INSTALL SEED,不是 RUNTIME CONFIG】没有写策略:加一种工序【种类】不是加一行数据 ——
-- 运行时要先懂得它意味着什么(吃不吃料、产不产批),那是代码的事。
-- NOTE: introduced by db/migrations/2026-08-31-procwire1bi-operations-wired-and-the-discharge-deadlock.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.operation_kinds (
    code             text PRIMARY KEY,
    name_en          text NOT NULL,
    name_zh          text NOT NULL,
    -- 【规则列 ①】这一类工序【吃不吃】投料。false = 料穿过去,库存不动。
    consumes_input   boolean NOT NULL,
    -- 【规则列 ②】这一类工序【产不产】新批次。false = 没有产出腿,而那【不是】
    -- "忘了填",是这一类工序的定义(R3:同一批进、同一批出,只改状态)。
    produces_outputs boolean NOT NULL,
    is_active        boolean NOT NULL DEFAULT true,
    sort_order       integer NOT NULL DEFAULT 0,
    notes            text
);

COMMENT ON TABLE public.operation_kinds IS
'PROC-WIRE-1B-i:一道工序【属于哪一类】。RUNTIME CONFIG,加一种是加一行。

【两条规则列就是它存在的全部理由】commit_processing_run 的分支【读这两列】,
不读一个写死的字符串。于是"这道工序吃不吃料、产不产批"是【数据】回答的 ——
与 output_batch_purposes.is_saleable_stock 同一条。

【为什么两列而不是一列】它们今天完全相关(转化=吃且产,状态改变=不吃不产),
但概念上独立:一道"只吃不产"的工序是【纯销毁】,而"只产不吃"是不可能的。
把它们合成一列,等于断言那个巧合是一条定律。';

INSERT INTO public.operation_kinds (code, name_en, name_zh, consumes_input, produces_outputs, sort_order, notes) VALUES
    ('transforming', 'Transforming', '转化型', true, true, 1,
     '料被吃掉,变成一批或几批新东西。今天线上 13 张加工单全部是这一类(虽然它们还没有工序类型)。'),
    ('state_changing', 'State-changing', '状态改变型', false, false, 2,
     '【R3】同一批进、同一批出,只改状态,不产新批。**料【穿过】工序,库存一克不动** —— 深度放电就是这一种。它没有产出腿,而那不是"忘了填"。');

ALTER TABLE public.operation_kinds ENABLE ROW LEVEL SECURITY;
CREATE POLICY "operation_kinds select all" ON public.operation_kinds
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- 【没有写策略,这是分类的一部分】写入只经迁移。
GRANT SELECT ON public.operation_kinds TO authenticated;
