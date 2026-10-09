-- db/functions/reverse_electricity_allocation.sql
-- MES-5b-2(2026-10-09,MES-5b Step 0 Q22 · Q23 · Q24 · Q25,Tim):【撤回一张电费单 —— 一笔事务、一个冲销日,带理由】(F1)。
--   门:module.finance.edit(过账、冲抵、冲销费用单用的同一个码;线上 admin · finance)。没有审批(Q25)。理由必填(reverse_freight_document 的先例)。
--   一笔事务里(Q22):
--     ① 冲掉费用单与分摊那张分录:reverse_expense_internal —— reverse_expense 用的同一段(未付的借回 2000,已付的借回银行;
--        冲销日 = reversal_date_for(分摊那张分录),期间锁在 post_journal_entry 里照判)。经付款结过的费用单在那里按名拒
--        EXPENSE_HAS_SETTLEMENT —— 先经付款冲销申请冲掉那笔付款(Q24)。
--     ② 每一炉那条已结的实际电费行:先清掉结算戳(remitted_*),再软删 —— 软删由 fin_journal_cost_entry 过 借 2200 / 贷 5110。
--        (守卫拒"一条结过的行被软删",所以两句分开;Step 0 §7。)
--     ③ 被它冲掉的每一条手敲估计:先清冲抵戳,再取消软删,再【明写】一张 借 5110 / 贷 2200 的重新计提(取消软删不过账 ——
--        fin_journal_cost_entry 只认软删与改额)。每一条一张,source_type = processing_cost,source_id = 那一条,与它自己的录入分录同形。
--     ④ 一行 electricity_allocation_reversals(金额遮蔽,同分摊)。
--   于是 2200 · 5110 · 6200 · 2000(或银行)回到过账之前的余额,那几炉回到过账之前的样子 —— 同一段时间可以再过一张改正过的账单(Q23:
--   compute 的"已分过""时间段重叠"与 guard_electricity_line_one_live_allocation 都不再认一张撤回过的分摊)。
--   【一个冲销日】分录冲销件落在 reversal_date_for(…),而 ② 的软删分录与 ③ 的重新计提由触发器 / 本函数落在 CURRENT_DATE ——
--     分摊那张分录的日期是账单日、账单日不许晚于今天,所以 reversal_date_for(…) = CURRENT_DATE;这里断言两者相等,不相等就拒(不会静悄悄地分在两天)。
--   结算戳只许经财务函数改(guard_cost_entry_settled 认事务级标记 evoltrya.cost_settlement_ctx,用毕即清)。
--   与 post 拿同一把咨询锁,所以"撤回"与"再过一张"不会交错。
--   拒:理由没给 ELECTRICITY_REVERSAL_REASON_REQUIRED;找不到 ELECTRICITY_ALLOCATION_NOT_FOUND;撤回过 ELECTRICITY_ALLOCATION_ALREADY_REVERSED;
--     那几条行或估计自过账以来被动过(本不可能 —— 戳只许经这几支函数改)ELECTRICITY_ALLOCATION_STATE_CHANGED。
--   返回 {reversal_id, allocation_id, reversal_expense_code, journal_code, actual_lines, restored_estimates, reversal_date}。
--   ★ MES-6a-1(2026-10-09,F3 · Q33 · Q34):理由照旧在码之后第一件事查;它从此【原样】传给 reverse_expense_internal(不再加
--     "Electricity bill reversed: " 前缀),写在被冲掉的那张费用单的 reversal_reason 上 —— 分摊这一侧在 electricity_allocation_reversals.reason 另留一份。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b2-reversals.sql.

CREATE OR REPLACE FUNCTION public.reverse_electricity_allocation(p_allocation_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user      uuid := auth.uid();
    v_reason    text := NULLIF(btrim(COALESCE(p_reason, '')), '');
    v_a         electricity_allocations%ROWTYPE;
    v_code      text;
    v_date      date;
    v_x         jsonb;
    v_line_ids  uuid[];
    v_line_n    integer;
    v_line_amt  numeric;
    v_est_ids   uuid[];
    v_est_n     integer;
    v_est_amt   numeric;
    v_e         record;
    v_rev_id    uuid := gen_random_uuid();
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT code INTO v_code FROM expenses
     WHERE id = (SELECT expense_id FROM electricity_allocations WHERE id = p_allocation_id);
    IF v_reason IS NULL THEN
        RAISE EXCEPTION 'ELECTRICITY_REVERSAL_REASON_REQUIRED|%', COALESCE(v_code, '?')
          USING HINT = '没有理由的撤回,事后没人答得出为什么';
    END IF;

    PERFORM pg_advisory_xact_lock(hashtext('electricity_allocation')::bigint);
    SELECT * INTO v_a FROM electricity_allocations WHERE id = p_allocation_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'ELECTRICITY_ALLOCATION_NOT_FOUND|%', COALESCE(p_allocation_id::text, '?');
    END IF;
    IF EXISTS (SELECT 1 FROM electricity_allocation_reversals v WHERE v.allocation_id = p_allocation_id) THEN
        RAISE EXCEPTION 'ELECTRICITY_ALLOCATION_ALREADY_REVERSED|%', v_code;
    END IF;

    v_date := reversal_date_for(v_a.journal_entry_id);
    IF v_date <> CURRENT_DATE THEN
        RAISE EXCEPTION 'ELECTRICITY_REVERSAL_DATE_SPLIT|%|%', v_date, CURRENT_DATE;
    END IF;

    -- 先锁住、再核对:各炉那条实际电费行仍是这张分摊结掉的样子;被它冲掉的估计仍是它冲掉的样子
    SELECT array_agg(c.id ORDER BY c.id), count(*), COALESCE(sum(c.amount_base), 0) INTO v_line_ids, v_line_n, v_line_amt
      FROM electricity_allocation_lines l JOIN processing_cost_entries c ON c.id = l.cost_entry_id
     WHERE l.allocation_id = p_allocation_id;
    PERFORM 1 FROM processing_cost_entries c WHERE c.id = ANY (v_line_ids) FOR UPDATE;
    IF EXISTS (SELECT 1 FROM processing_cost_entries c WHERE c.id = ANY (v_line_ids)
                 AND (c.deleted_at IS NOT NULL OR c.remitted_journal_entry_id IS DISTINCT FROM v_a.journal_entry_id)) THEN
        RAISE EXCEPTION 'ELECTRICITY_ALLOCATION_STATE_CHANGED|%|lines', v_code;
    END IF;
    SELECT array_agg(c.id ORDER BY c.id), count(*), COALESCE(sum(c.amount_base), 0) INTO v_est_ids, v_est_n, v_est_amt
      FROM processing_cost_entries c
     WHERE c.relief_expense_id = v_a.expense_id AND c.is_estimate AND c.deleted_at IS NOT NULL;
    PERFORM 1 FROM processing_cost_entries c WHERE c.id = ANY (v_est_ids) FOR UPDATE;
    IF v_est_n <> v_a.relieved_estimate_count OR v_est_amt <> v_a.relieved_estimate_amount THEN
        RAISE EXCEPTION 'ELECTRICITY_ALLOCATION_STATE_CHANGED|%|estimates', v_code;
    END IF;

    -- ① 费用单与分录(经付款结过的在里面按名拒)
    -- ★ MES-6a-1(F3,Q34):理由原样传过去(不加前缀)—— 它写在被冲掉的那张费用单的 reversal_reason 上;分摊这一侧另留一份。
    v_x := reverse_expense_internal(v_a.expense_id, v_reason);

    PERFORM set_config('evoltrya.cost_settlement_ctx', '1', true);
    -- ② 实际电费行:清戳,再软删(触发器过 借 2200 / 贷 5110)
    IF v_line_n > 0 THEN
        UPDATE processing_cost_entries SET remitted_at = NULL, remitted_journal_entry_id = NULL, updated_by = v_user
         WHERE id = ANY (v_line_ids);
        UPDATE processing_cost_entries SET deleted_at = now(), updated_by = v_user
         WHERE id = ANY (v_line_ids);
    END IF;
    -- ③ 估计:清戳,取消软删,明写重新计提(借 5110 / 贷 2200)
    IF v_est_n > 0 THEN
        UPDATE processing_cost_entries SET relieved_at = NULL, relief_expense_id = NULL, updated_by = v_user
         WHERE id = ANY (v_est_ids);
        UPDATE processing_cost_entries SET deleted_at = NULL, updated_by = v_user
         WHERE id = ANY (v_est_ids);
        FOR v_e IN SELECT c.id, c.cost_type, c.amount_base, r.code AS run_code
                     FROM processing_cost_entries c JOIN processing_runs r ON r.id = c.run_id
                    WHERE c.id = ANY (v_est_ids) ORDER BY r.code, c.id LOOP
            IF v_e.amount_base <> 0 THEN
                PERFORM post_journal_entry(v_date, 'Cost restored ' || v_e.run_code || ' (bill ' || v_code || ' reversed)',
                                           'processing_cost', v_e.id, fin_cost_lines(v_e.cost_type, v_e.amount_base, false));
            END IF;
        END LOOP;
    END IF;
    PERFORM set_config('evoltrya.cost_settlement_ctx', '', true);

    -- ④ 撤回的记录
    INSERT INTO electricity_allocation_reversals (id, allocation_id, reversal_date, reason, reversal_expense_id, reversal_journal_entry_id,
        payment_status, bank_account_code, bill_amount, actual_line_count, actual_line_amount, restored_estimate_count,
        restored_estimate_amount, created_by)
    VALUES (v_rev_id, p_allocation_id, v_date, v_reason, (v_x ->> 'reversal_expense_id')::uuid, (v_x ->> 'reversal_journal_id')::uuid,
        v_a.payment_status, v_a.bank_account_code, v_a.bill_amount, v_line_n, v_line_amt, v_est_n, v_est_amt, v_user);

    RETURN jsonb_build_object('reversal_id', v_rev_id, 'allocation_id', p_allocation_id, 'expense_code', v_code,
                              'reversal_expense_code', v_x ->> 'code', 'journal_code', v_x ->> 'journal_code',
                              'actual_lines', v_line_n, 'restored_estimates', v_est_n, 'reversal_date', v_date);
END;
$function$
