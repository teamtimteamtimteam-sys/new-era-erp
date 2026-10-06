-- db/functions/ingest_process_pending.sql
-- MES-1(2026-10-06,MES-1 Step 0 Q11,Tim):【"Process received"】—— 把收件箱里 status = received 的行按到达顺序交给分派器。
--   转换只在员工的会话里跑(Q11),所以这是收件箱上的一个按钮,持 module.processing.view 的人能按;
--   MES-2 的确认队列打开时会调它。它只改状态那几列(守卫),处理一遍是幂等的:没有 received 的行就什么都不做。
--   p_limit 一次最多几行(默认 200,1–1000);返回 {processed, transformed, failed, awaiting}。
-- MES-2(2026-10-06,MES-2 Step 0 Q6,Tim):它也取 awaiting_transform 的行 —— 但【只取它那一类此刻已经有转换器的】。
--   一类接上转换器之前送来的行(MES-1 起它们停在 awaiting_transform),从此由同一个按钮接着处理,不必由 cto / admin 一行一行重试;
--   还没有转换器的类照旧不碰(再交给分派器一次只会把 attempts 白白加一)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes1-entry-point.sql.

CREATE OR REPLACE FUNCTION public.ingest_process_pending(p_limit integer DEFAULT 200)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id    bigint;
    v_state text;
    v_t     integer := 0;
    v_f     integer := 0;
    v_a     integer := 0;
BEGIN
    PERFORM require_permission('module.processing.view');
    FOR v_id IN SELECT b.id FROM ingest_inbox b
                 WHERE b.status = 'received'
                    OR (b.status = 'awaiting_transform'
                        AND EXISTS (SELECT 1 FROM ingest_data_classes c
                                     WHERE c.code = b.data_class AND c.transform_function IS NOT NULL))
                 ORDER BY b.id LIMIT LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000) LOOP
        v_state := ingest_transform_row(v_id);
        IF v_state = 'transformed' THEN v_t := v_t + 1;
        ELSIF v_state = 'failed' THEN v_f := v_f + 1;
        ELSE v_a := v_a + 1;
        END IF;
    END LOOP;
    RETURN jsonb_build_object('processed', v_t + v_f + v_a, 'transformed', v_t, 'failed', v_f, 'awaiting', v_a);
END;
$function$;
