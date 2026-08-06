-- db/functions/depreciate_fixed_assets.sql
-- 月度直线折旧(FIN-22)。幂等靠【算术】不靠闸:应提 = 目标累计 − Σ 已提,
-- 同期第二次跑差额 0 → 不过账、不留行。期末日期必填(DATE_REQUIRED,FIN-10 规矩);
-- 锁定期间在算术【之前】点名拒绝(PERIOD_LOCKED,与 post_journal_entry 同口径)——
-- 差额为 0 的跑法也不许落在锁里。分录:逐折旧科目借方归组,贷 1510 一条;
-- 计提行进 fixed_asset_depreciation(recorded,累计折旧从此可加出来)。

CREATE OR REPLACE FUNCTION public.depreciate_fixed_assets(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_locked  date;
    v_preview jsonb;
    v_r       jsonb;
    v_lines   jsonb := '[]'::jsonb;
    v_grp     record;
    v_total   numeric;
    v_je      jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;
    -- 【先查锁,再算术】差额为 0 的跑法也不许落在锁定期间里 —— 拒绝要点名,
    -- 与 post_journal_entry 同一口径(它兜底,这里提前)。
    SELECT locked_before INTO v_locked FROM finance_settings WHERE id;
    IF v_locked IS NOT NULL AND p_period_end < v_locked THEN
        RAISE EXCEPTION 'PERIOD_LOCKED|%|%', p_period_end, v_locked;
    END IF;

    v_preview := preview_depreciate_fixed_assets(p_period_end);
    v_total := (v_preview->>'total_delta')::numeric;

    -- 幂等出口:没有应提额 → 不过账、不留行,原样说明
    IF v_total = 0 THEN
        RETURN jsonb_build_object('period_end', p_period_end, 'total_posted', 0,
                                  'journal_code', NULL, 'detail', v_preview->'rows');
    END IF;

    -- 分录:逐【折旧科目】借方归组,贷 1510 一条
    FOR v_grp IN
        SELECT r->>'account' AS account, round(SUM((r->>'delta_base')::numeric), 2) AS amt
        FROM jsonb_array_elements(v_preview->'rows') r
        WHERE (r->>'delta_base')::numeric > 0
        GROUP BY r->>'account' ORDER BY r->>'account'
    LOOP
        v_lines := v_lines || jsonb_build_object('account_code', v_grp.account, 'side', 'debit',
            'currency', 'SGD', 'amount_ccy', v_grp.amt, 'fx_rate', 1,
            'line_memo', 'straight-line depreciation');
    END LOOP;
    v_lines := v_lines || jsonb_build_object('account_code', '1510', 'side', 'credit',
        'currency', 'SGD', 'amount_ccy', v_total, 'fx_rate', 1);

    v_je := post_journal_entry(p_period_end,
        'Depreciation for period ending ' || p_period_end,
        'depreciation', NULL, v_lines);

    -- 计提行落库(recorded —— 累计折旧从此可加出来)
    FOR v_r IN SELECT * FROM jsonb_array_elements(v_preview->'rows')
    LOOP
        IF (v_r->>'delta_base')::numeric > 0 THEN
            INSERT INTO fixed_asset_depreciation (asset_id, period_end, amount_base, journal_entry_id, created_by)
            VALUES ((v_r->>'asset_id')::uuid, p_period_end, (v_r->>'delta_base')::numeric,
                    (v_je->>'entry_id')::uuid, v_user);
        END IF;
    END LOOP;

    RETURN jsonb_build_object('period_end', p_period_end, 'total_posted', v_total,
                              'journal_code', v_je->>'code', 'detail', v_preview->'rows');
END;
$function$;
