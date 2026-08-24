CREATE OR REPLACE FUNCTION public.void_invoice(p_invoice_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_inv invoices%ROWTYPE;
    v_n   int;
    v_rev jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');
    SELECT * INTO v_inv FROM invoices WHERE id = p_invoice_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INVOICE_NOT_FOUND|%', COALESCE(p_invoice_id::text, '?');
    END IF;
    IF v_inv.status <> 'issued' THEN
        RAISE EXCEPTION 'INVOICE_ALREADY_VOID|%', v_inv.code;
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'REASON_REQUIRED';
    END IF;

    IF v_inv.kind = 'order' THEN
        -- 【冲销日必填,永不默认】它决定冲销分录的期间;期间锁/年结闸由
        -- post_journal_entry 对它统一执行(锁住的月份按名拒,不是悄悄挪到今天)。
        IF p_reversal_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        -- 【有活核销就不作废】核销行不可变、只随收款的冲销失效 —— 先冲收款
        -- (reverse_payment,先例),再作废发票。顺序反过来会留下一堆指着
        -- 已作废单据的活核销。
        SELECT count(*) INTO v_n
        FROM payment_allocations pa
        JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
        WHERE pa.invoice_id = p_invoice_id;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_HAS_SETTLEMENTS|%|%', v_inv.code, v_n;
        END IF;
        -- 【SO-3b:停放的那条检查在这里落地】发货一旦释放过这张票的负债
        -- (部分或全部),冲销就没有足额的 2500 可借 —— 按名拒,更正走
        -- 【贷项凭证】(credit note,sales_records 表头停放的未来概念)。
        -- 判据是【派生】的:这张发票的行上,有没有发出去过的货。不设状态位 ——
        -- 状态位会与真相漂开,而这个问题每次都问得起(与 ship_order 的
        -- SO_SHIP_NOT_INVOICED 同一条)。
        SELECT count(*) INTO v_n
        FROM shipment_lines sl
        JOIN invoice_lines il ON il.sales_order_line_id = sl.sales_order_line_id
        WHERE il.invoice_id = p_invoice_id AND NOT il.invoice_voided;
        IF v_n > 0 THEN
            RAISE EXCEPTION 'INVOICE_SHIPPED_NOT_VOIDABLE|%', v_inv.code;
        END IF;
        v_rev := reverse_journal_entry_internal(v_inv.entry_id, p_reversal_date, 'Void ' || v_inv.code);
    ELSIF v_inv.entry_id IS NOT NULL THEN
        -- ════════════════════════════════════════════════════════════════════
        -- 【GST-2:带税的 sale 型发票【有一张分录】—— 那张只过税的分录】
        -- GST-2 之前 sale 型什么都不过账,所以这一支从来不需要冲销。现在它需要:
        -- 不冲掉那张 借 1100 / 贷 2100,一张作废的发票会把销项税永远留在
        -- 2100 里,而 F5 的文档侧已经把这张票排除掉了 —— 于是勾稽的两边
        -- 会分开,而分开的原因是【作废没做完】,不是过账算错了税。
        -- 【日期必填,与 order 支逐字同一条理由】它决定冲销落进哪个期间。
        -- ════════════════════════════════════════════════════════════════════
        IF p_reversal_date IS NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
        END IF;
        v_rev := reverse_journal_entry_internal(v_inv.entry_id, p_reversal_date, 'Void ' || v_inv.code);
    ELSE
        -- 不带税的 sale 头没有分录可冲 —— 收下一个日期再忽略它,是在骗调用方
        -- (record_output_sale 拒 p_fx_rate 的同一条)。
        IF p_reversal_date IS NOT NULL THEN
            RAISE EXCEPTION 'REVERSAL_DATE_NOT_ACCEPTED|%', v_inv.code;
        END IF;
    END IF;

    -- 明细行保留供审计;作废标记由 trg_invoices_propagate_void 同步到明细行,
    -- 行(销售或订单行)随之重新可开票。
    UPDATE invoices
    SET status = 'void',
        void_reason = btrim(p_reason),
        voided_at = now(),
        voided_by = auth.uid()
    WHERE id = p_invoice_id;

    IF v_inv.kind = 'order' THEN
        INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
        VALUES (v_inv.sales_order_id, 'invoice_voided',
                v_inv.code || ' · ' || btrim(p_reason), auth.uid());
    END IF;

    RETURN jsonb_build_object(
        'invoice_id', p_invoice_id,
        'code', v_inv.code,
        'status', 'void',
        'reversal_code', v_rev->>'code');
END;
$function$
;