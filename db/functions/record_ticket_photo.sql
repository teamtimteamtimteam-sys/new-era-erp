-- db/functions/record_ticket_photo.sql
-- MES-2(2026-10-06,MES-0 Q20;MES-2 Step 0 Q21,Tim):【登记一张地磅单照片】—— 文件已经由浏览器传进私有桶 capture-photos,
--   这里落它的登记行。持 action.confirm_capture(与桶的上传策略同一个码)。单要在、没作废(TICKET_NOT_FOUND · TICKET_VOIDED);
--   路径必须是 <单 id>/…(TICKET_PHOTO_PATH_INVALID);类型只收 jpeg / png / webp(TICKET_PHOTO_TYPE_INVALID);
--   ≤ 10 MB(TICKET_PHOTO_TOO_LARGE)。服务端动作在调它之前还会再核一次类型;桶本身只收这三种类型、≤ 10 MB,
--   而桶里的对象谁都删不了(没有 DELETE 策略)—— 所以一个被这里拒掉的对象会留在桶里、没有登记行(交回报告记着)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.

CREATE OR REPLACE FUNCTION public.record_ticket_photo(p_ticket_id uuid, p_file_path text, p_file_name text, p_mime_type text, p_size_bytes integer)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tk weighbridge_tickets%ROWTYPE;
    v_id uuid;
BEGIN
    PERFORM require_permission('action.confirm_capture');
    SELECT * INTO v_tk FROM weighbridge_tickets WHERE id = p_ticket_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TICKET_NOT_FOUND|%', COALESCE(p_ticket_id::text, '?');
    END IF;
    IF v_tk.voided_at IS NOT NULL THEN
        RAISE EXCEPTION 'TICKET_VOIDED|%', v_tk.code;
    END IF;
    IF p_file_path IS NULL OR p_file_path NOT LIKE p_ticket_id::text || '/%' OR btrim(COALESCE(p_file_name, '')) = '' THEN
        RAISE EXCEPTION 'TICKET_PHOTO_PATH_INVALID';
    END IF;
    IF p_mime_type IS NULL OR p_mime_type NOT IN ('image/jpeg', 'image/png', 'image/webp') THEN
        RAISE EXCEPTION 'TICKET_PHOTO_TYPE_INVALID|%', COALESCE(p_mime_type, '?');
    END IF;
    IF p_size_bytes IS NULL OR p_size_bytes <= 0 OR p_size_bytes > 10485760 THEN
        RAISE EXCEPTION 'TICKET_PHOTO_TOO_LARGE|%', COALESCE(p_size_bytes::text, '?');
    END IF;
    INSERT INTO weighbridge_ticket_photos (ticket_id, file_path, file_name, mime_type, size_bytes, uploaded_by)
    VALUES (p_ticket_id, p_file_path, btrim(p_file_name), p_mime_type, p_size_bytes, auth.uid())
    RETURNING id INTO v_id;
    RETURN v_id;
END;
$function$;
