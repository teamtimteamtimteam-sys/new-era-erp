-- db/functions/portal_certificates.sql
-- MES-9c(2026-10-20,MES-9 Step 0 §4 · §5 · Q19 · V39,Tim):【门户的证书一页】—— 调用者自己那一家的在册证书,与它自己交上来的每一份及其状态。
--   先过 portal_require_link()(角色 · 链接 · 撤销 · 会话);供应商只从链接推出来,没有任何参数。
--   回:
--     compliance  它那一家在册的合规证书(supplier_compliance,没删的):类型 · 号 · 有效期至(§4 —— 不回备注、发证机构、谁录的)
--     submissions 它【自己这个账号】交上来的每一份(uploading 与 abandoned 不列 —— 那是传到一半与没传成的,没有东西可等):
--                 类型 · 号 · 有效期 · 文件名 · 交上来的时刻 · 状态(waiting / accepted / rejected)· 驳回理由(Q19:供应商看得见)·
--                 决定的时刻。【不回谁决定的】(员工的名字不给门户,§4)
--     types       可以交的证书类型(certificate_types 里启用的:码 · 英文名 · 中文名)—— 门户角色读不到那张表,所以这里给
--     limits      V39:每份最大字节数与收的文件类型(account_settings);任一为空 → set = false,上传会按名拒
--   别家的一个字都不回;一个价钱都没有。
--   EXECUTE 只授 supplier_portal(zzz_function_grants.sql;db/portal-grants-baseline.tsv,判词八)。
-- NOTE: introduced by db/migrations/2026-10-20-mes9c-certificate-uploads.sql.
CREATE OR REPLACE FUNCTION public.portal_certificates()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_link     uuid := portal_require_link();
    v_supplier uuid;
    v_max      bigint;
    v_types    text[];
BEGIN
    SELECT p.supplier_id INTO v_supplier FROM supplier_portal_users p WHERE p.id = v_link;
    SELECT a.portal_upload_max_bytes, a.portal_upload_types INTO v_max, v_types FROM account_settings a WHERE a.id;
    RETURN jsonb_build_object(
        'supplier_code', (SELECT s.code FROM suppliers s WHERE s.id = v_supplier),
        'compliance', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'cert_type_code', c.cert_type_code,
                       'type_name_en', ct.name_en,
                       'type_name_zh', ct.name_zh,
                       'cert_no', c.cert_no,
                       'valid_until', c.valid_until)
                   ORDER BY ct.sort_order, c.valid_until DESC NULLS LAST, c.created_at DESC)
              FROM supplier_compliance c JOIN certificate_types ct ON ct.code = c.cert_type_code
             WHERE c.supplier_id = v_supplier AND c.deleted_at IS NULL), '[]'::jsonb),
        'submissions', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', s.id,
                       'cert_type_code', s.cert_type_code,
                       'type_name_en', ct.name_en,
                       'type_name_zh', ct.name_zh,
                       'cert_no', s.cert_no,
                       'valid_from', s.valid_from,
                       'valid_until', s.valid_until,
                       'file_name', s.file_name,
                       'submitted_at', s.submitted_at,
                       'state', CASE s.status WHEN 'submitted' THEN 'waiting' ELSE s.status END,
                       'reject_reason', CASE WHEN s.status = 'rejected' THEN s.reject_reason END,
                       'decided_at', s.decided_at)
                   ORDER BY s.submitted_at DESC)
              FROM portal_certificate_submissions s JOIN certificate_types ct ON ct.code = s.cert_type_code
             WHERE s.portal_user_id = v_link AND s.status IN ('submitted', 'accepted', 'rejected')), '[]'::jsonb),
        'types', COALESCE((
            SELECT jsonb_agg(jsonb_build_object('code', ct.code, 'name_en', ct.name_en, 'name_zh', ct.name_zh) ORDER BY ct.sort_order, ct.code)
              FROM certificate_types ct WHERE ct.is_active), '[]'::jsonb),
        'limits', jsonb_build_object('set', v_max IS NOT NULL AND v_types IS NOT NULL, 'max_bytes', v_max, 'types', to_jsonb(v_types)));
END;
$function$;
