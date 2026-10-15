-- db/functions/terms_request_submit_internal.sql
-- APR-8(2026-09-26):提一张条款申请 —— 四扇提交的门各问完自己的码,落进这一支。本支不问码。
--
--   1. 主体要在、这一种要成立:
--        公式:没删(FORMULA_NOT_FOUND);修改要在用(FORMULA_NOT_ACTIVE);新建 / 重新启用要停用着(FORMULA_ALREADY_ACTIVE);
--              拟议条款规范化(formula_terms_normalize);修改而条款与此刻一模一样 → TERMS_REQUEST_NO_CHANGE|编号。
--        合同:没删(CONTRACT_NOT_FOUND);是 draft 或 suspended(CONTRACT_NOT_ACTIVATABLE|编号|状态);
--              合同期已经结束 → CONTRACT_PERIOD_ENDED|编号|截止日。
--              ★ TERMS-EDIT-1(Tim 2026-09-27,grilling Q3):卖方合同条款不齐 → CONTRACT_TERMS_INCOMPLETE|编号|缺的那几条
--              (逗号分隔,见 contract_activation_missing);买方合同不要求。
--              ★ MES-6b-1(V17 · F4):同一种物质既计价又罚 → SUBSTANCE_PRICED_AND_PENALISED|码;声明了按参数的质量验收限而一行都没填
--              → QUALITY_LIMITS_NOT_FILED|编号(两条先于 CONTRACT_TERMS_INCOMPLETE 说)。
--   2. 理由必填(TERMS_REQUEST_REASON_REQUIRED|种类|编号)。
--   3. 同一个主体上已有一张在等 → TERMS_REQUEST_OPEN|编号|那一张(grilling Q5;唯一索引是第二道)。
--   4. ★ 审批开着时:提单人这个【人】之外,二级还有没有人批得动 → TERMS_REQUEST_NO_OTHER_DECIDER|label
--      (assert_other_decider,按人认)。线上 admin@ 与 tim@ 是同一个人,而二级只有 tim@ —— admin@ 提的一律按名拒。
--   5. 落一行 submitted:snapshot 与 fingerprint 冻结;按批准那一刻的同一支试跑(terms_request_dry_run)。
--   6. 审批开着:留痕 submitted,二级。关着:当场生效,状态 approved,留痕 auto_approved。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql;
--       replaced by db/migrations/2026-09-27-terms-edit1-contract-terms-editor.sql (CONTRACT_TERMS_INCOMPLETE);
--       replaced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql (two named refusals).

CREATE OR REPLACE FUNCTION public.terms_request_submit_internal(p_kind text, p_subject uuid, p_proposed jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_missing text[];
    v_pp     text;
    v_on     boolean := approvals_enabled();
    v_id     uuid := gen_random_uuid();
    v_code   text;
    v_active boolean;
    v_status text;
    v_to     date;
    v_prop   jsonb := NULL;
    v_open   text;
    v_n      integer;
    v_label  text;
BEGIN
    IF p_kind IN ('formula_create', 'formula_change', 'formula_reactivate') THEN
        SELECT code, is_active INTO v_code, v_active FROM pricing_formulas
         WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF p_kind = 'formula_change' AND NOT v_active THEN
            RAISE EXCEPTION 'FORMULA_NOT_ACTIVE|%', v_code;
        END IF;
        IF p_kind IN ('formula_create', 'formula_reactivate') AND v_active THEN
            RAISE EXCEPTION 'FORMULA_ALREADY_ACTIVE|%', v_code;
        END IF;
        v_prop := formula_terms_normalize(COALESCE(p_proposed, formula_terms_state(p_subject)));
        IF p_kind = 'formula_change' AND v_prop = formula_terms_state(p_subject) THEN
            RAISE EXCEPTION 'TERMS_REQUEST_NO_CHANGE|%', v_code;
        END IF;
    ELSIF p_kind = 'contract_activate' THEN
        SELECT code, status, effective_to INTO v_code, v_status, v_to FROM contracts
         WHERE id = p_subject AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_NOT_FOUND|%', COALESCE(p_subject::text, '?');
        END IF;
        IF v_status NOT IN ('draft', 'suspended') THEN
            RAISE EXCEPTION 'CONTRACT_NOT_ACTIVATABLE|%|%', v_code, v_status;
        END IF;
        IF v_to IS NOT NULL AND v_to < CURRENT_DATE THEN
            RAISE EXCEPTION 'CONTRACT_PERIOD_ENDED|%|%', v_code, v_to;
        END IF;
        -- ★ MES-6b-1(V17 · F4;Step 0 Q25 · Q33):两条缺失有它们自己的名字 —— 一种物质既计价又罚(条款不一致,先说它),
        --   声明了按参数却没填限(SETTLE-1 ③ 的形状);其余照旧一句 CONTRACT_TERMS_INCOMPLETE 列出缺的那几条。
        v_missing := contract_activation_missing(p_subject);
        SELECT substr(x, length('priced_and_penalised:') + 1) INTO v_pp
          FROM unnest(v_missing) x WHERE x LIKE 'priced\_and\_penalised:%' ORDER BY x LIMIT 1;
        IF v_pp IS NOT NULL THEN
            RAISE EXCEPTION 'SUBSTANCE_PRICED_AND_PENALISED|%', v_pp
              USING HINT = '这份合同把同一种物质既写进了计价条款、又写进了惩罚条款 —— 一种物质要么计价、要么罚。';
        END IF;
        IF 'quality_limits' = ANY (v_missing) THEN
            RAISE EXCEPTION 'QUALITY_LIMITS_NOT_FILED|%', v_code
              USING HINT = '这份合同声明了按参数的质量验收限,却一行限都没有填 —— 【声明了有】与【填了哪些】是两件事。';
        END IF;
        IF cardinality(v_missing) > 0 THEN
            RAISE EXCEPTION 'CONTRACT_TERMS_INCOMPLETE|%|%', v_code, array_to_string(v_missing, ',');
        END IF;
    ELSE
        RAISE EXCEPTION 'TERMS_REQUEST_KIND_UNKNOWN|%', COALESCE(p_kind, '?');
    END IF;

    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'TERMS_REQUEST_REASON_REQUIRED|%|%', p_kind, v_code;
    END IF;

    SELECT r.label INTO v_open FROM terms_requests r
     WHERE r.status = 'submitted' AND (r.formula_id = p_subject OR r.contract_id = p_subject)
     LIMIT 1;
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'TERMS_REQUEST_OPEN|%|%', v_code, v_open;
    END IF;

    -- label:同一个主体上第几张。咨询锁串行化"数一遍 + 1"。
    PERFORM pg_advisory_xact_lock(hashtext('terms_request_label')::bigint);
    SELECT count(*) + 1 INTO v_n FROM terms_requests r
     WHERE COALESCE(r.formula_id, r.contract_id) = p_subject;
    v_label := v_code || ' · ' || CASE p_kind WHEN 'formula_create' THEN 'new'
                                               WHEN 'formula_change' THEN 'change'
                                               WHEN 'formula_reactivate' THEN 'reactivate'
                                               ELSE 'activate' END || ' #' || v_n::text;

    PERFORM assert_other_decider('terms_request', 'decide_terms_request', 2::smallint,
                                 'TERMS_REQUEST_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO terms_requests (id, kind, status, label, formula_id, contract_id, reason, proposed,
                                snapshot, fingerprint, created_by)
    VALUES (v_id, p_kind, 'submitted', v_label,
            CASE WHEN p_kind <> 'contract_activate' THEN p_subject END,
            CASE WHEN p_kind = 'contract_activate' THEN p_subject END,
            btrim(p_reason), v_prop, terms_request_snapshot(p_kind, p_subject, v_prop),
            terms_request_fingerprint(p_kind, p_subject), auth.uid());

    PERFORM terms_request_dry_run(v_id);

    IF v_on THEN
        PERFORM record_approval_decision('terms_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        PERFORM terms_request_execute_internal(v_id);
        UPDATE terms_requests SET status = 'approved', executed_at = now() WHERE id = v_id;
        PERFORM record_approval_decision('terms_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场生效,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'kind', p_kind,
        'subject_code', v_code,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END);
END;
$function$;
