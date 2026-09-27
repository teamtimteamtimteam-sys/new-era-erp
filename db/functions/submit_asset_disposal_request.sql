-- db/functions/submit_asset_disposal_request.sql
-- APR-9(2026-09-27):财务提一张固定资产处置申请。CFO 批准才处置(Tim 的矩阵 §4,不分档;grilling Q7 · Q8 · Q10)。
--
-- 【门】module.finance.edit(处置原来的门)。
-- 【拒绝,按这个顺序】
--   ASSET_NOT_FOUND · ASSET_ALREADY_DISPOSED|<code>
--   ASSET_DISPOSAL_REASON_REQUIRED|<code>
--   PROCEEDS_INVALID · BANK_INVALID|<科目>            收款与银行科目提交时冻结(dispose 的同一句话)
--   ASSET_DISPOSAL_OPEN|<code>|<那一张>               一台资产同一时刻只挂一张在等的申请(唯一索引是第二道)
--   ASSET_DISPOSAL_NO_OTHER_DECIDER|<label>           审批开着、提单人这个人之外二级没人批得动(assert_other_decider;
--                                                     线上是 admin@:它与 tim@ 是同一个人)
--   …以及试跑按原话冒出来的一切(ASSET_HAS_NO_COST · PERIOD_LOCKED …)
-- 【试跑】落一行 submitted,按批准那一刻的同一支试跑(处置日 = 今天),estimate 与 amount_base 取试跑的结果。
-- 审批开着:留痕 submitted,二级。关着:当场处置,状态 approved,留痕 auto_approved(APR-7 同形,Q10)。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.submit_asset_disposal_request(p_asset_id uuid, p_proceeds numeric, p_bank_account text, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_on    boolean := approvals_enabled();
    v_id    uuid := gen_random_uuid();
    v_a     fixed_assets%ROWTYPE;
    v_bank  text;
    v_open  text;
    v_n     integer;
    v_label text;
    v_dry   jsonb;
    v_exec  jsonb := NULL;
BEGIN
    PERFORM require_permission('module.finance.edit');

    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', COALESCE(p_asset_id::text, '?');
    END IF;
    IF v_a.status <> 'active' THEN
        RAISE EXCEPTION 'ASSET_ALREADY_DISPOSED|%', v_a.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_REASON_REQUIRED|%', v_a.code;
    END IF;
    IF p_proceeds IS NULL OR p_proceeds < 0 THEN
        RAISE EXCEPTION 'PROCEEDS_INVALID';
    END IF;
    IF p_proceeds > 0 THEN
        IF p_bank_account IS NULL OR p_bank_account NOT IN ('1000', '1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
        END IF;
        v_bank := p_bank_account;
    END IF;

    SELECT q.label INTO v_open FROM asset_disposal_requests q
     WHERE q.asset_id = v_a.id AND q.status = 'submitted' LIMIT 1;
    IF v_open IS NOT NULL THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_OPEN|%|%', v_a.code, v_open;
    END IF;

    SELECT count(*) + 1 INTO v_n FROM asset_disposal_requests q WHERE q.asset_id = v_a.id;
    v_label := v_a.code || ' · disposal #' || v_n::text;

    PERFORM assert_other_decider('asset_disposal_request', 'decide_asset_disposal_request', 2::smallint,
                                 'ASSET_DISPOSAL_NO_OTHER_DECIDER|' || v_label);

    INSERT INTO asset_disposal_requests (id, status, label, asset_id, proceeds_base, bank_account, reason,
                                         snapshot, estimate, amount_base, created_by)
    VALUES (v_id, 'submitted', v_label, v_a.id, p_proceeds, v_bank, btrim(p_reason),
            asset_disposal_fingerprint(v_a.id), '{}'::jsonb, 0, auth.uid());

    v_dry := asset_disposal_dry_run(v_id);
    UPDATE asset_disposal_requests
       SET estimate = v_dry, amount_base = (v_dry->>'amount_base')::numeric
     WHERE id = v_id;

    IF v_on THEN
        PERFORM record_approval_decision('asset_disposal_request', v_id, 'submitted', 2::smallint, NULL);
    ELSE
        v_exec := asset_disposal_execute_internal(v_id);
        UPDATE asset_disposal_requests
           SET status = 'approved', executed_at = now(), disposal_date = (v_exec->>'disposal_date')::date,
               result_entry_id = (v_exec->>'entry_id')::uuid, result = v_exec,
               amount_base = (v_exec->>'amount_base')::numeric
         WHERE id = v_id;
        PERFORM record_approval_decision('asset_disposal_request', v_id, 'auto_approved', NULL,
                                         '审批关着时提交:申请生下来就是 approved 并当场处置,没有人按过批准');
    END IF;

    RETURN jsonb_build_object(
        'request_id', v_id,
        'label', v_label,
        'status', CASE WHEN v_on THEN 'submitted' ELSE 'approved' END,
        'estimate', v_dry,
        'amount_base', COALESCE(v_exec->'amount_base', v_dry->'amount_base'));
END;
$function$;
