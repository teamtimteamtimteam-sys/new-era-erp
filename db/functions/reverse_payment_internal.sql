-- db/functions/reverse_payment_internal.sql
-- PAY-REQ-1(2026-09-23):reverse_payment 的函数体搬到这里,拿掉了权限检查,
-- 并补上镜像行漏抄的 employee_id。下面是它原来的抬头,照录:
--
-- SOD-1(2026-08-24):这支函数现在【声明】自己在冲销。
-- guard_payment_sod 会拦住"建收款人的人付款给该收款人",而冲销的镜像行
-- direction/counterparty 与原单相同,会走到那道闸上。冲销是把钱【收回来】的
-- 更正动作 —— 拦住它只会把一笔记错的付款锁死在账上,而且拦不住任何舞弊。
-- 所以由调用方显式声明,不由守卫去猜(po_status_ctx / close_ctx / alloc_ctx 同一惯用法)。
-- 【用完立刻清掉】set_config(..., true) 是【事务】局部,不是语句局部 ——
-- 只设不清,同一事务里后面任何一笔直连 INSERT 都会畅通无阻(APR-2c fu2 实测过)。
-- fixture 127 的 B5 臂把"立起来"与"落下去"一起断言。

CREATE OR REPLACE FUNCTION public.reverse_payment_internal(p_payment_id uuid, p_memo text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_orig        payments%ROWTYPE;
    v_mirror_id   uuid := gen_random_uuid();
    v_mirror_code text;
    v_je          jsonb;
BEGIN
    -- ★ PAY-REQ-1:这里【没有】权限检查 —— 内层引擎,EXECUTE 已从 authenticated 收回。
    --   唯一的外门是 pay_payment_request(finance.edit,且只执行一张已批准的冲销申请);
    --   payment_request_dry_run 在提交与批准时照同一套规矩核一遍再回滚。
    SELECT * INTO v_orig FROM payments WHERE id = p_payment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'PAYMENT_NOT_FOUND|%', p_payment_id;
    END IF;
    IF v_orig.status <> 'posted' OR v_orig.reversed_by_payment IS NOT NULL THEN
        RAISE EXCEPTION 'PAYMENT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 冲其分录(冲销日 = 今天;期间锁在 post_journal_entry 内生效)
    -- AP-RECON-1 Batch B:冲销日 = 今天与原分录日里较晚的那个(reversal_date_for;冲销不许早于原分录)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, reversal_date_for(v_orig.journal_entry_id), 'Payment reversal ' || v_orig.code);

    -- 镜像收付款单(现金退回),挂冲销分录,不带核销行
    v_mirror_code := fin_next_payment_code(CASE WHEN v_orig.direction = 'in' THEN document_type_prefix('payment_receipt') ELSE document_type_prefix('payment_out') END, CURRENT_DATE);

    -- SOD-1:告诉 guard_payment_sod 这是一次【冲销】,不是一次付款。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '1', true);
    -- ★ PAY-REQ-1:镜像行此前【漏抄 employee_id】—— payments 的形状 CHECK 要求
    --   付给员工的那一行恰好带着它,于是冲销一笔员工付款会撞 CHECK 失败
    --   (PAY-REQ-1 grilling 读代码发现;从此每一次冲销都走申请,这条路第一次真的会被走到)。
    INSERT INTO payments (id, code, direction, counterparty_type, customer_id, supplier_id,
                          employee_id,
                          amount_ccy, currency, fx_rate, amount_base, bank_account_code,
                          payment_date, notes, journal_entry_id, created_by)
    VALUES (v_mirror_id, v_mirror_code, v_orig.direction, v_orig.counterparty_type,
            v_orig.customer_id, v_orig.supplier_id, v_orig.employee_id,
            v_orig.amount_ccy, v_orig.currency, v_orig.fx_rate, v_orig.amount_base,
            v_orig.bank_account_code, CURRENT_DATE,
            'REVERSAL: ' || v_orig.code || COALESCE(' — ' || p_memo, ''),
            (v_je->>'reversal_id')::uuid, auth.uid());
    -- 【立刻清掉】—— 事务局部,不清就一直开着。
    PERFORM set_config('evoltrya.payment_reversal_ctx', '', true);

    UPDATE payments
    SET status = 'reversed', reversed_by_payment = v_mirror_id
    WHERE id = p_payment_id;

    RETURN jsonb_build_object(
        'reversal_payment_id', v_mirror_id,
        'code', v_mirror_code,
        'journal_code', v_je->>'code'
    );
END;
$function$;