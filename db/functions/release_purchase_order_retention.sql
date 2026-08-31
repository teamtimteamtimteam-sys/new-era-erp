CREATE OR REPLACE FUNCTION public.release_purchase_order_retention(p_retention_id uuid, p_released_amount_ccy numeric, p_withheld_amount_ccy numeric, p_withholding_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_state    text;
    v_total    numeric;
    v_code     text;
    v_maturity date;
    v_user     uuid := auth.uid();
BEGIN
    PERFORM require_permission('module.purchasing.edit');

    -- ★【为什么这里【不】读 purchase_order_retention_status】★ 那张视图体内带着
    -- has_permission('module.purchasing.view') 与按 data.view_prices 的金额遮蔽。
    -- 视图体里的谓词【不因为本函数是 DEFINER 而失效】—— 它是一个过滤条件,不是 RLS。
    -- 于是一个没有 data.view_prices 的调用者会拿到 retention_amount_ccy = NULL,
    -- 下面那条"放款+扣留必须等于总额"的校验会拿 NULL 去比,**结果是它不拦了**。
    -- 一道被遮蔽悄悄关掉的闸比没有闸更糟。所以判据一律从基表现算。
    SELECT po.code,
           CASE WHEN fa.acceptance_date IS NULL THEN NULL::date
                ELSE (fa.acceptance_date + (r.retention_months || ' months')::interval)::date END,
           CASE WHEN fa.acceptance_date IS NULL              THEN 'clock_not_started'
                WHEN r.released_at IS NOT NULL               THEN 'released'
                WHEN (fa.acceptance_date + (r.retention_months || ' months')::interval)::date
                     <= CURRENT_DATE                         THEN 'awaiting_confirmation'
                ELSE 'running' END,
           COALESCE(r.fixed_amount_ccy, round(pol.estimated_amount_ccy * r.percentage / 100.0, 2))
    INTO v_code, v_maturity, v_state, v_total
    FROM purchase_order_line_retentions r
    JOIN purchase_order_lines pol ON pol.id = r.purchase_order_line_id
    JOIN purchase_orders po ON po.id = pol.purchase_order_id
    JOIN fixed_assets fa ON fa.id = pol.asset_id
    WHERE r.id = p_retention_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'RETENTION_NOT_FOUND|%', COALESCE(p_retention_id::text, '?');
    END IF;

    IF v_state = 'released' THEN
        RAISE EXCEPTION 'RETENTION_ALREADY_RELEASED|%', v_code;
    END IF;
    -- 【没验收就没有起算点】—— 这不是"还没到期",是【时钟还没开始走】。
    IF v_state = 'clock_not_started' THEN
        RAISE EXCEPTION 'RETENTION_CLOCK_NOT_STARTED|%', v_code
          USING HINT = '这台机器还没有验收日期(fixed_assets.acceptance_date)—— 质保期无从起算,更谈不上到期。先记验收(set_asset_acceptance)';
    END IF;
    -- 【提前放款等于把质保金废掉】质保金的全部意义是它在质保期内扣得下来。
    IF v_state = 'running' THEN
        RAISE EXCEPTION 'RETENTION_NOT_MATURE|%|%', v_code, v_maturity
          USING HINT = '质保期未满 —— 提前放款等于把质保金废掉。到期日由验收日推导,不是一个可以绕过的字面量';
    END IF;

    IF p_released_amount_ccy IS NULL OR p_withheld_amount_ccy IS NULL THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_AMOUNTS_REQUIRED'
          USING HINT = '放多少、扣多少都要明说 —— 两个都不给默认值';
    END IF;
    IF p_released_amount_ccy < 0 OR p_withheld_amount_ccy < 0 THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_AMOUNT_NEGATIVE|%|%', p_released_amount_ccy, p_withheld_amount_ccy;
    END IF;
    IF round(p_released_amount_ccy + p_withheld_amount_ccy, 2) <> round(v_total, 2) THEN
        RAISE EXCEPTION 'RETENTION_RELEASE_DOES_NOT_BALANCE|%|%|%',
            v_code, round(p_released_amount_ccy + p_withheld_amount_ccy, 2), round(v_total, 2)
          USING HINT = '放款 + 扣留必须恰好等于质保金总额 —— 差额若允许存在,那笔钱就没有下落了';
    END IF;
    -- 扣了钱就要说为什么。表上那条 CHECK 也拦,这里【先】说一遍,好让走门的人
    -- 拿到一个具名拒绝,而不是一条约束原文。
    IF p_withheld_amount_ccy > 0 AND COALESCE(btrim(p_withholding_reason), '') = '' THEN
        RAISE EXCEPTION 'RETENTION_WITHHOLDING_NEEDS_REASON|%', v_code
          USING HINT = '扣留了质保金就要写明理由 —— 一笔没有理由的扣款,在供应商问起来的那天答不出来';
    END IF;

    UPDATE purchase_order_line_retentions
    SET released_at         = now(),
        released_by         = v_user,
        released_amount_ccy = p_released_amount_ccy,
        withheld_amount_ccy = p_withheld_amount_ccy,
        withholding_reason  = CASE WHEN p_withheld_amount_ccy > 0
                                   THEN btrim(p_withholding_reason) ELSE NULL END
    WHERE id = p_retention_id;

    RETURN jsonb_build_object(
        'retention_id', p_retention_id,
        'purchase_order_code', v_code,
        'retention_amount_ccy', round(v_total, 2),
        'released_amount_ccy', p_released_amount_ccy,
        'withheld_amount_ccy', p_withheld_amount_ccy,
        'withholding_reason', CASE WHEN p_withheld_amount_ccy > 0 THEN btrim(p_withholding_reason) END);
END;
$function$