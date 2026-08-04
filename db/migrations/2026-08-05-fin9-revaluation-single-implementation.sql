-- FIN-9:重估的算术只留一份 —— 预览与过账共用同一个函数。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【问题不是"查询没检查错误",是同一条规则被实现了两遍】
-- ════════════════════════════════════════════════════════════════════════════
-- /finance/revaluation 的预览表【自己用 TypeScript 又算了一遍调整额】,而没有问
-- revalue_foreign_balances。两份实现已经漂开了,与查询失不失败无关:
--
--   1. 既往重估行并入承载额的口径不同。SQL 按【科目】把该科目的既往重估净额加进
--      该科目【每一个币种】分组;TS 那段 `for (const [k,a] of agg) { … break }`
--      把每一行只加进【第一个】匹配分组。一个科目挂两种外币时,两者必然不同。
--   2. TS 把 adj = 0 的行也列出来(SQL 只在 adj <> 0 时发行),显示口径不同。
--   3. 最要紧的一条:预览【根本没有 7110 那一行】。净额未实现汇兑损益 —— 也就是
--      这次重估对损益表的全部影响 —— 操作员在过账前一眼都看不到。
--   4. 承载额那条查询的 error 被吞掉,读成空集就少算既往重估,调整额被放大;
--      而这个数字会被过账进总账,不是只错在屏幕上。
--
-- 这与"验配影响预览"(Phase 4 cut 5b)、"HR-2c 删掉的 GrantRunner 公式"是同一个
-- 病:界面重算了一遍数据库已经会算的东西。修法也一样 —— 【删掉重复实现】,
-- 不是去修那条查询。仓库里已有先例:preview_reprice_inbound_batch 与
-- reprice_inbound_batch 共用 reprice_split 的算术。
--
-- 本迁移:
--   * 新增 preview_revalue_foreign_balances(date) —— 只读,返回逐行明细 + 合计;
--   * revalue_foreign_balances 改为【调用它】再据其结果发行,于是算术只剩一份。
--     过账行为、幂等性、期间锁、FX_RATE_MISSING 的抛出口径全部不变
--     (缺牌价时仍由 fx_rate_for 抛出原样的 FX_RATE_MISSING|币种|日期|类型)。

BEGIN;

-- ── 预览:只读,不发任何分录 ────────────────────────────────────────────────
-- 缺当日中间价【不抛】,该行 rate/target_base/adjustment 返回 null 并记进
-- missing_rates —— 页面要能把"缺牌价"画出来,而不是整页报错。
-- 过账那一侧仍然拒绝(见下),D2 的语义不变。
CREATE OR REPLACE FUNCTION public.preview_revalue_foreign_balances(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_row     record;
    v_rate    numeric;
    v_target  numeric;
    v_adj     numeric;
    v_carry   numeric;
    v_rows    jsonb := '[]'::jsonb;
    v_missing jsonb := '[]'::jsonb;
    v_total   numeric := 0;
BEGIN
    PERFORM require_permission('module.finance.view');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    FOR v_row IN
        SELECT a.code, l.currency,
               round(sum(CASE WHEN l.debit > 0 THEN l.amount_ccy ELSE -l.amount_ccy END), 2) AS native,
               round(sum(l.debit - l.credit), 2) AS carry_fx
        FROM journal_lines l
        JOIN accounts a ON a.id = l.account_id
        JOIN journal_entries e ON e.id = l.entry_id
        WHERE e.status = 'posted' AND e.entry_date <= p_period_end
          AND a.is_monetary AND l.currency <> 'SGD'
        GROUP BY a.code, l.currency
        ORDER BY a.code, l.currency
    LOOP
        -- 既往重估调整行(本币行,挂在 revaluation 分录上)也算进承载额
        SELECT v_row.carry_fx + COALESCE(round(sum(l2.debit - l2.credit), 2), 0)
        INTO v_carry
        FROM journal_lines l2
        JOIN accounts a2 ON a2.id = l2.account_id
        JOIN journal_entries e2 ON e2.id = l2.entry_id
        WHERE a2.code = v_row.code AND l2.currency = 'SGD'
          AND e2.source_type = 'revaluation' AND e2.status = 'posted'
          AND e2.entry_date <= p_period_end;

        BEGIN
            v_rate := fx_rate_for(v_row.currency, p_period_end, 'mid');
        EXCEPTION WHEN OTHERS THEN
            v_rate := NULL;
            IF NOT (v_missing @> to_jsonb(v_row.currency)) THEN
                v_missing := v_missing || to_jsonb(v_row.currency);
            END IF;
        END;

        IF v_rate IS NULL THEN
            v_target := NULL; v_adj := NULL;
        ELSE
            v_target := round(v_row.native * v_rate, 2);
            v_adj    := round(v_target - v_carry, 2);
            v_total  := v_total + v_adj;
        END IF;

        v_rows := v_rows || jsonb_build_object(
            'account', v_row.code, 'currency', v_row.currency,
            'native', v_row.native, 'carry_base', v_carry,
            'rate', v_rate, 'target_base', v_target, 'adjustment', v_adj);
    END LOOP;

    RETURN jsonb_build_object(
        'period_end', p_period_end,
        'rows', v_rows,
        'total_adjustment', v_total,
        'missing_rates', v_missing);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.preview_revalue_foreign_balances(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.preview_revalue_foreign_balances(date) TO authenticated, service_role;

-- ── 过账:改为据预览结果发行,算术不再自带一份 ──────────────────────────────
CREATE OR REPLACE FUNCTION public.revalue_foreign_balances(p_period_end date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_preview jsonb;
    v_r       jsonb;
    v_adj     numeric;
    v_lines   jsonb := '[]'::jsonb;
    v_detail  jsonb := '[]'::jsonb;
    v_total   numeric := 0;
    v_je      jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'DATE_REQUIRED';
    END IF;

    v_preview := preview_revalue_foreign_balances(p_period_end);

    -- 缺当日中间价即拒(D2)。这里【故意再调一次 fx_rate_for】把它自己的异常抛出来,
    -- 免得错误文案在两处各写一遍又各自漂移 —— 与本次修的病同源。
    IF jsonb_array_length(v_preview->'missing_rates') > 0 THEN
        PERFORM fx_rate_for((v_preview->'missing_rates'->>0), p_period_end, 'mid');
    END IF;

    FOR v_r IN SELECT * FROM jsonb_array_elements(v_preview->'rows')
    LOOP
        v_adj := (v_r->>'adjustment')::numeric;
        IF v_adj IS NOT NULL AND v_adj <> 0 THEN
            v_lines := v_lines || jsonb_build_object(
                'account_code', v_r->>'account',
                'side', CASE WHEN v_adj > 0 THEN 'debit' ELSE 'credit' END,
                'currency', 'SGD', 'amount_ccy', abs(v_adj), 'fx_rate', 1,
                'line_memo', (v_r->>'currency') || ' @ ' || (v_r->>'rate'));
            v_total := v_total + v_adj;
            v_detail := v_detail || jsonb_build_object(
                'account', v_r->>'account', 'currency', v_r->>'currency',
                'native', (v_r->>'native')::numeric,
                'target_base', (v_r->>'target_base')::numeric,
                'adjustment', v_adj);
        END IF;
    END LOOP;

    IF v_total <> 0 THEN
        -- 净额对方科目:未实现汇兑损益(C5;已实现的走结算时点的 7100)
        v_lines := v_lines || jsonb_build_object(
            'account_code', '7110',
            'side', CASE WHEN v_total > 0 THEN 'credit' ELSE 'debit' END,
            'currency', 'SGD', 'amount_ccy', abs(v_total), 'fx_rate', 1);
    END IF;

    IF jsonb_array_length(v_lines) = 0 THEN
        RETURN jsonb_build_object('period_end', p_period_end, 'adjustments', 0,
                                  'detail', '[]'::jsonb, 'journal_code', NULL);
    END IF;

    v_je := post_journal_entry(p_period_end,
        format('FX revaluation as at %s', p_period_end), 'revaluation', NULL, v_lines);

    RETURN jsonb_build_object('period_end', p_period_end,
                              'adjustments', jsonb_array_length(v_detail),
                              'detail', v_detail, 'journal_code', v_je->>'code');
END;
$function$;

COMMIT;
