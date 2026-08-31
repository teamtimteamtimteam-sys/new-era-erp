CREATE OR REPLACE FUNCTION public.post_stocktake(p_stocktake_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user           uuid := auth.uid();
    v_st             record;
    v_line           record;
    v_code           text;
    v_current        numeric;
    v_deleted        timestamptz;
    v_delta          numeric;
    v_lines_total    integer := 0;
    v_lines_adjusted integer := 0;
    v_total_delta    numeric := 0;
    v_value          numeric;
    v_inv_acct       text;
    v_amt            numeric;
    v_je_lines       jsonb := '[]'::jsonb;
BEGIN
    PERFORM require_permission('module.stocktakes.edit');
    SELECT id, code, status, deleted_at INTO v_st
    FROM stocktakes WHERE id = p_stocktake_id FOR UPDATE;
    IF NOT FOUND OR v_st.deleted_at IS NOT NULL THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_FOUND|%', p_stocktake_id;
    END IF;
    IF v_st.status <> 'open' THEN
        RAISE EXCEPTION 'STOCKTAKE_NOT_OPEN|%', v_st.status;
    END IF;

    FOR v_line IN SELECT * FROM stocktake_lines WHERE stocktake_id = p_stocktake_id
    LOOP
        v_lines_total := v_lines_total + 1;

        IF v_line.inbound_batch_id IS NOT NULL THEN
            SELECT code, remaining_qty, deleted_at INTO v_code, v_current, v_deleted
            FROM inbound_batches WHERE id = v_line.inbound_batch_id FOR UPDATE;
            -- ════════════════════════════════════════════════════════════════
            -- PROC-COST-2 · R1:【盘点计值 = 落地成本,与注销同一支函数】
            -- 改之前这里取的是 unit_price(上一行的 SELECT 列表里),于是一批
            -- 落地 900 的货盘成 0 只解除 500,**400 留在 1200 上**(线上实测)。
            --
            -- ★【两个方向都改,而这是让修复安全的那一半】★
            -- 下面 v_value 同时喂给盘盈(借库存)与盘亏(贷库存)两支。只改盘亏
            -- 的实现会让一次"点少了、再点回来"**永久销毁**运费与加工成本 ——
            -- 那批料一克都没离开过厂房。**一次修复造出来的新缺陷,比被修的更坏。**
            -- fixture 的 D 臂钉的就是这一条:100 → 50 → 100,1200 必须回到起点。
            --
            -- 【读的是 landed_unit_cost,不是带判据的读取器】计值不许取决于
            -- 谁按的按钮 —— 见本刀迁移抬头第四节。
            -- 【FOR UPDATE 之后单独取】把函数调用留在 FOR UPDATE 的目标列表里
            -- 会让人以为它也被锁保护;它不是,它是一次独立的读。分两行写。
            -- ════════════════════════════════════════════════════════════════
            v_value := inbound_batch_landed_unit_cost(v_line.inbound_batch_id);
            v_inv_acct := '1200';
        ELSE
            SELECT ob.code, ob.remaining_qty, ob.deleted_at, po.unit_cost_base
            INTO v_code, v_current, v_deleted, v_value
            FROM output_batches ob
            LEFT JOIN processing_outputs po ON po.output_batch_id = ob.id
            WHERE ob.id = v_line.output_batch_id
            FOR UPDATE OF ob;
            v_inv_acct := '1220';
        END IF;

        IF v_deleted IS NOT NULL THEN
            RAISE EXCEPTION 'BATCH_DELETED|%', v_code;
        END IF;

        v_delta := v_line.counted_qty - v_current;
        IF v_delta <> 0 THEN
            IF v_line.inbound_batch_id IS NOT NULL THEN
                -- ════════════════════════════════════════════════════════════
                -- FIN-32-fu1:业务日 = 过账日(CURRENT_DATE),而这是【查过之后】
                -- 的结论,不是"没有更好的来源"那种含糊话。
                -- stocktakes 上确实有个 started_at,名字听起来像盘点日 —— 它不是:
                -- 它是 timestamptz NOT NULL DEFAULT now(),【全代码库没有任何一处
                -- 写过它】,而线上每一行的 started_at 与 created_at 【逐微秒相等】
                -- (实测 3/3,最大差 0.000000 秒)。它是建单时间戳,不是盘点日期。
                -- 所以周一盘、周二过账,这里记的仍是周二 —— 而这是【诚实的】:
                -- 系统里根本没有人告诉过它周一。
                -- 真要记录盘点当天,得先有一个【盘点日字段让人填】(Phase 2 的
                -- 盘点单),那时这里改成读它 —— 与注销读 deleted_at 同一条规矩:
                -- 日期要来自记录,而记录得先存在。
                -- ════════════════════════════════════════════════════════════
                INSERT INTO inventory_movements (inbound_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.inbound_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE inbound_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.inbound_batch_id;
            ELSE
                INSERT INTO inventory_movements (output_batch_id, movement_type, qty_delta, business_date, notes, created_by)
                VALUES (v_line.output_batch_id, 'adjustment', v_delta, CURRENT_DATE,
                        'stocktake ' || v_st.code || COALESCE(': ' || v_line.notes, ''), v_user);
                UPDATE output_batches
                SET remaining_qty = v_line.counted_qty, updated_by = v_user, updated_at = now()
                WHERE id = v_line.output_batch_id;
            END IF;
            v_lines_adjusted := v_lines_adjusted + 1;
            v_total_delta := v_total_delta + v_delta;

            -- cut 2a:有单值的差异行,成对累积分录行(盘盈:借库存 贷 5200;盘亏反向)。
            -- 无值(未计价进料 / 无成本产出)只调量不入账。
            -- PROC-COST-2:v_value 现在是【单位落地成本】,两支共用它 —— 见上。
            IF v_value IS NOT NULL THEN
                v_amt := round(abs(v_delta) * v_value, 2);
                IF v_amt <> 0 THEN
                    IF v_delta > 0 THEN
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', '5200',     'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt);
                    ELSE
                        v_je_lines := v_je_lines
                            || jsonb_build_object('account_code', '5200',     'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_amt)
                            || jsonb_build_object('account_code', v_inv_acct, 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_amt);
                    END IF;
                END IF;
            END IF;
        END IF;
    END LOOP;

    UPDATE stocktakes
    SET status = 'posted', posted_at = now(), updated_by = v_user, updated_at = now()
    WHERE id = p_stocktake_id;

    -- cut 2a:一张分录覆盖全部有值差异行(每行自成一对,天然自平)
    IF jsonb_array_length(v_je_lines) >= 2 THEN
        PERFORM post_journal_entry(
            CURRENT_DATE,
            'Stocktake ' || v_st.code,
            'stocktake', p_stocktake_id,
            v_je_lines);
    END IF;

    RETURN jsonb_build_object(
        'stocktake_id', p_stocktake_id,
        'code', v_st.code,
        'lines_total', v_lines_total,
        'lines_adjusted', v_lines_adjusted,
        'total_delta', v_total_delta
    );
END;
$function$;