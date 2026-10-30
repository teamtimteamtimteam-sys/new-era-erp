-- db/functions/guard_signing_asset_write.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q4 · Q3):签字样本(signature_specimens)与公司印章(company_stamps)共用的守卫 ——
--   一行只许被换下一次(superseded_at 从空到有),别的列一个都不许改。删行不挡:盖过 / 签过的那一张由 contract_files 的外键(RESTRICT)护着,
--   没用过的一张只有属主路径删得掉(没有任何删除策略)—— 一次性证明收尾时用。函数之外的路(postgres 手改)也挡在这里。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.guard_signing_asset_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    IF (to_jsonb(NEW) - 'superseded_at') IS DISTINCT FROM (to_jsonb(OLD) - 'superseded_at')
       OR OLD.superseded_at IS NOT NULL OR NEW.superseded_at IS NULL THEN
        RAISE EXCEPTION 'SIGNING_ASSET_IMMUTABLE|%', TG_TABLE_NAME;
    END IF;
    RETURN NEW;
END;
$function$;
