-- db/functions/guard_commission_agreement_agent.sql
-- COMM-1:佣金协议的代理人【必须是 service_vendor】。
--
-- 形状逐字取自 guard_forwarder_details_is_forwarder():同一个问题 ——
-- 一个挂在某家对手方身上的属性,要求那一家【真的是那一类】—— 同一个处置。
--
-- 【为什么这条判断值得一道守卫,而不是一句约定】佣金的收款方是一个
-- 【提供服务的第三方】。把它错挂到一家卖货给我们的供应商身上,
-- 会让一笔佣金看起来像是货款的一部分,而那正是本仓库反复点名的
-- 「两件不同的事长得一样」。
--
-- 【它不是 SECURITY DEFINER】与货代那一支同形:它读 suppliers,
-- 而写这张表的人必须持有 module.suppliers.edit(RLS),
-- 那样的人本来就看得见 suppliers。

CREATE OR REPLACE FUNCTION public.guard_commission_agreement_agent()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_type text;
    v_code text;
BEGIN
    SELECT counterparty_type, code INTO v_type, v_code
      FROM public.suppliers WHERE id = NEW.agent_supplier_id;
    IF v_type IS DISTINCT FROM 'service_vendor' THEN
        RAISE EXCEPTION 'COMMISSION_AGENT_NOT_SERVICE_VENDOR|%', COALESCE(v_code, NEW.agent_supplier_id::text)
          USING HINT = '佣金的收款方是一个提供服务的第三方 —— 先把这一家的 counterparty_type 改成 service_vendor,或者建一家';
    END IF;
    RETURN NEW;
END;
$function$;
