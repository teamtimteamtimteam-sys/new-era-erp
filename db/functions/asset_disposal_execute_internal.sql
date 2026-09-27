-- db/functions/asset_disposal_execute_internal.sql
-- APR-9(2026-09-27):让一张处置申请【生效】—— 批准、审批关着时的提交、提交时的试跑,三处都走这一支,
-- 所以试跑拒的与批准拒的是同一句话。
--   1. 资产行上锁;fingerprint 再比(Q8)—— 变了 → ASSET_CHANGED_SINCE_REQUEST|label。
--   2. 处置日 = 今天(Q7:批准那一天;试跑时是提交那一天),收款与银行科目取申请上冻结的那一组,
--      摘要尾巴 = 提单人的理由。dispose_fixed_asset_internal 过账并把卡置为 disposed。
-- 【冻结放行】evoltrya.asset_disposal_ctx = 本申请 id,guard_asset_disposal_freeze 只放这一张申请自己的写。
-- 返回 dispose 的结果(成本、累计折旧、收款、损益、分录编号),外加 disposal_date、entry_id 与 amount_base
-- (处置分录的借方合计,本位币)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.asset_disposal_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r     asset_disposal_requests%ROWTYPE;
    v_res   jsonb;
    v_entry uuid;
    v_amt   numeric;
BEGIN
    SELECT * INTO v_r FROM asset_disposal_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_DISPOSAL_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    PERFORM 1 FROM fixed_assets WHERE id = v_r.asset_id FOR UPDATE;
    IF asset_disposal_fingerprint(v_r.asset_id) IS DISTINCT FROM v_r.snapshot THEN
        RAISE EXCEPTION 'ASSET_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    PERFORM set_config('evoltrya.asset_disposal_ctx', v_r.id::text, true);
    v_res := dispose_fixed_asset_internal(v_r.asset_id, CURRENT_DATE, v_r.proceeds_base, v_r.bank_account, v_r.reason);
    PERFORM set_config('evoltrya.asset_disposal_ctx', '', true);

    SELECT a.disposal_journal_id INTO v_entry FROM fixed_assets a WHERE a.id = v_r.asset_id;
    SELECT COALESCE(round(sum(l.debit), 2), 0) INTO v_amt FROM journal_lines l WHERE l.entry_id = v_entry;

    RETURN v_res || jsonb_build_object('disposal_date', CURRENT_DATE, 'entry_id', v_entry, 'amount_base', v_amt);
END;
$function$;
