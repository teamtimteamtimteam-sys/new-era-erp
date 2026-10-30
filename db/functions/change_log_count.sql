-- db/functions/change_log_count.sql
-- GOLIVE-2(第 13 行,Tim 2026-10-30 Q3):变更记录导出的【计数】—— 符合库这一侧筛选(日期 · 区域 / 记录类型 · 记录 · 人)的已记录变更有几行。
--   导出的 50,000 上限数的就是它(「只看关键事件」由界面的造句器在写文件时判,库里数不了,所以不在这个数里 —— Q3 原样)。
--   同一道门 data.view_change_log,与 change_log_page 逐字同一组筛选。
CREATE OR REPLACE FUNCTION public.change_log_count(p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_table text DEFAULT NULL::text, p_tables text[] DEFAULT NULL::text[], p_record_ids text[] DEFAULT NULL::text[], p_actor uuid DEFAULT NULL::uuid, p_no_session boolean DEFAULT false, p_removed_account boolean DEFAULT false)
 RETURNS bigint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_n bigint;
BEGIN
    PERFORM require_permission('data.view_change_log');
    SELECT count(*) INTO v_n
      FROM change_log c
     WHERE (p_from IS NULL OR c.occurred_at >= p_from::timestamptz)
       AND (p_to IS NULL OR c.occurred_at < (p_to + 1)::timestamptz)
       AND (p_table IS NULL OR c.table_name = p_table)
       AND (p_tables IS NULL OR c.table_name = ANY (p_tables))
       AND (p_record_ids IS NULL OR EXISTS (SELECT 1 FROM jsonb_each_text(c.row_key) k WHERE k.value = ANY (p_record_ids)))
       AND (p_actor IS NULL OR c.actor_account = p_actor OR c.actor_employee = p_actor)
       AND (NOT COALESCE(p_no_session, false) OR c.actor_kind = 'no_session')
       AND (NOT COALESCE(p_removed_account, false)
            OR (c.actor_kind = 'user' AND c.actor_employee IS NULL
                AND NOT EXISTS (SELECT 1 FROM auth.users u2 WHERE u2.id = c.actor_account)));
    RETURN v_n;
END;
$function$;
