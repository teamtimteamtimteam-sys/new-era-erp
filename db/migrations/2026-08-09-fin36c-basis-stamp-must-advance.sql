-- FIN-36c:基准变更的时点必须【走得动】,而且重分摊不能把自己标成过期
--
-- FIN-36 的第一版用 now() 盖 allocation_basis_changed_at,撞上了 fixture 32 撞过的
-- 同一堵墙:now() 是【事务时间】,同一个事务里的两次写拿到同一个值。于是
--   * 一次裸 UPDATE ... SET allocation_basis 与它之前的 allocated_at 时点相等,
--     而 is_stale 用的是严格大于 → 【改了基准却不算过期】,正是本切要抓的那种;
--   * 反过来,如果改用会走动的时钟,allocate_processing_costs 在同一条 UPDATE 里
--     既改基准又写 allocated_at,基准时点会晚一点点 → 【刚分摊完就自称过期】。
--
-- 两个毛病要一起解,分成两件事:
--   1. 时点改用 clock_timestamp() —— 它在事务内也走,所以"先分摊、后改基准"这个
--      顺序在任何事务边界下都分得开(fixture 就是在一个事务里跑的)。
--   2. 触发器只在【基准变了而 allocated_at 没变】时才盖章。语义正好是要表达的那句:
--      【跟着重分摊一起发生的基准变更不是漂移;单独发生的才是。】
--      allocate_processing_costs 在同一条 UPDATE 里两个都改 → 不盖章 → 不自标过期。
--
-- NOTE: apply with ./db/apply_migration.sh

BEGIN;

CREATE OR REPLACE FUNCTION public.stamp_allocation_basis_changed()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    -- clock_timestamp() 而不是 now():now() 是事务时间,事务内两次写相等,
    -- 于是"分摊完之后又改了基准"与"分摊时顺手改的"分不开(fixture 32 的 seq 是
    -- 同一课的另一面)。触发条件已经把"跟着重分摊一起改"排除在外了。
    NEW.allocation_basis_changed_at := clock_timestamp();
    RETURN NEW;
END;
$function$;

DROP TRIGGER trg_processing_runs_basis_changed ON public.processing_runs;

-- 【只在基准单独变动时盖章】跟着重分摊一起改的不算漂移 —— allocate_processing_costs
-- 在同一条 UPDATE 里同时写 allocation_basis 与 allocated_at。
CREATE TRIGGER trg_processing_runs_basis_changed
    BEFORE UPDATE OF allocation_basis ON public.processing_runs
    FOR EACH ROW
    WHEN (NEW.allocation_basis IS DISTINCT FROM OLD.allocation_basis
          AND NEW.allocated_at IS NOT DISTINCT FROM OLD.allocated_at)
    EXECUTE FUNCTION public.stamp_allocation_basis_changed();

COMMIT;
