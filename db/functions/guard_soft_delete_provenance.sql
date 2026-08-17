CREATE OR REPLACE FUNCTION public.guard_soft_delete_provenance()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_code text;
BEGIN
    -- 只管【从在册变成已删】那一刻。改别的列、甚至改一个已删行,都不经过这里。
    IF NEW.deleted_at IS NULL OR OLD.deleted_at IS NOT NULL THEN
        RETURN NEW;
    END IF;

    v_code := COALESCE(NEW.code, OLD.code, '?');

    -- ① 必须走门。标记由库内函数设(set_config 住在 pg_catalog,PostgREST
    --    不暴露它,客户端够不着)—— 所以这一条挡的是【直连 UPDATE】那条路。
    IF COALESCE(current_setting('evoltrya.soft_delete_ctx', true), '') <> '1' THEN
        RAISE EXCEPTION 'SOFT_DELETE_NO_DIRECT_UPDATE|%|%', TG_TABLE_NAME, v_code;
    END IF;

    -- ② 门里也不许留空。一个"有时填、有时不填"的审计字段比没有这一列更坏:
    --    它会被读成"这次删除没有人负责"。
    IF NEW.deleted_by IS NULL
       OR NEW.delete_reason IS NULL OR btrim(NEW.delete_reason) = '' THEN
        RAISE EXCEPTION 'DELETE_REASON_REQUIRED|%|%', TG_TABLE_NAME, v_code;
    END IF;

    RETURN NEW;
END;
$function$;
