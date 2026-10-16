-- db/functions/freeze_compliance_pack.sql
-- MES-8b-1(2026-10-17,MES-0 Q82;MES-8 Step 0 Q15 · Q16 · Q17,Tim):【把一个【已关账】月份的合规包冻下来】—— freeze_management_pack 的形状。
--   ★ 它自己不算任何东西:payload 就是 compliance_pack_data(那个月) 的返回值(一份实现,两个调用方)。
--   ★ 只有关账的月份冻得下来(Q15):locked_before > 月末,与 PACK_MONTH_NOT_LOCKED 逐字同源 —— 按名拒并把两个日期都说出来:
--     COMPLIANCE_PACK_MONTH_NOT_LOCKED|<YYYY-MM>|<锁到>。
--   ★ 编号(Q16):CPK-YYYY-MM;同一个月已有一份在册,再冻要写理由(COMPLIANCE_PACK_SUPERSEDE_REASON_REQUIRED|<号>),
--     新的一份是 CPK-YYYY-MM-2(-3 …),旧的那一份【先】落 superseded(部分唯一索引:一个月只许一份在册),它的 payload 与存下的字节一个字不动。
--     没有在册的一份时写了理由:COMPLIANCE_PACK_REASON_WITHOUT_SUPERSEDE(一句没有对象的理由是一句假话)。
--   ★ 门(Q17):action.compliance_pack(cto · admin),它声明 module.compliance.view;payload 来自只要查看码的那一支。
--   没有作废(Q16)。
-- NOTE: introduced by db/migrations/2026-10-17-mes8b1-margin-exposure-and-compliance-pack.sql.
CREATE OR REPLACE FUNCTION public.freeze_compliance_pack(p_period_month date, p_notes text DEFAULT NULL::text, p_supersede_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_start   date;
    v_end     date;
    v_locked  date;
    v_prev    compliance_packs%ROWTYPE;
    v_reason  text := NULLIF(btrim(COALESCE(p_supersede_reason, '')), '');
    v_payload jsonb;
    v_seq     integer;
    v_code    text;
    v_id      uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('action.compliance_pack');
    PERFORM require_permission('module.compliance.view');

    IF p_period_month IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_PERIOD_REQUIRED';
    END IF;
    v_start := date_trunc('month', p_period_month)::date;
    v_end   := (v_start + INTERVAL '1 month - 1 day')::date;

    SELECT locked_before INTO v_locked FROM finance_settings;
    IF v_locked IS NULL OR v_locked <= v_end THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_MONTH_NOT_LOCKED|%|%', to_char(v_start, 'YYYY-MM'), COALESCE(v_locked::text, '—')
          USING HINT = '只有已关账的月份才冻得下来 —— 开放月份看得到实时预览,但那不是一份可以交出去的包;先在月结那一步关账';
    END IF;

    -- 同一个月的编号与在册那一份:咨询锁串行化(freeze_management_pack 的同一个手法)
    PERFORM pg_advisory_xact_lock(hashtext('compliance_pack_' || to_char(v_start, 'YYYY-MM'))::bigint);
    SELECT * INTO v_prev FROM compliance_packs WHERE period_month = v_start AND superseded_at IS NULL;
    IF FOUND AND v_reason IS NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_SUPERSEDE_REASON_REQUIRED|%', v_prev.code
          USING HINT = '这个月已经有一份在册的合规包 —— 再冻一份要说明为什么(重开期间补记了什么?哪一节变了?)';
    END IF;
    IF NOT FOUND AND v_reason IS NOT NULL THEN
        RAISE EXCEPTION 'COMPLIANCE_PACK_REASON_WITHOUT_SUPERSEDE|%', to_char(v_start, 'YYYY-MM');
    END IF;

    v_payload := compliance_pack_data(v_start);

    SELECT COUNT(*) + 1 INTO v_seq FROM compliance_packs WHERE period_month = v_start;
    v_code := document_type_prefix('compliance_pack') || '-' || to_char(v_start, 'YYYY-MM') ||
              CASE WHEN v_seq > 1 THEN '-' || v_seq::text ELSE '' END;

    IF v_prev.id IS NOT NULL THEN
        UPDATE compliance_packs
           SET superseded_at = now(), superseded_by = v_id, superseded_reason = v_reason
         WHERE id = v_prev.id;
    END IF;

    INSERT INTO compliance_packs (id, code, period_month, period_start, period_end, locked_before_at_freeze, payload, notes, frozen_by)
    VALUES (v_id, v_code, v_start, v_start, v_end, v_locked, v_payload, NULLIF(btrim(COALESCE(p_notes, '')), ''), auth.uid());

    RETURN jsonb_build_object('pack_id', v_id, 'code', v_code, 'period_month', v_start, 'period_end', v_end,
                              'locked_before_at_freeze', v_locked, 'superseded', v_prev.code);
END;
$function$
