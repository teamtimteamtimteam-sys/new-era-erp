-- db/functions/guard_incident_batch_write.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q7,Tim):incident_batches 的守卫,一支函数两种挂法 ——
--   语句级(UPDATE / DELETE):删除对谁都按名拒 INCIDENT_LINK_IMMUTABLE|delete;会话里直连的 UPDATE 按名拒
--     INCIDENT_LINK_THROUGH_FUNCTION_ONLY —— 语句级,所以 RLS 让它碰不到任何一行时照样抛,不是一次"成功的空操作"(ALERT-1)。
--   行级:直连插入按名拒(同上);一行链接只在【解链接】那一次改得动 —— 从有效变成解除,而且只许动 unlinked_at / unlinked_by /
--     unlink_reason 三列;别的改动一律 INCIDENT_LINK_IMMUTABLE|update(属主路径同样受它管:它守的是记录的形状)。
--   INVOKER:row_security_active 要反映调用者。
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
CREATE OR REPLACE FUNCTION public.guard_incident_batch_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF TG_OP = 'DELETE' THEN
        RAISE EXCEPTION 'INCIDENT_LINK_IMMUTABLE|delete';
    END IF;
    IF row_security_active(TG_RELID) THEN
        RAISE EXCEPTION 'INCIDENT_LINK_THROUGH_FUNCTION_ONLY';
    END IF;
    IF TG_LEVEL = 'STATEMENT' OR TG_OP = 'INSERT' THEN
        IF TG_LEVEL = 'STATEMENT' THEN
            RETURN NULL;
        END IF;
        RETURN NEW;
    END IF;
    IF OLD.unlinked_at IS NOT NULL OR NEW.unlinked_at IS NULL
       OR (to_jsonb(NEW) - 'unlinked_at' - 'unlinked_by' - 'unlink_reason')
          IS DISTINCT FROM (to_jsonb(OLD) - 'unlinked_at' - 'unlinked_by' - 'unlink_reason') THEN
        RAISE EXCEPTION 'INCIDENT_LINK_IMMUTABLE|update'
          USING HINT = '一条链接只在解链接那一次改(带理由),之后不改、不删。要重新链上,就再链一次。';
    END IF;
    RETURN NEW;
END;
$function$;
