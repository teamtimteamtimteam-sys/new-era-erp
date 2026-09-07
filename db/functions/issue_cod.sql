CREATE OR REPLACE FUNCTION public.issue_cod(p_cod_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_cod   record;
    v_lic   jsonb;
    v_done  jsonb;
    v_data  jsonb;
    v_code  text;
    v_token uuid;
    v_now   timestamptz;
BEGIN
    IF NOT has_permission('action.issue_cod') THEN
        RAISE EXCEPTION 'PERMISSION_DENIED';
    END IF;

    SELECT c.id, c.inbound_batch_id, c.status, c.completed_on INTO v_cod
      FROM certificates_of_destruction c WHERE c.id = p_cod_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'COD_NOT_FOUND|%', COALESCE(p_cod_id::text, '?');
    END IF;
    IF v_cod.status <> 'pending' THEN
        RAISE EXCEPTION 'COD_ALREADY_ISSUED|%', v_cod.status;
    END IF;

    -- 【签发那一刻再问一次判据】—— 不重写,问同一支函数。
    v_done := cod_delivery_completion(v_cod.inbound_batch_id);
    IF NOT (v_done->>'complete')::boolean THEN
        RAISE EXCEPTION 'CANNOT_CERTIFY|%|%', v_done->>'batch_code', v_done->>'reason';
    END IF;

    -- ── 执照闸(COD-2:两端日期都查)────────────────────────────────────────
    -- 【判据不在这里重写】cod_governing_licence() 是唯一那一份,六句具名拒绝
    -- 也住在那里。这里只负责把它抛出去 —— 而【抛出去的名字必须各不相同】,
    -- 因为补救的办法各不相同(去录一行 / 去补日期 / 去核对到货日期)。
    -- 【不发明任何占位执照号】—— 表今天是空的,所以今天什么都签发不了,而那是对的:
    -- NEA 发照之前 Tim 不会买料。
    v_lic := cod_governing_licence((v_done->>'completed_on')::date);
    IF NOT (v_lic->>'ok')::boolean THEN
        -- 【拒绝要说得出下一步去哪】与 loadDocumentCompany 的 COMPANY_MISSING_MESSAGE
        -- 同一条:一句报不出去处的拒绝,等于把人留在原地。
        RAISE EXCEPTION '%|%', v_lic->>'reason', v_lic->>'detail';
    END IF;

    v_code  := next_cod_code();
    v_token := gen_random_uuid();
    v_now   := clock_timestamp();

    -- 【快照由服务端自己组装,不收调用者递进来的一份】否则冻住的是调用者说的话。
    -- (record_traceability_report_issue 自己调 traceability_report_data,同一条。)
    v_data := cod_certificate_data(v_cod.inbound_batch_id);

    -- 【证书这一块用【真的】签发值覆盖】组装时它还是 pending。
    -- ★ issued_by 只存 uuid,【不解析成人名】★ —— 裁定:纸上没有人名,
    -- "谁处理的"是公司。签发人是一条记录,不是印在证书上的一行。
    v_data := (v_data - 'certificate') || jsonb_build_object(
        'certificate', jsonb_build_object(
            'id', v_cod.id, 'code', v_code, 'status', 'issued',
            'issued_at', v_now, 'issued_by', auth.uid(),
            'verification_token', v_token,
            'completed_on', v_cod.completed_on));

    -- 【任何一格缺了就按名拒,绝不回落去读活行、也绝不印一片空白】(S6 规则二)
    IF v_data->'company'->>'legal_name' IS NULL
       OR btrim(v_data->'company'->>'legal_name') = '' THEN
        RAISE EXCEPTION 'COMPANY_LEGAL_NAME_MISSING|/finance/company';
    END IF;
    IF v_data->'supplier'->>'name' IS NULL THEN
        RAISE EXCEPTION 'SUPPLIER_NAME_MISSING|%', v_data->'inbound_batch'->>'code';
    END IF;
    -- 【第二道,刻意留着】上面的闸已经过了,这一句问的是"组装出来的那一份里
    -- 到底有没有那一格" —— 两句问的不是同一件事,而快照是核验页几年后的唯一依据。
    IF v_data->'licence' = 'null'::jsonb OR v_data->'licence' IS NULL THEN
        RAISE EXCEPTION 'COD_LICENCE_NOT_RECORDED|/purchasing/licences';
    END IF;

    UPDATE certificates_of_destruction
       SET status = 'issued', code = v_code, verification_token = v_token,
           snapshot = v_data, issued_at = v_now, issued_by = auth.uid()
     WHERE id = p_cod_id;

    RETURN jsonb_build_object(
        'cod_id', v_cod.id, 'code', v_code, 'status', 'issued',
        'verification_token', v_token, 'issued_at', v_now,
        'batch_code', v_data->'inbound_batch'->>'code');
END;
$function$;
