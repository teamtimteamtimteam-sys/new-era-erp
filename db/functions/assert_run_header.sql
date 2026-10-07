-- db/functions/assert_run_header.sql
-- MES-4a(2026-10-07,MES-0 Q42;MES-4a Step 0 Q7,Tim):【一张新加工单的表头说得通吗】—— 一份判据,三个调用方:
--   commit_processing_run(在任何业务判断之前先问它,于是操作员先看到这一句)· guard_processing_run_header(INSERT 触发器 ——
--   对任何写入者成立)· correct_run_header(改开始 / 结束 / 班次时按新值再问一遍)。
--   按顺序:
--     RUN_TIMES_REQUIRED|<开始或结束缺哪一个>      开始、结束必填
--     RUN_SHIFT_REQUIRED                           班次必填(选的,不是推的 —— 班次的起止时刻今天是空的)
--     RUN_SHIFT_UNKNOWN|<码>                       班次不存在或已停用
--     RUN_END_BEFORE_START|<开始>|<结束>            结束必须晚于开始
--     RUN_IN_FUTURE|<结束>                          还没发生的事不记(fixture 214 那一族:发生了的事,日期不晚于今天)
--     RUN_DATE_OUTSIDE_RUN_TIME|<加工日>|<开始那天>|<结束那天>  加工日要落在开始与结束的【新加坡日期】之间(含两端)
--   加工日仍是库存流水的业务日期(它决定期间),所以它【不从时刻推出来】—— 人选,这里只问它与时刻对不对得上。
--   【内层】不是 SECURITY DEFINER、没有调用者检查;它不读任何人的数据(只读班次字典),EXECUTE 从 authenticated 收回。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes4a-processing-record.sql.

CREATE OR REPLACE FUNCTION public.assert_run_header(p_process_date date, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_shift_code text)
 RETURNS void
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_from date;
    v_to   date;
BEGIN
    IF p_started_at IS NULL OR p_ended_at IS NULL THEN
        RAISE EXCEPTION 'RUN_TIMES_REQUIRED|%', CASE WHEN p_started_at IS NULL AND p_ended_at IS NULL THEN 'start,end'
                                                     WHEN p_started_at IS NULL THEN 'start' ELSE 'end' END
          USING HINT = 'MES-4a 起每一张加工单都要说出它从几点跑到几点(规格 §3.2 · §5)。';
    END IF;
    IF p_shift_code IS NULL OR btrim(p_shift_code) = '' THEN
        RAISE EXCEPTION 'RUN_SHIFT_REQUIRED'
          USING HINT = 'MES-4a 起每一张加工单都要选一个班次。班次是选的,不是从时刻推的 —— 班次的起止时刻还没人给(V6 · V7)。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM shifts s WHERE s.code = p_shift_code AND s.is_active) THEN
        RAISE EXCEPTION 'RUN_SHIFT_UNKNOWN|%', p_shift_code;
    END IF;
    IF p_ended_at <= p_started_at THEN
        RAISE EXCEPTION 'RUN_END_BEFORE_START|%|%', p_started_at, p_ended_at;
    END IF;
    IF p_ended_at > now() THEN
        RAISE EXCEPTION 'RUN_IN_FUTURE|%', p_ended_at
          USING HINT = '一炉还没跑完就不记 —— 结束时刻晚于此刻。';
    END IF;
    v_from := (p_started_at AT TIME ZONE 'Asia/Singapore')::date;
    v_to := (p_ended_at AT TIME ZONE 'Asia/Singapore')::date;
    IF p_process_date IS NOT NULL AND (p_process_date < v_from OR p_process_date > v_to) THEN
        RAISE EXCEPTION 'RUN_DATE_OUTSIDE_RUN_TIME|%|%|%', p_process_date, v_from, v_to
          USING HINT = '加工日要落在这一炉开始那天与结束那天(新加坡日期)之间。';
    END IF;
END;
$function$
