-- db/views/equipment_usage.sql
-- EQP-2a:每台机器【做过什么】—— 从既有的加工记录推导,一个数都不存。
--
-- 【只有公斤,没有小时 —— 这是一个测量结果,不是一个将就】加工这一族里没有
-- 任何开始/结束/班次/工时列(实测:processing_runs 上唯一的世界侧日期是
-- process_date,一个 date;其余全是记账时刻;work_orders 只有 scheduled_date)。
-- 所以运转小时【推导不出来】,而本刀不为了让它可能而加一个时长字段。
-- EQP-2b 的保养间隔因此按公斤走。
--
-- 【口径:读表头,不重算腿】total_input / total_output / loss_qty 是
-- commit_processing_run 从腿上算好写下的;再从腿上算一遍只会造出同一个问题的
-- 第二个答案。实测线上五炉逐一比对,表头与腿的合计完全一致。
--
-- 【不算数的两种炉子】rollback_processing_run 在同一条 UPDATE 里把 status 置为
-- 'reversed' 并写下 deleted_at —— 两个标记同源,所以永远同步。判据两列一起看:
-- 任何一个将来被单独改动,这里都会立刻不一致。实测线上十三炉:
-- committed 且未删 10 条、reversed 且已删 3 条,另外两种组合零条。
--
-- 【LEFT JOIN 是刻意的】没跑过任何一炉的机器也要在,带一排 0;而
-- first/last_run_date 是 NULL —— 那不是零,是"还没有第一次"。
-- 【equipment_id 为空的炉子不在这张视图里】它们没有机器可归。要看它们得另读
-- processing_runs,并按那一列的注释显示成【未归属】这个具名类别。
--
-- 【属主权限 + 两个模块的 OR】机器卡在财务、干活的人在加工,两边都要读得到。
-- 这个 OR 是 AGENTS.md 第 2 条常设决定,batch_margin 里逐字实现着 ——
-- 实测没有哪个业务角色两个都持。
-- NOTE: introduced by db/migrations/2026-08-21-eqp2a-what-the-machine-did.sql.

CREATE VIEW public.equipment_usage WITH (security_invoker = off) AS
 SELECT fa.id AS equipment_id,
    fa.code AS equipment_code,
    fa.description AS equipment_description,
    fa.acquisition_date,
    fa.in_service_date,
    fa.status AS equipment_status,
    count(pr.id) AS run_count,
    COALESCE(sum(pr.total_input), 0::numeric) AS input_kg,
    COALESCE(sum(pr.total_output), 0::numeric) AS output_kg,
    COALESCE(sum(pr.loss_qty), 0::numeric) AS loss_kg,
    min(pr.process_date) AS first_run_date,
    max(pr.process_date) AS last_run_date
   FROM fixed_assets fa
     LEFT JOIN processing_runs pr ON pr.equipment_id = fa.id AND pr.status = 'committed'::text AND pr.deleted_at IS NULL
  WHERE has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text)
  GROUP BY fa.id, fa.code, fa.description, fa.acquisition_date, fa.in_service_date, fa.status;
