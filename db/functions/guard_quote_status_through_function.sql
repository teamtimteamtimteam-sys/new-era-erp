-- db/functions/guard_quote_status_through_function.sql
-- FIN-CHAIN-1(Tim 2026-10-20,APR-5 Q12 · APR5-QUOTE-STATUS-DIRECT-UPDATE):**报价的状态只经函数写**。
--
-- 【量过的】写报价状态的三支函数 —— record_qt_issue(draft → issued)· decline_quote(→ declined + 理由)·
-- convert_quote(→ converted + converted_order_id)—— 全是 SECURITY DEFINER;没有一个屏幕直连改 status
-- (app/ 里对 quotes 只有一条 .insert,不带 status)。而 RLS 的 UPDATE / INSERT 策略开在 module.sales.edit 上,
-- 于是持这个码的人此前可以【直连】把一张报价改成 issued / declined / converted —— 绕开签发留痕
-- (qt_issues)、谢绝理由的门与转单的门。
--
-- 【为什么是行级、只看这三列,而不是 sales_records 那种语句级一律拒】报价的其余列【本来就该直连改】
-- (改价改量是报价的用途 —— 表注释)。所以本守卫只认:
--   · UPDATE 改了 status / converted_order_id / decline_reason;
--   · INSERT 带着一个不是 draft 的 status,或者带着 converted_order_id / decline_reason。
-- 属主路径(row_security_active = false —— 三支 SECURITY DEFINER 函数与迁移)一律放行;与
-- guard_sales_record_direct_write · guard_processing_direct_write 同一个判据。
-- 本函数是 SECURITY INVOKER:它要问的正是【调用者】是不是在 RLS 之下。
--
-- 【与 guard_quote_converted_immutable 的先后】同为 BEFORE 行级,按触发器名排序:converted 那一支
-- (trg_quotes_converted_immutable)先跑 —— 对一张已转单的报价,直连改任何列仍然读到 QT_CONVERTED_IMMUTABLE
-- (fixture 72 钉着)。
--
-- NOTE: introduced by db/migrations/2026-10-20-fin-chain-1.sql.

CREATE OR REPLACE FUNCTION public.guard_quote_status_through_function()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN NEW;
    END IF;
    IF TG_OP = 'INSERT' THEN
        IF NEW.status IS DISTINCT FROM 'draft' THEN
            RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|status|%', NEW.status;
        END IF;
        IF NEW.converted_order_id IS NOT NULL THEN
            RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|converted_order_id|%', NEW.status;
        END IF;
        IF NEW.decline_reason IS NOT NULL THEN
            RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|decline_reason|%', NEW.status;
        END IF;
        RETURN NEW;
    END IF;
    IF NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|status|%', OLD.code;
    END IF;
    IF NEW.converted_order_id IS DISTINCT FROM OLD.converted_order_id THEN
        RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|converted_order_id|%', OLD.code;
    END IF;
    IF NEW.decline_reason IS DISTINCT FROM OLD.decline_reason THEN
        RAISE EXCEPTION 'QT_STATUS_THROUGH_FUNCTION_ONLY|decline_reason|%', OLD.code;
    END IF;
    RETURN NEW;
END;
$function$