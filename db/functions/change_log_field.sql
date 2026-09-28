-- db/functions/change_log_field.sql
-- HISTORY-1:为遮蔽与任务隐私的判据取【这一行的某个字段】。
--   一次编辑只记了改了的那几列,判据要的字段(employee_id / direction / task_id)常常不在影像里。
--   先后:这条记录自己的 new / old / 主键 → 那一行今天的值 → 同一行更早的记录里最近一次出现的值
--   (那一行已经被删掉时,只剩记录答得出)。三处都没有 → NULL,调用方按【看不见】处理。
-- 【不是 SECURITY DEFINER】它只被 change_log_rows 的判据调用,那时以属主身份跑;
--   EXECUTE 已从 authenticated 收回 —— 它按表名动态读任意一张表。
CREATE OR REPLACE FUNCTION public.change_log_field(p_table text, p_key jsonb, p_old jsonb, p_new jsonb, p_field text)
 RETURNS text
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v text := COALESCE(p_new ->> p_field, p_old ->> p_field, p_key ->> p_field);
BEGIN
    IF v IS NOT NULL OR p_key IS NULL THEN
        RETURN v;
    END IF;
    IF to_regclass(format('public.%I', p_table)) IS NOT NULL THEN
        EXECUTE format('SELECT to_jsonb(t) ->> %L FROM public.%I t WHERE to_jsonb(t) @> $1 LIMIT 1', p_field, p_table)
           INTO v USING p_key;
        IF v IS NOT NULL THEN
            RETURN v;
        END IF;
    END IF;
    SELECT COALESCE(c.new ->> p_field, c.old ->> p_field) INTO v
      FROM change_log c
     WHERE c.table_name = p_table AND c.row_key = p_key
       AND COALESCE(c.new ->> p_field, c.old ->> p_field) IS NOT NULL
     ORDER BY c.seq DESC
     LIMIT 1;
    RETURN v;
END;
$function$;
