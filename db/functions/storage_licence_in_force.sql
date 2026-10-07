-- db/functions/storage_licence_in_force.sql
-- MES-3a(2026-10-06,MES-0 Q32;MES-3a Step 0 Q5,Tim):【那一天,库存上限按哪一张执照判】—— 销毁证书的同一条挑法
--   (cod_governing_licence):gwdf、没软删、号不空、status = active、两个日期都在、那一天落在 valid_from … valid_until 里。
--   恰好一张 → 它的 id;一张都没有,或两张重叠 → NULL(收货照收,记 licence_not_in_force —— Q5;一张过期的公司执照今天
--   不拦收货,在这里开始拦就是一条没人要的新规矩)。【重叠时不挑】—— 挑就是替录错的人做主(cod_governing_licence 的原话)。
--   SECURITY DEFINER:读 company_compliance 不过 RLS,只回一个 id;属主视图(storage_ceiling_status、提醒臂)以读者身份调它。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes3a-storage-safety.sql.

CREATE OR REPLACE FUNCTION public.storage_licence_in_force(p_on date)
 RETURNS uuid
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT CASE WHEN count(*) = 1 THEN (array_agg(cc.id))[1] END
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf' AND cc.deleted_at IS NULL
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
       AND cc.status = 'active'
       AND cc.valid_from IS NOT NULL AND cc.valid_until IS NOT NULL
       AND p_on BETWEEN cc.valid_from AND cc.valid_until;
$function$;
