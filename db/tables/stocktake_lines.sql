-- db/tables/stocktake_lines.sql
-- Stocktake lines — one counted quantity per batch within a stocktake.
-- No updated_at: a re-count replaces the line via upsert on the (stocktake, batch) key.
-- ROLE-1 Batch 3a: the upsert happens only inside record_stocktake_count; every count and recount
-- (with who made it) is appended to stocktake_counts. created_by here is the LAST counter.
-- book_qty is the remaining_qty snapshot at count time; post_stocktake() recomputes the
-- delta against the CURRENT remaining_qty (count wins), so book_qty is informational.
--
-- The two UNIQUE constraints use the default NULLS DISTINCT: because each line has exactly
-- one batch FK (XOR CHECK), the null side never collides, giving partial-unique semantics
-- (unique per stocktake+inbound_batch, and per stocktake+output_batch) — no partial index needed.
--
-- NOTE: introduced by db/migrations/2026-07-03-phase2-cut4-stocktake.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.stocktake_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    stocktake_id     uuid NOT NULL REFERENCES public.stocktakes (id) ON DELETE RESTRICT,
    inbound_batch_id uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id  uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    book_qty         numeric NOT NULL,
    counted_qty      numeric NOT NULL CHECK (counted_qty >= 0),
    notes            text,
    counted_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid,
    CONSTRAINT stocktake_lines_one_batch CHECK ((inbound_batch_id IS NULL) <> (output_batch_id IS NULL)),
    UNIQUE (stocktake_id, inbound_batch_id),
    UNIQUE (stocktake_id, output_batch_id)
);

CREATE INDEX idx_stocktake_lines_stocktake ON public.stocktake_lines (stocktake_id);

-- SEARCH-4 · 迁移 B:关联搜索走这一列。为将来的体量建,不为今天的毫秒数
--(320 行上规划器一律 Seq Scan;理由与迁移 A/C 逐字同族)。
CREATE INDEX stocktake_lines_inbound_batch_id_rel ON public.stocktake_lines (inbound_batch_id);
CREATE INDEX stocktake_lines_output_batch_id_rel ON public.stocktake_lines (output_batch_id);

ALTER TABLE public.stocktake_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stocktake_lines select by permission"
    ON public.stocktake_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.stocktakes.view'::text));

-- ★ ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q2 · Q3):**没有写策略**。录数与重录只经
--   record_stocktake_count(SECURITY DEFINER,action.stocktake_count):它核盘点单仍是 open、按
--   auth.uid() 写 created_by,并在 stocktake_counts 里追加一行"谁数的"。原来的 INSERT / UPDATE 两条
--   让持 stocktakes.edit 的人在已过账的单上加行改行、把 created_by 写成任何人。

-- AUDEL-1a:硬删按名拒,报【父单】的号 —— 把行从表头底下删走与删掉表头是同一件事,
-- 而"先删行再删头"正是 AUDEL-0 实测通过的那条两步路。DELETE 策略一并删掉。
CREATE TRIGGER trg_stocktake_lines_no_hard_delete
    BEFORE DELETE ON public.stocktake_lines
    FOR EACH ROW EXECUTE FUNCTION public.guard_stocktake_no_hard_delete();

-- ── SILENT-1(2026-09-08)· 被拒绝的写要抛,不许是一次"成功的空操作" ──────────
-- 本表的写策略是 `USING (p) WITH CHECK (p)`,两侧同一个谓词:不满足 p 的人卡在
-- USING 上,那一行根本没进语句的视野,WITH CHECK 永远没机会抛 —— 零行、不报错。
-- 这支语句级触发器零行也照样触发,抛 PERMISSION_DENIED|<码>。
-- 它由 row_security_active() 守着,所以属主 / SECURITY DEFINER 那些路一律放行。
-- 【它不动任何策略,所以读权限不可能因它变窄。】详见迁移文件抬头。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.stocktake_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.stocktakes.edit');

-- ── ROLE-1 Batch 3a · 直连 INSERT / UPDATE 一律按名拒 ────────────────────────────
-- 同 stocktakes 上那一支:零行也触发,抛 STOCKTAKE_THROUGH_FUNCTION_ONLY;属主路径放行。
CREATE TRIGGER trg_stocktake_lines_direct_write
    BEFORE INSERT OR UPDATE ON public.stocktake_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_stocktake_direct_write();
