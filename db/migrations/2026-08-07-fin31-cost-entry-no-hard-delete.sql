-- db/migrations/2026-08-07-fin31-cost-entry-no-hard-delete.sql
-- FIN-31:加工成本条目【不许硬删】—— 把一条一直靠副作用成立的规矩,写成声明。
--
-- 【复核的结论,先说清楚】"已分摊的加工单还能增删改成本、且没有分摊检查"这条,
-- 到今天【已经不成立】,不需要加任何检查:
--   * 三条路径都由应用侧的 runEditable 挡在 status='committed' 且未软删;
--   * 三条路径都会让 processing_run_allocation_status.is_stale 变 true ——
--     该视图取 GREATEST(created_at, updated_at),而软删是 UPDATE deleted_at,
--     update_updated_at 会把 updated_at 顶上去(它【不】过滤 deleted_at,正是为此);
--   * 重跑是差额法(FIN-24),负差额同样正确 —— 实测:600 → 删掉 300 的电费 →
--     重跑得 300,1220 恰好动 −300,1200 不动,5110 净额回零,重跑后 is_stale 转 false。
-- 所以"允许改、会标过期、重跑是对的"这三件事合起来就是答案,那条抱怨可以结掉。
--
-- 【剩下的那一件,才是本迁移做的事】硬删(DELETE 而非 UPDATE deleted_at)会:
-- 不产生冲销分录(5110 借 / 2200 贷 原样留在总账)、不留历史行、并且把那一行的
-- 时间戳从 last_cost_change 的 UNION 里【拿走】—— 于是 is_stale 可能不升反降,
-- 一笔已经不存在的成本继续留在分摊里,而没有任何东西会说话。
--
-- 它今天【几乎】已经被拦住:processing_cost_entry_history.entry_id 的外键是
-- NO ACTION,而 FIN-8 之后每条新条目在 INSERT 时就有历史行 —— 于是硬删被外键顶回。
-- 但那是【副作用,不是声明】:它只覆盖有历史行的条目(线上 5 条里有 3 条是
-- FIN-8 之前建的,没有历史行,今天真的删得掉),而且哪天有人把那个外键"顺手"
-- 改成 ON DELETE CASCADE,这道保护会连同历史行一起无声消失。
-- 一条靠别处的副作用成立的规矩,等于没有规矩 —— 写成守卫,和
-- guard_cost_entry_settled 同一个形状。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin31-cost-entry-no-hard-delete.sql

BEGIN;

CREATE OR REPLACE FUNCTION public.guard_cost_entry_no_hard_delete()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    -- 软删(UPDATE deleted_at)才是这张表的删除语义:它过冲销分录、留历史行、
    -- 并把 updated_at 顶上去让分摊标记过期。硬删三件全不做。
    RAISE EXCEPTION 'COST_ENTRY_HARD_DELETE|%', OLD.cost_type;
END;
$fn$;

CREATE TRIGGER trg_processing_cost_entries_no_hard_delete
    BEFORE DELETE ON public.processing_cost_entries
    FOR EACH ROW EXECUTE FUNCTION public.guard_cost_entry_no_hard_delete();

COMMIT;
