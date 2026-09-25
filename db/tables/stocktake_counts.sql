-- db/tables/stocktake_counts.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q2 (A)):**每一次录数与重录,连同录数的人**。
--
-- 【为什么要一张新表】stocktake_lines 每个 (盘点单, 批次) 只有一行,重录走 upsert 覆盖 ——
-- created_by 只剩最后一个保存的人,而且它是客户端送来的。"录过数的人永远不能过账"要一份
-- 数过的人的【完整】名单,于是:
--   · 本表只增不改(guard_stocktake_count_append_only,不分直连与属主路径);
--   · counted_by 由 record_stocktake_count 按 auth.uid() 写,NOT NULL,客户端碰不到;
--   · stocktake_lines 仍是"这一格现在的实点数"(过账读它),本表是"谁在什么时候数成了多少"。
-- post_stocktake 拒开单人(SELF_APPROVAL_FORBIDDEN|raiser)与本表里每一个录数的人
-- (STOCKTAKE_COUNTER_CANNOT_POST|盘点单),按人认(self_leg / account_person)。
--
-- 【读】module.stocktakes.view。【写】没有写策略;直连写按名拒 STOCKTAKE_THROUGH_FUNCTION_ONLY。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE TABLE public.stocktake_counts (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    stocktake_id      uuid NOT NULL REFERENCES public.stocktakes (id) ON DELETE RESTRICT,
    stocktake_line_id uuid NOT NULL REFERENCES public.stocktake_lines (id) ON DELETE RESTRICT,
    inbound_batch_id  uuid REFERENCES public.inbound_batches (id) ON DELETE RESTRICT,
    output_batch_id   uuid REFERENCES public.output_batches (id) ON DELETE RESTRICT,
    book_qty          numeric NOT NULL,
    counted_qty       numeric NOT NULL CHECK (counted_qty >= 0),
    notes             text,
    counted_by        uuid NOT NULL,
    counted_at        timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT stocktake_counts_one_batch CHECK ((inbound_batch_id IS NULL) <> (output_batch_id IS NULL))
);

CREATE INDEX idx_stocktake_counts_stocktake ON public.stocktake_counts (stocktake_id);
CREATE INDEX idx_stocktake_counts_line ON public.stocktake_counts (stocktake_line_id);

ALTER TABLE public.stocktake_counts ENABLE ROW LEVEL SECURITY;
CREATE POLICY "stocktake_counts select by permission"
    ON public.stocktake_counts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.stocktakes.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.stocktake_counts FROM anon;

-- 只增不改:UPDATE / DELETE 一律按名拒(属主路径也拒)。
CREATE TRIGGER trg_stocktake_counts_append_only
    BEFORE UPDATE OR DELETE ON public.stocktake_counts
    FOR EACH ROW EXECUTE FUNCTION public.guard_stocktake_count_append_only();

-- 没有写策略:直连写(零行也触发)按名拒 STOCKTAKE_THROUGH_FUNCTION_ONLY。
CREATE TRIGGER trg_stocktake_counts_direct_write
    BEFORE INSERT OR UPDATE OR DELETE ON public.stocktake_counts
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_stocktake_direct_write();
