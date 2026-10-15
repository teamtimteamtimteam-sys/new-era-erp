-- db/functions/guard_downtime_cause.sql
-- MES-7a-1(2026-10-15,MES-0 Q71;MES-7a Step 0 Q3 · Q4,Tim):【一段新记的停机必须说出原因,而且来源只能是手工】。
--   ① INSERT:cause_code 必填(DOWNTIME_CAUSE_REQUIRED)—— 在【插入】这一刻判,所以本刀之前那一行("Test-1",原因为空)
--      原样留着、读作"未分类";MES-4a 给加工单的开始 / 结束 / 班次立的是同一个先例(INSERT 触发器,不是一条 NOT VALID 的 CHECK)。
--      原因必须是启用着的(DOWNTIME_CAUSE_INACTIVE|<代号>);不存在的代号由外键拒,函数在前面先按名拒(DOWNTIME_CAUSE_UNKNOWN)。
--   ② 来源(Q4):manual · device。device【保留】—— 没有任何控制器的负载格式,也没有转换层,于是今天每一行都是 manual,
--      一行 device 按名拒(DOWNTIME_SOURCE_RESERVED);一行的来源记下之后不改(DOWNTIME_SOURCE_FIXED)。
--   ③ UPDATE:一段已经说出原因的停机不能被改回"没有原因"(DOWNTIME_CAUSE_REQUIRED);改到一种停用的原因也拒。
--      旧的那一行(原因为空)不更正就一直是空 —— 更正它的人必须给它一个原因(correct_equipment_downtime)。
--   【属主路径不放行】这条规矩说的是行,不是门:迁移、fixture、SECURITY DEFINER 的函数插进来的每一行都要有原因。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes7a1-equipment-reliability.sql.

CREATE OR REPLACE FUNCTION public.guard_downtime_cause()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'INSERT' THEN
        IF NEW.cause_code IS NULL THEN
            RAISE EXCEPTION 'DOWNTIME_CAUSE_REQUIRED';
        END IF;
        IF NEW.source IS DISTINCT FROM 'manual' THEN
            RAISE EXCEPTION 'DOWNTIME_SOURCE_RESERVED|%', COALESCE(NEW.source, '?');
        END IF;
    ELSE
        IF NEW.source IS DISTINCT FROM OLD.source THEN
            RAISE EXCEPTION 'DOWNTIME_SOURCE_FIXED|%', OLD.source;
        END IF;
        IF NEW.cause_code IS NULL AND OLD.cause_code IS NOT NULL THEN
            RAISE EXCEPTION 'DOWNTIME_CAUSE_REQUIRED';
        END IF;
        IF NEW.cause_code IS NOT DISTINCT FROM OLD.cause_code THEN
            RETURN NEW;
        END IF;
    END IF;
    IF NEW.cause_code IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM downtime_causes c WHERE c.code = NEW.cause_code AND c.is_active) THEN
        RAISE EXCEPTION 'DOWNTIME_CAUSE_INACTIVE|%', NEW.cause_code;
    END IF;
    RETURN NEW;
END;
$function$;
