-- db/functions/dispose_fixed_asset_internal.sql
-- APR-9(2026-09-27):处置的【引擎】—— 原 dispose_fixed_asset 的函数体,一个字没改,只拿掉了门(FIN-22 的全部规矩照旧:
-- 1500 按成本解除、1510 按累计折旧解除,差额对净收款进 7200;收款 > 0 必须给银行科目;零成本的卡按名拒;
-- 【不自动补提】处置月折旧)。只从 asset_disposal_execute_internal 调用(批准、审批关着时的提交、提交时的试跑)。
-- 分录的 created_by 是调用那一刻的 auth.uid() —— 批准时就是批的 CFO(过账发生在批准那一刻,APR-7 Q6 同一条)。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-27-apr9-salary-changes-and-asset-disposals-wait-for-approval.sql.

CREATE OR REPLACE FUNCTION public.dispose_fixed_asset_internal(p_asset_id uuid, p_disposal_date date, p_proceeds numeric DEFAULT 0, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user   uuid := auth.uid();
    v_a      record;
    v_accum  numeric;
    v_gain   numeric;
    v_bank   text;
    v_lines  jsonb := '[]'::jsonb;
    v_je     jsonb;
BEGIN
    IF p_disposal_date IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    SELECT * INTO v_a FROM fixed_assets WHERE id = p_asset_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ASSET_NOT_FOUND|%', p_asset_id;
    END IF;
    IF v_a.status <> 'active' THEN
        RAISE EXCEPTION 'ASSET_ALREADY_DISPOSED|%', v_a.code;
    END IF;
    -- EQP-1c-a:【零成本的卡处置不了 —— 而这一条是本刀自己造出来的路,所以本刀关它】
    -- 下面那条 1500 贷方是【无条件】发出的,金额就是 cost_base;而
    -- journal_lines_amount_ccy_check 是 CHECK (amount_ccy > 0)。于是处置一张
    -- 零成本卡会撞出一条【裸的 23514】,而不是一句人话。
    -- 【为什么不改成"金额为 0 就不发那条行"】那会让处置【悄悄成功】,
    -- 把一张"还没买成的机器"变成一张"已处置"的资产 —— 而这两件事在账上
    -- 完全不是一回事。一张还没有成本的卡要退场,那是【取消一次采购承诺】,
    -- 不是【处置一台资产】,而那条路今天不存在(docs/known-issues.md 有记录)。
    -- 与 set_asset_in_service 用同一个码:同一句话 —— 这张卡还不是一台资产。
    IF v_a.cost_base = 0 THEN
        RAISE EXCEPTION 'ASSET_HAS_NO_COST|%', v_a.code
          USING HINT = '这张卡还没有任何成本,不构成一次处置 —— 它要退场是另一件事,今天没有那条路';
    END IF;
    IF p_disposal_date < v_a.acquisition_date THEN
        RAISE EXCEPTION 'DISPOSAL_BEFORE_ACQUISITION|%|%', p_disposal_date, v_a.acquisition_date;
    END IF;
    IF p_proceeds IS NULL OR p_proceeds < 0 THEN
        RAISE EXCEPTION 'PROCEEDS_INVALID';
    END IF;
    IF p_proceeds > 0 THEN
        IF p_bank_account IS NULL OR p_bank_account NOT IN ('1000','1010') THEN
            RAISE EXCEPTION 'BANK_INVALID|%', COALESCE(p_bank_account, '?');
        END IF;
        v_bank := p_bank_account;
    END IF;

    SELECT COALESCE(SUM(amount_base), 0) INTO v_accum
    FROM fixed_asset_depreciation WHERE asset_id = p_asset_id;

    -- 损益 = 净收款 + 累计折旧 − 成本(>0 益,<0 损)
    v_gain := round(p_proceeds + v_accum - v_a.cost_base, 2);

    IF p_proceeds > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', v_bank, 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', p_proceeds, 'line_memo', 'disposal proceeds');
    END IF;
    IF v_accum > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '1510', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', v_accum, 'line_memo', 'accumulated depreciation relieved');
    END IF;
    v_lines := v_lines || jsonb_build_object('account_code', '1500', 'side', 'credit',
        'currency', base_currency_code(), 'amount_ccy', v_a.cost_base, 'line_memo', 'cost relieved');
    IF v_gain > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'credit',
            'currency', base_currency_code(), 'amount_ccy', v_gain);
    ELSIF v_gain < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'debit',
            'currency', base_currency_code(), 'amount_ccy', -v_gain);
    END IF;

    v_je := post_journal_entry(p_disposal_date,
        'Disposal ' || v_a.code || COALESCE(' — ' || p_notes, ''),
        'asset_disposal', p_asset_id, v_lines);

    UPDATE fixed_assets
    SET status = 'disposed', disposal_date = p_disposal_date,
        disposal_proceeds_base = p_proceeds, disposal_journal_id = (v_je->>'entry_id')::uuid
    WHERE id = p_asset_id;

    RETURN jsonb_build_object('asset_id', p_asset_id, 'code', v_a.code,
        'cost_relieved', v_a.cost_base, 'accum_relieved', v_accum,
        'proceeds', p_proceeds, 'gain_loss', v_gain, 'journal_code', v_je->>'code');
END;
$function$;
