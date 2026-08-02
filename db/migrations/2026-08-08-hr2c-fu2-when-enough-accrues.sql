-- db/migrations/2026-08-08-hr2c-fu2-when-enough-accrues.sql
-- HR-2c 跟进 2:被拒的时候,要说得出【什么时候够】。
--
-- 「假期不足:可用 8 天,申请 10 天。」这句话把员工直接推到 HR 那里去问一句
-- 本来系统自己知道的事:再等到几号就够了。按月累积之后这个问题【总是有答案的】——
-- 累积是个阶梯函数,往前推就行。
--
-- 【为什么放在数据库里】答案要靠累积规则算,而累积规则只有一份实现。
-- 放到 TypeScript 里就是第二份 —— GrantRunner 里那份重复的折算公式刚被删掉,
-- 不该再种一棵。错误码本身【不变】(INSUFFICIENT_ACCRUED_LEAVE|accrued|requested),
-- 界面拿到错误之后再问一次这个函数,把日期拼进那句话里。

BEGIN;

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
$function$;

COMMENT ON FUNCTION public.annual_leave_available_from(uuid, numeric, date) IS
    '最早哪一天累积够 p_days 天可请。按月末逐个往前推(累积在月末落账);本年度内攒不够则返回 NULL。'
    '供界面在 INSUFFICIENT_ACCRUED_LEAVE 之后补一句"到几号就够了" —— 累积规则只有一份实现,不在应用层重写。';

COMMIT;
