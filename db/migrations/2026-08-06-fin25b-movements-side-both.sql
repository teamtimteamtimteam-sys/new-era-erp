-- db/migrations/2026-08-06-fin25b-movements-side-both.sql
--
-- FIN-25b:inventory_movements 的 side 约束把 processing_consume /
-- reversal_restore 钉在进料侧 —— 它写于消耗只可能来自进料批的年代。FIN-25 起
-- 两种消耗都存在(再加工耗产出批),这两类放开为【任一侧】;恰一批次仍由
-- one_batch XOR 把守,不放松。produce/void/sale 仍钉在产出侧(语义未变)。
-- fixture 19 的 E 臂(reversal_restore 产出侧)与 stage2 提交(consume 产出侧)
-- 就是撞上它才有本迁移 —— 门先红,后有修。

BEGIN;

ALTER TABLE public.inventory_movements DROP CONSTRAINT inventory_movements_side;
ALTER TABLE public.inventory_movements ADD CONSTRAINT inventory_movements_side CHECK (CASE movement_type
    WHEN 'processing_produce' THEN output_batch_id IS NOT NULL
    WHEN 'reversal_void' THEN output_batch_id IS NOT NULL
    WHEN 'sale' THEN output_batch_id IS NOT NULL
    ELSE true END);

COMMIT;
