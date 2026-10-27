-- db/functions/certificate_expiry_status.sql
-- SYSTEM-MAP-2(Tim 2026-10-27 SYSTEM-MAP-1 Q3 → 64d-2):一张资质证书【现在】是什么状态 —— 一份判据,三个读者:
--   提醒页 qualification_expiring(供应商证书)与 company_licence_expiring(公司执照)两支(db/views/operations_arms_all.sql)
--   与供应商证书总览的状态列(db/views/supplier_certificate_status.sql)。
--   not_tracked  证书种类的 disposition = 'ignore'(提醒从来不响)
--   no_expiry    没有有效期
--   expired      有效期 < 今天 —— 与收货闸 supplier_receiving_blocked 同一个比较(当天到期的那一天仍然有效)
--   expiring     有效期 ≤ 今天 + 那一种的 warn_lead_days
--   valid        其余
--   提醒那两支 = expired 或 expiring(与原来那句 disposition <> 'ignore' AND valid_until <= CURRENT_DATE + warn_lead_days 逐行等价)。
-- STABLE:它读 CURRENT_DATE。
--
-- NOTE: introduced by db/migrations/2026-10-27-system-map-2-my-workbench.sql.

CREATE OR REPLACE FUNCTION public.certificate_expiry_status(p_valid_until date, p_disposition text, p_warn_lead_days integer)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE
        WHEN p_disposition = 'ignore' THEN 'not_tracked'
        WHEN p_valid_until IS NULL THEN 'no_expiry'
        WHEN p_valid_until < CURRENT_DATE THEN 'expired'
        WHEN p_valid_until <= CURRENT_DATE + p_warn_lead_days THEN 'expiring'
        ELSE 'valid'
    END;
$function$;

COMMENT ON FUNCTION public.certificate_expiry_status(date, text, integer) IS
'SYSTEM-MAP-2:证书现在的状态 —— not_tracked(种类 ignore)· no_expiry · expired(< 今天,与收货闸同一个比较)· expiring(≤ 今天 + warn_lead_days)· valid。三个读者:提醒页两支(供应商证书 · 公司执照)与供应商证书总览的状态列。';
