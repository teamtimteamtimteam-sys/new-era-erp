-- db/functions/guard_contract_file_write.sql
-- CONTRACT-ESIGN(Tim 2026-10-30 Q1 · Q7):contract_files 的守卫 —— 一个版本存下之后,它的字节、哈希、签署人、样本、印章与位置一个都不许改。
--   只放这几步(其余任何一列变了 → CONTRACT_FILE_IMMUTABLE|<id>):
--     uploading → current     存下:sha256 · file_size · stored_at 从空到有
--     uploading → abandoned   没传成
--     current   → superseded  只有 original,被新的一份替换:superseded_at
--     current   → void        只有 signed / countersigned:voided_at · voided_by · void_reason
--   删行只放两种:还在 uploading / abandoned 的一行;以及【合同本身已经不在了】(合同被删 → 级联下来;只有属主路径删得掉合同)。
--   别的删除 → CONTRACT_FILE_NO_DELETE|<id>。属主路径也挡(与 COD 的存档表同一条:函数之外的路也不许改一份签过的文件)。
-- NOTE: introduced by db/migrations/2026-10-30-contract-esign.sql.
CREATE OR REPLACE FUNCTION public.guard_contract_file_write()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_changed text[];
    v_allowed text[];
BEGIN
    IF TG_OP = 'DELETE' THEN
        IF OLD.status IN ('uploading', 'abandoned') OR NOT EXISTS (SELECT 1 FROM contracts c WHERE c.id = OLD.contract_id) THEN
            RETURN OLD;
        END IF;
        RAISE EXCEPTION 'CONTRACT_FILE_NO_DELETE|%', OLD.id;
    END IF;
    SELECT COALESCE(array_agg(n.key ORDER BY n.key), ARRAY[]::text[]) INTO v_changed
      FROM jsonb_each(to_jsonb(NEW)) n
      JOIN jsonb_each(to_jsonb(OLD)) o ON o.key = n.key
     WHERE n.value IS DISTINCT FROM o.value;
    v_allowed := CASE
        WHEN OLD.status = 'uploading' AND NEW.status = 'current' THEN ARRAY['status', 'sha256', 'file_size', 'stored_at']
        WHEN OLD.status = 'uploading' AND NEW.status = 'abandoned' THEN ARRAY['status']
        WHEN OLD.status = 'current' AND NEW.status = 'superseded' AND OLD.kind = 'original' THEN ARRAY['status', 'superseded_at']
        WHEN OLD.status = 'current' AND NEW.status = 'void' AND OLD.kind IN ('signed', 'countersigned')
            THEN ARRAY['status', 'voided_at', 'voided_by', 'void_reason']
        ELSE NULL END;
    IF v_allowed IS NULL OR NOT (v_changed <@ v_allowed)
       OR (OLD.status = 'uploading' AND NEW.status = 'current' AND OLD.sha256 IS NOT NULL)
       OR (OLD.status = 'uploading' AND NEW.status = 'current' AND OLD.file_size IS NOT NULL AND 'file_size' = ANY (v_changed)) THEN
        RAISE EXCEPTION 'CONTRACT_FILE_IMMUTABLE|%', OLD.id;
    END IF;
    RETURN NEW;
END;
$function$;
