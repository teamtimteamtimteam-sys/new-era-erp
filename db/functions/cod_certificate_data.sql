CREATE OR REPLACE FUNCTION public.cod_certificate_data(p_inbound_batch_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ib   record;
    v_comp record;
    v_lic  record;
    v_cod  record;
    v_done jsonb;
    v_runs jsonb;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    IF p_inbound_batch_id IS NULL THEN
        RAISE EXCEPTION 'BATCH_REQUIRED';
    END IF;

    SELECT ib.id, ib.code, ib.quantity, ib.unit, ib.arrival_date,
           m.code AS material_code, m.name AS material_name,
           s.legal_name AS supplier_name, s.code AS supplier_code,
           po.code AS purchase_order_code
      INTO v_ib
      FROM inbound_batches ib
      LEFT JOIN materials m       ON m.id  = ib.material_id
      LEFT JOIN suppliers s       ON s.id  = ib.supplier_id
      LEFT JOIN purchase_orders po ON po.id = ib.purchase_order_id
     WHERE ib.id = p_inbound_batch_id;

    -- 【三条拒绝是有序的,而顺序本身是内容】先分清"这个 id 根本不是批次"与
    -- "它是个批次、但是产出批"—— 后者是拿产出批的 id 来要销毁证书,一个可以
    -- 理解的错,它值得一句说得清的话。(与 traceability_report_data 同形,方向相反。)
    IF NOT FOUND THEN
        IF EXISTS (SELECT 1 FROM output_batches ob WHERE ob.id = p_inbound_batch_id) THEN
            RAISE EXCEPTION 'NOT_AN_INBOUND_BATCH|%',
                (SELECT ob.code FROM output_batches ob WHERE ob.id = p_inbound_batch_id);
        END IF;
        RAISE EXCEPTION 'BATCH_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    -- 【第四个状态:组装不出来】判据不在这里重写一遍 —— 只有那一支说了算,
    -- 在这里再写一遍就是让同一件事有两处实现(而它们迟早各说各话)。
    v_done := cod_delivery_completion(p_inbound_batch_id);
    IF NOT (v_done->>'complete')::boolean THEN
        RAISE EXCEPTION 'CANNOT_CERTIFY|%|%', v_ib.code, v_done->>'reason';
    END IF;

    -- 公司抬头的【文字】部分。★ 印在纸上的抬头与 logo 仍然由
    -- loadDocumentCompany() 决定(裁定如此,八份对外单据都走它)★ ——
    -- 这里取的是要【冻进 snapshot】的那一份,核验页几年后靠它渲染。
    SELECT cp.legal_name, cp.registration_no, cp.address_lines, cp.city,
           cp.postal_code, cp.country, cp.phone, cp.email, cp.website
      INTO v_comp FROM company_profile cp LIMIT 1;

    -- 【执照:在组装时【读】company_compliance,不是读一个设置开关】
    -- 于是把真正的 GWDF 号录进去那一天,之后每一张证书自动带上它 ——
    -- 不用改一行代码,也没有任何要有人记得去翻的开关。
    -- ★ status IS NULL 是【没有人说过】,不是 active ★(与
    -- approved_storage_limit_tonnes 的那条注释同一句话)。
    SELECT cc.cert_no, cc.issuing_body, cc.valid_from, cc.valid_until, cc.status, cc.scope
      INTO v_lic
      FROM company_compliance cc
     WHERE cc.cert_type_code = 'gwdf'
       AND cc.deleted_at IS NULL
       AND cc.status = 'active'
       AND cc.cert_no IS NOT NULL AND btrim(cc.cert_no) <> ''
     ORDER BY cc.valid_until DESC NULLS LAST
     LIMIT 1;

    SELECT c.id, c.code, c.status, c.issued_at, c.verification_token,
           c.void_reason, c.voided_at
      INTO v_cod
      FROM certificates_of_destruction c
     WHERE c.inbound_batch_id = p_inbound_batch_id AND c.status <> 'void';

    -- 【出处:只回答"这来自哪些行",不印在纸上、也不许被回查内容】
    SELECT COALESCE(jsonb_agg(DISTINCT r.id), '[]'::jsonb) INTO v_runs
      FROM processing_inputs pi JOIN processing_runs r ON r.id = pi.run_id
     WHERE pi.inbound_batch_id = p_inbound_batch_id AND r.deleted_at IS NULL;

    RETURN jsonb_build_object(
        'inbound_batch', jsonb_build_object(
            'id', v_ib.id, 'code', v_ib.code,
            'material_code', v_ib.material_code, 'material_name', v_ib.material_name,
            'quantity', v_ib.quantity, 'unit', v_ib.unit,
            'arrival_date', v_ib.arrival_date,
            'purchase_order_code', v_ib.purchase_order_code),
        -- 【只有名字与编号】—— 能力够得着的正好是证书需要的,不多一格。
        'supplier', jsonb_build_object(
            'name', v_ib.supplier_name, 'code', v_ib.supplier_code),
        'processing', jsonb_build_object(
            'completed_on', v_done->>'completed_on'),
        'company', jsonb_build_object(
            'legal_name', v_comp.legal_name, 'registration_no', v_comp.registration_no,
            'address_lines', v_comp.address_lines, 'city', v_comp.city,
            'postal_code', v_comp.postal_code, 'country', v_comp.country,
            'phone', v_comp.phone, 'email', v_comp.email, 'website', v_comp.website),
        -- 【执照缺席是一个具名状态,不是空白】内部存档照印这一格,标成"未记录";
        -- 签发则被 issue_cod() 按名拒。
        'licence', CASE WHEN v_lic.cert_no IS NULL THEN NULL ELSE jsonb_build_object(
            'cert_no', v_lic.cert_no, 'issuing_body', v_lic.issuing_body,
            'valid_from', v_lic.valid_from, 'valid_until', v_lic.valid_until,
            'scope', v_lic.scope) END,
        'certificate', CASE WHEN v_cod.id IS NULL THEN NULL ELSE jsonb_build_object(
            'id', v_cod.id, 'code', v_cod.code, 'status', v_cod.status,
            'issued_at', v_cod.issued_at,
            'verification_token', v_cod.verification_token) END,
        'provenance', jsonb_build_object('run_ids', v_runs)
    );
END;
$function$;
