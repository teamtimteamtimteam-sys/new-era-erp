-- db/functions/change_log_field.sql
-- HISTORY-1:为遮蔽与任务隐私的判据取【这一行的某个字段】。
--   一次编辑只记了改了的那几列,判据要的字段(employee_id / direction / task_id)常常不在影像里。
--   先后:这条记录自己的 new / old / 主键 → 那一行今天的值 → 同一行更早的记录里最近一次出现的值
--   (那一行已经被删掉时,只剩记录答得出)。三处都没有 → NULL,调用方按【看不见】处理。
-- 【不是 SECURITY DEFINER】它只被 change_log_rows 的判据调用,那时以属主身份跑;
--   EXECUTE 已从 authenticated 收回 —— 它按表名动态读任意一张表。
-- CHAIN-WALK-COST(v1.4.80):今天这一行按键列自己的类型找(走主键索引),不再整行 to_jsonb 再 @>。
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
        -- CHAIN-WALK-COST:按键列自己的类型比(走主键索引),不拿整行的 to_jsonb 去 @>(一年 3 万张分录,每调一次整表扫约 20 ms;
        --   一段付薪分录的变更记录对一个看不见工资的读者要调它二十多次)。同一个判据:键里每一列等于那个值。键里有一列这张表已经没有了
        --   → 以前的 @> 对不上,这里也不查(落到下面的变更记录);值读不成那一列的类型 → 对不上(数据错误只在这一句里接住)。
        IF NOT EXISTS (SELECT 1 FROM jsonb_object_keys(p_key) k
                        WHERE NOT EXISTS (SELECT 1 FROM pg_attribute a
                                           WHERE a.attrelid = format('public.%I', p_table)::regclass AND a.attname = k AND NOT a.attisdropped)) THEN
            BEGIN
                EXECUTE format('SELECT to_jsonb(t) ->> %L FROM public.%I t WHERE %s LIMIT 1', p_field, p_table,
                               (SELECT string_agg(format('t.%I = %L', e.key, e.value), ' AND ') FROM jsonb_each_text(p_key) e))
                   INTO v;
            EXCEPTION WHEN data_exception THEN
                v := NULL;
            END;
        END IF;
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
