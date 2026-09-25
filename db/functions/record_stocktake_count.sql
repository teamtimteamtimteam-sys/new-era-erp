-- db/functions/record_stocktake_count.sql
-- ROLE-1 Batch 3a(Tim 2026-09-25,Batch 3 grilling Q2 (A) · Q3):录一笔实点数 / 重录。
--
-- 【两处写,一个事务】
--   ① stocktake_lines:这一格【现在】的实点数(过账读它)—— 同一 (盘点单, 批次) 重录覆盖,
--      book_qty 取【保存时点】的批次剩余(与原来的 saveCount 同一口径),created_by = 最后一个录数的人;
--   ② stocktake_counts:追加一行"谁、何时、数成多少"—— 只增不改。过账时"录过数的人不能过账"
--      读的就是这张表,所以重录【不会】抹掉前一个录数的人。
-- 录数的人由 auth.uid() 写,不经客户端。
--
-- 【拒】PERMISSION_DENIED|action.stocktake_count · STOCKTAKE_NOT_FOUND · STOCKTAKE_NOT_OPEN(过账或
-- 取消之后不许再录 —— 此前这一句只在屏幕上)· STOCKTAKE_COUNT_BATCH_REQUIRED(要且只要一个批次)·
-- STOCKTAKE_COUNT_QTY_INVALID(空或负)· BATCH_DELETED(批次不存在或已注销)。
--
-- NOTE: introduced by db/migrations/2026-09-25-role1b3a-the-counter-never-posts.sql.

CREATE OR REPLACE FUNCTION public.record_stocktake_count(p_stocktake_id uuid, p_inbound_batch_id uuid, p_output_batch_id uuid, p_counted_qty numeric, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_st      record;
    v_book    numeric;
    v_deleted timestamptz;
    v_found   boolean;
    v_notes   text := NULLIF(btrim(COALESCE(p_notes, '')), '');
    v_line_id uuid;
BEGIN
    PERFORM require_permission('action.stocktake_count');

    SELECT id, code, status, deleted_at INTO v_st
      FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', COALESCE(p_stocktake_id::text, '?');
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    IF (p_inbound_batch_id IS NULL) = (p_output_batch_id IS NULL) THEN
        RAISE EXCEPTION 'STOCKTAKE_COUNT_BATCH_REQUIRED|%', v_st.code;
    END IF;
    IF p_counted_qty IS NULL OR p_counted_qty < 0 THEN
        RAISE EXCEPTION 'STOCKTAKE_COUNT_QTY_INVALID|%', v_st.code;
    END IF;

    IF p_inbound_batch_id IS NOT NULL THEN
        SELECT remaining_qty, deleted_at, true INTO v_book, v_deleted, v_found
          FROM inbound_batches WHERE id = p_inbound_batch_id;
    ELSE
        SELECT remaining_qty, deleted_at, true INTO v_book, v_deleted, v_found
          FROM output_batches WHERE id = p_output_batch_id;
    END IF;
    IF v_found IS NULL OR v_deleted IS NOT NULL THEN
        RAISE EXCEPTION 'BATCH_DELETED|%', COALESCE(p_inbound_batch_id, p_output_batch_id)::text;
    END IF;

    IF p_inbound_batch_id IS NOT NULL THEN
        INSERT INTO stocktake_lines (stocktake_id, inbound_batch_id, book_qty, counted_qty, notes, counted_at, created_by)
        VALUES (p_stocktake_id, p_inbound_batch_id, v_book, p_counted_qty, v_notes, now(), v_user)
        ON CONFLICT (stocktake_id, inbound_batch_id) DO UPDATE
           SET book_qty = EXCLUDED.book_qty, counted_qty = EXCLUDED.counted_qty, notes = EXCLUDED.notes,
               counted_at = EXCLUDED.counted_at, created_by = EXCLUDED.created_by
        RETURNING id INTO v_line_id;
    ELSE
        INSERT INTO stocktake_lines (stocktake_id, output_batch_id, book_qty, counted_qty, notes, counted_at, created_by)
        VALUES (p_stocktake_id, p_output_batch_id, v_book, p_counted_qty, v_notes, now(), v_user)
        ON CONFLICT (stocktake_id, output_batch_id) DO UPDATE
           SET book_qty = EXCLUDED.book_qty, counted_qty = EXCLUDED.counted_qty, notes = EXCLUDED.notes,
               counted_at = EXCLUDED.counted_at, created_by = EXCLUDED.created_by
        RETURNING id INTO v_line_id;
    END IF;

    INSERT INTO stocktake_counts (stocktake_id, stocktake_line_id, inbound_batch_id, output_batch_id,
                                  book_qty, counted_qty, notes, counted_by)
    VALUES (p_stocktake_id, v_line_id, p_inbound_batch_id, p_output_batch_id,
            v_book, p_counted_qty, v_notes, v_user);

    UPDATE stocktakes SET updated_by = v_user, updated_at = now() WHERE id = p_stocktake_id;

    RETURN jsonb_build_object('stocktake_id', p_stocktake_id, 'code', v_st.code, 'line_id', v_line_id,
                              'book_qty', v_book, 'counted_qty', p_counted_qty);
END;
$function$;

COMMENT ON FUNCTION public.record_stocktake_count(uuid, uuid, uuid, numeric, text) IS
'ROLE-1 Batch 3a:录数 / 重录(action.stocktake_count)。覆盖 stocktake_lines 那一格的实点数,并在 stocktake_counts 追加一行谁数的(只增不改)—— 过账时录过数的每一个人都被拒。只在盘点单 open 时收;录数的人由 auth.uid() 写。';
