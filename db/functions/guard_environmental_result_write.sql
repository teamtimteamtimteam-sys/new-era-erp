-- db/functions/guard_environmental_result_write.sql
-- MES-7b-2(2026-10-16,MES-7b Step 0 Q16,Tim):environmental_results 的守卫,一支函数两种挂法 ——
--   UPDATE / DELETE(语句级):对谁都按名拒 ENV_RESULT_IMMUTABLE|<动作> —— 只追加;记错了再记一条、引用它、带理由。
--   INSERT(行级):会话里直连插入按名拒 ENV_RESULT_THROUGH_FUNCTION_ONLY;采样日不在未来(新加坡的今天,ENV_SAMPLED_IN_FUTURE|<日>)——
--     对每一个写入者都成立。判定与"超标 ⇔ 一件事故"由表上的 CHECK 钉住。
--   【INVOKER】row_security_active 要反映调用者的视角。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
CREATE OR REPLACE FUNCTION public.guard_environmental_result_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_LEVEL = 'STATEMENT' THEN
        RAISE EXCEPTION 'ENV_RESULT_IMMUTABLE|%', lower(TG_OP)
          USING HINT = '一条环境监测结果写下就不改。记错了就再记一条,引用它、写下理由。';
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'ENV_RESULT_THROUGH_FUNCTION_ONLY';
    END IF;
    IF NEW.sampled_on > (now() AT TIME ZONE 'Asia/Singapore')::date THEN
        RAISE EXCEPTION 'ENV_SAMPLED_IN_FUTURE|%', NEW.sampled_on;
    END IF;
    RETURN NEW;
END;
$function$;
