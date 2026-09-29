-- db/functions/change_log_mask_row.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):遮蔽的【唯一一步】—— 从 change_log_rows 的循环体里抽出来,两个读法共用:
--   /settings/change-history 的 change_log_rows,与每一页底部审计记录的 record_trail。
--   规则仍是 HISTORY-1 那一份 change_log_mask_rules();这里【不加任何一条自己的规则】。
-- 返回 {"old": …, "new": …, "row_restricted": bool}(old/new 为 JSON null 表示影像本身就没有)。
--   任务四张表先问 change_log_task_visible();不过 → 整份影像换成受限标记,row_restricted = true。
--   其余逐列问 change_log_rule_visible();看不见的换成 {"$restricted": true},本来就是 null 的留 null。
-- 【不是 SECURITY DEFINER】只在两支 DEFINER 读法的函数体里以属主身份被调用;EXECUTE 已从 authenticated 收回。
CREATE OR REPLACE FUNCTION public.change_log_mask_row(p_table text, p_key jsonb, p_old jsonb, p_new jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    m        record;
    v_hidden text[] := ARRAY[]::text[];
BEGIN
    IF p_table IN ('tasks', 'task_nodes', 'task_participants', 'task_history')
       AND NOT change_log_task_visible(p_table, p_key, p_old, p_new) THEN
        RETURN jsonb_build_object('old', change_log_restrict(p_old, NULL),
                                  'new', change_log_restrict(p_new, NULL),
                                  'row_restricted', true);
    END IF;
    FOR m IN SELECT mr.column_name AS m_col, mr.rule AS m_rule
               FROM change_log_mask_rules() mr WHERE mr.table_name = p_table LOOP
        IF (COALESCE(p_old -> m.m_col, 'null'::jsonb) <> 'null'::jsonb
            OR COALESCE(p_new -> m.m_col, 'null'::jsonb) <> 'null'::jsonb)
           AND NOT change_log_rule_visible(m.m_rule, p_table, p_key, p_old, p_new) THEN
            v_hidden := v_hidden || m.m_col;
        END IF;
    END LOOP;
    IF cardinality(v_hidden) > 0 THEN
        RETURN jsonb_build_object('old', change_log_restrict(p_old, v_hidden),
                                  'new', change_log_restrict(p_new, v_hidden),
                                  'row_restricted', false);
    END IF;
    RETURN jsonb_build_object('old', p_old, 'new', p_new, 'row_restricted', false);
END;
$function$;
