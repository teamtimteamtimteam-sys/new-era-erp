CREATE OR REPLACE FUNCTION public.trg_quote_line_touches_parent()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    -- 【父行已经不在时是一次空更新,而不是一个错误】整张报价被硬删时,级联
    -- 删子行会走到这里,而那时父行在本快照里已经删掉 —— UPDATE 命中 0 行。
    -- 写下来是因为"命中 0 行"在别处通常是要报警的(失败不是空集),这里它
    -- 恰恰是对的:父行没了,没有 updated_at 需要顶。
    -- 【updated_at 交给 BEFORE UPDATE 触发器写】—— 这里只负责"碰一下",
    -- 时钟只有一处(quotes_touch_updated_at),不在两个地方各写一遍。
    UPDATE quotes SET updated_by = auth.uid()
     WHERE id = COALESCE(NEW.quote_id, OLD.quote_id);
    RETURN COALESCE(NEW, OLD);
END;
$function$

;
