-- PROC-COST-1 fu1(2026-08-31):一行成本载体必须指向【它自己那张单的投料批】
--
-- 【为什么这是一道闸,而不是一句注释】
-- 主刀里,载体行只由 allocate_processing_costs 从 processing_inputs 推出来,
-- 所以走那条路【天然】不会挂到外来批次上。但 2b 要的不是"走那条路不会",
-- 而是**"不可能"** —— 而这张表对 authenticated 是可写的(RLS 放 module.processing.edit,
-- 与 freight_allocations 同形)。也就是说今天存在一条路:直接 INSERT 一行,
-- 把一笔加工成本挂到一张【与这张单毫无关系】的进料批上。
--
-- 那样一行不会报任何错,而它的后果恰恰是本仓库最坏的那一种:
-- batch_processing_cost_base 会把它算进那批货的落地成本,那批货进了哪张转化单,
-- 哪张单的产出单位成本就被抬高 —— **每一笔分录都是平的,只是成本落错了货。**
--
-- 【为什么是触发器,不是 CHECK】CHECK 看不见别的表。这条规矩跨两张表
-- (载体行 ↔ processing_inputs),与 FIN-29 那条"付款条款模板的币种"同一形状:
-- 规矩跨表 → 守卫触发器,而且【父子两侧都要】的那一条在这里不适用
-- (processing_inputs 不会在载体行写完之后被删:回滚是软删整张单,而软删之后
-- 基函数本来就不认这一行了)。
--
-- 【按名拒绝】BPCA_BATCH_NOT_AN_INPUT|<run>|<batch> —— 消息里同时给出单与批,
-- 因为读到它的人要回答的正是"那这笔成本该挂到哪张单上"。

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_bpca_batch_is_input()
RETURNS trigger
LANGUAGE plpgsql
AS $function$
DECLARE
    v_run_code   text;
    v_batch_code text;
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM public.processing_inputs pi
         WHERE pi.run_id = NEW.run_id
           AND pi.inbound_batch_id = NEW.inbound_batch_id
    ) THEN
        SELECT code INTO v_run_code   FROM public.processing_runs  WHERE id = NEW.run_id;
        SELECT code INTO v_batch_code FROM public.inbound_batches  WHERE id = NEW.inbound_batch_id;
        RAISE EXCEPTION 'BPCA_BATCH_NOT_AN_INPUT|%|%',
            COALESCE(v_run_code, NEW.run_id::text),
            COALESCE(v_batch_code, NEW.inbound_batch_id::text)
          USING HINT = '一笔加工成本只能资本化到【它自己那张加工单投过的料】身上。挂到别的批次上,成本会跟着那批货走进别人的产出单位成本里,而每一张分录仍然是平的 —— 错的是货,不是账。';
    END IF;
    RETURN NEW;
END;
$function$;

COMMENT ON FUNCTION public.guard_bpca_batch_is_input() IS
    'PROC-COST-1 fu1:一行成本载体必须指向它自己那张单的投料批。走 allocate_processing_costs 天然成立;这道闸挡的是【直接 INSERT】那条路(表对 authenticated 可写)。跨两张表的规矩,CHECK 看不见 —— 所以是触发器。';

CREATE TRIGGER trg_bpca_batch_is_input
    BEFORE INSERT OR UPDATE ON public.batch_processing_cost_allocations
    FOR EACH ROW EXECUTE FUNCTION public.guard_bpca_batch_is_input();

COMMIT;
