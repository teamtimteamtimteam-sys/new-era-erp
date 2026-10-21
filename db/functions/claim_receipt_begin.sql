-- db/functions/claim_receipt_begin.sql
-- CLAIM-RECEIPTS-1(Tim 2026-10-21,Step 0 Q1 · Q4 · Q10):【给报销单的一笔开始传一份收据】—— 在【任何一个字节存下之前】判完,过了才登记一行、
--   给出私有桶 claim-receipts 里的路径。MES-9c portal_submission_begin 的形状(先判、再登记、字节由浏览器直传、finish 确认)。
--   依次按名拒(第一条不过就停,什么都不写):
--     这一笔不存在                                         → CLAIM_RECEIPT_ITEM_NOT_FOUND
--     调用者不是这张单说的员工、也不是替他提单的人(Q4)    → CLAIM_RECEIPT_NOT_YOURS|<单号>
--     单不在 submitted(Q4:只在提交之后、决定之前)        → CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|<单号>|<状态>
--     上限没给(门户那两列任一为空 —— Q1:与门户同一个数)  → CLAIM_RECEIPT_LIMITS_NOT_SET
--     文件类型不在上限里(HEIC / Word / Excel 都落在这里)   → CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|<类型>
--     大小 ≤ 0 / 超过上限                                 → CLAIM_RECEIPT_EMPTY / CLAIM_RECEIPT_TOO_LARGE|<上限字节数>
--     文件名空                                             → CLAIM_RECEIPT_NAME_REQUIRED
--     整个项目的存储已到 900 MB(Q10,免费方案 1 GB)        → CLAIM_RECEIPT_STORAGE_FULL|<已用字节数>|<上限字节数>
--   过了:写一行 status = uploading(路径 = <单 id>/<笔 id>/<这一行的 id>.<扩展名>,扩展名由类型定,不取文件名里的),回 id · 桶 · 路径。
--   【900 MB 是 Tim 的数,写在这里而不是一张设置表里】它只活到付费方案(Q10:"Nothing else until the paid plan");
--   到那天删掉这一条,而不是把它调大。数的是 storage.objects 每一个对象 metadata 里的 size(所有桶)。
--   EXECUTE 授 authenticated(zzz_function_grants.sql);调用者在函数体里判。
-- NOTE: introduced by db/migrations/2026-10-21-claim-receipts-1.sql.
CREATE OR REPLACE FUNCTION public.claim_receipt_begin(p_item_id uuid, p_file_name text, p_file_type text, p_file_size bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_item    expense_claim_items%ROWTYPE;
    v_c       expense_claims%ROWTYPE;
    v_max     bigint;
    v_types   text[];
    v_used    bigint;
    v_ceiling constant bigint := 943718400;   -- 900 MB(Tim Q10)
    v_id      uuid := gen_random_uuid();
    v_ext     text;
    v_path    text;
    v_name    text := left(btrim(regexp_replace(COALESCE(p_file_name, ''), '[\\/[:cntrl:]]+', '_', 'g')), 200);
BEGIN
    SELECT * INTO v_item FROM expense_claim_items WHERE id = p_item_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_ITEM_NOT_FOUND';
    END IF;
    SELECT * INTO v_c FROM expense_claims WHERE id = v_item.claim_id FOR UPDATE;
    IF NOT COALESCE(v_c.employee_id = current_user_employee() OR v_c.created_by = auth.uid(), false) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NOT_YOURS|%', v_c.code;
    END IF;
    IF v_c.status <> 'submitted' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_CLAIM_NOT_SUBMITTED|%|%', v_c.code, v_c.status;
    END IF;
    SELECT a.portal_upload_max_bytes, a.portal_upload_types INTO v_max, v_types FROM account_settings a WHERE a.id;
    IF v_max IS NULL OR v_types IS NULL THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_LIMITS_NOT_SET';
    END IF;
    IF p_file_type IS NULL OR NOT (p_file_type = ANY (v_types)) THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_TYPE_NOT_ACCEPTED|%', COALESCE(p_file_type, '');
    END IF;
    IF p_file_size IS NULL OR p_file_size <= 0 THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_EMPTY';
    END IF;
    IF p_file_size > v_max THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_TOO_LARGE|%', v_max;
    END IF;
    IF v_name = '' THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_NAME_REQUIRED';
    END IF;
    SELECT COALESCE(sum((o.metadata ->> 'size')::bigint), 0) INTO v_used FROM storage.objects o;
    IF v_used + p_file_size > v_ceiling THEN
        RAISE EXCEPTION 'CLAIM_RECEIPT_STORAGE_FULL|%|%', v_used, v_ceiling;
    END IF;
    v_ext := CASE p_file_type WHEN 'application/pdf' THEN 'pdf' WHEN 'image/jpeg' THEN 'jpg' WHEN 'image/png' THEN 'png' ELSE 'bin' END;
    v_path := v_c.id::text || '/' || v_item.id::text || '/' || v_id::text || '.' || v_ext;
    INSERT INTO expense_claim_receipts (id, claim_id, item_id, file_name, file_type, file_size, storage_path, created_by)
    VALUES (v_id, v_c.id, v_item.id, v_name, p_file_type, p_file_size, v_path, auth.uid());
    RETURN jsonb_build_object('id', v_id, 'bucket', 'claim-receipts', 'path', v_path);
END;
$function$;
