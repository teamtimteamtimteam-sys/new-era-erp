-- db/functions/approval_level_for.sql
-- 按【已落库的策略】给一笔本位币金额分档。
--
-- ★ APR-3(2026-09-22):那一次比较搬去了 approval_level_at(numeric, numeric) ——
--   本函数的签名、两句按名拒绝、以及它对调用方的意思【一个字都没有变】,
--   它只是把 >= 交给那支唯一的定义。搬家的理由写在 approval_level_at 的抬头
--   (一句话:BEFORE UPDATE 的闸读不到 NEW 的门槛)。
--   ☞ 本文件里【不再出现】那个比较号,这是有意的 —— db/fixtures/151 注入④
--     的目标因此跟着搬到了 approval_level_at。

CREATE OR REPLACE FUNCTION public.approval_level_for(p_amount_base numeric)
 RETURNS smallint
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_threshold numeric;
BEGIN
    SELECT approval_threshold_base INTO v_threshold FROM finance_settings LIMIT 1;
    IF v_threshold IS NULL THEN
        -- 【没设好的管控不等于可以跳过管控】—— 猜一个级别等于把审批变成装饰
        RAISE EXCEPTION 'APPROVAL_THRESHOLD_NOT_SET';
    END IF;
    IF p_amount_base IS NULL THEN
        RAISE EXCEPTION 'APPROVAL_AMOUNT_REQUIRED';
    END IF;
    -- APR-3:分档的判据只有一份,在 approval_level_at 里。
    RETURN approval_level_at(p_amount_base, v_threshold);
END;
$function$;
