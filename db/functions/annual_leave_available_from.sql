-- db/functions/annual_leave_available_from.sql
-- 最早哪一天累积够 p_days 天可请。按月末逐个往前推(累积在月末落账);
-- 本假期年度内攒不够则返回 NULL —— 界面据此说另一句话,而不是编一个日期出来。
--
-- 【为什么在数据库里】"什么时候够"要靠累积规则算,而累积规则只有一份实现。
-- 放到 TypeScript 里就是第二份 —— GrantRunner 那份重复的折算公式刚被删掉,不该再种一棵。
-- 错误码本身不变(INSUFFICIENT_ACCRUED_LEAVE|accrued|requested),界面拿到错误后再问一次这里。
--
-- NOTE: introduced by db/migrations/2026-08-08-hr2c-fu2-when-enough-accrues.sql.

CREATE OR REPLACE FUNCTION public.annual_leave_available_from(p_employee_id uuid, p_days numeric, p_from date DEFAULT CURRENT_DATE)
 RETURNS date
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_from)::integer;
    v_m    date := date_trunc('month', p_from)::date;
    v_end  date;
BEGIN
    -- 【本人或 HR】—— 与 leave_balance 同一道口径。界面在 INSUFFICIENT_ACCRUED_LEAVE
    -- 之后调它,那时调用者要么是本人、要么持 module.hr.edit,两种都过得去。
    IF NOT (has_permission('module.hr.view') OR p_employee_id = current_user_employee()) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.hr.view';
    END IF;

    -- 逐个月末往前推:哪一个月末的可用余额够了,那天起就订得动。
    -- 累积在月末落账,所以「够了的那天」就是那个月末本身。
    WHILE v_m <= make_date(v_year, 12, 1) LOOP
        v_end := (v_m + interval '1 month' - interval '1 day')::date;
        IF v_end >= p_from
           AND (leave_balance_internal(p_employee_id, 'annual', v_end)->>'available')::numeric >= p_days THEN
            RETURN v_end;
        END IF;
        v_m := (v_m + interval '1 month')::date;
    END LOOP;
    -- 本假期年度内都攒不够 —— 返回 NULL,界面据此说另一句话,而不是编一个日期出来。
    RETURN NULL;
END;
$function$
;