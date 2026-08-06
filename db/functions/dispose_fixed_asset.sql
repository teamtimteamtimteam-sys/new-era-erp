-- db/functions/dispose_fixed_asset.sql
-- 处置:出售或报废(FIN-22)。1500 按成本解除、1510 按累计折旧解除,差额对净收款
-- 进 7200(与 7100/7110 同形,两个方向都过)。收款 > 0 必须给银行科目;报废收款 0。
-- 【不自动补提】处置月折旧 —— 想提就先跑月度例程再处置;未提部分如实进损益。

CREATE OR REPLACE FUNCTION public.dispose_fixed_asset(p_asset_id uuid, p_disposal_date date, p_proceeds numeric DEFAULT 0, p_bank_account text DEFAULT NULL::text, p_notes text DEFAULT NULL::text)
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
    PERFORM require_permission('module.finance.edit');
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
            'currency', 'SGD', 'amount_ccy', p_proceeds, 'fx_rate', 1, 'line_memo', 'disposal proceeds');
    END IF;
    IF v_accum > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '1510', 'side', 'debit',
            'currency', 'SGD', 'amount_ccy', v_accum, 'fx_rate', 1, 'line_memo', 'accumulated depreciation relieved');
    END IF;
    v_lines := v_lines || jsonb_build_object('account_code', '1500', 'side', 'credit',
        'currency', 'SGD', 'amount_ccy', v_a.cost_base, 'fx_rate', 1, 'line_memo', 'cost relieved');
    IF v_gain > 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'credit',
            'currency', 'SGD', 'amount_ccy', v_gain, 'fx_rate', 1);
    ELSIF v_gain < 0 THEN
        v_lines := v_lines || jsonb_build_object('account_code', '7200', 'side', 'debit',
            'currency', 'SGD', 'amount_ccy', -v_gain, 'fx_rate', 1);
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
