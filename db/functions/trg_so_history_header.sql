CREATE OR REPLACE FUNCTION public.trg_so_history_header()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【只在改单上下文里写 —— 这一句同时是"草稿不留改单历史"那条规矩的实现】
    -- 草稿态的 amend_sales_order 根本不设这个标记(它不需要通行证),于是草稿的
    -- 编辑自然不进本表。不是第二条规则,是同一个机制的推论(PUR-2 的建单行不记
    -- 历史用的就是这一条)。
    -- 状态转换也不进来:它们走 so_status_ctx,而且各自已经在 change_type 上有
    -- 自己的一行 —— 记进来会让编辑史被状态噪音淹掉。
    IF current_setting('evoltrya.so_amend_ctx', true) IS DISTINCT FROM '1' THEN
        RETURN NEW;
    END IF;
    -- 只记【商业字段】的改动:updated_at/updated_by 的变化不是编辑史。
    IF NEW.notes IS NOT DISTINCT FROM OLD.notes
       AND NEW.terms_text IS NOT DISTINCT FROM OLD.terms_text THEN
        RETURN NEW;
    END IF;

    INSERT INTO sales_order_history (sales_order_id, change_type,
        old_notes, new_notes, old_terms_text, new_terms_text, amend_reason)
    VALUES (NEW.id, 'header_update',
        OLD.notes, NEW.notes, OLD.terms_text, NEW.terms_text,
        NULLIF(current_setting('evoltrya.so_amend_reason', true), ''));
    RETURN NEW;
END;
$function$

;
