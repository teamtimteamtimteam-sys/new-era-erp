CREATE OR REPLACE FUNCTION public.reverse_freight_document(p_freight_document_id uuid, p_reason text, p_reversal_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_orig freight_documents%ROWTYPE;
    v_settled numeric;
    v_je jsonb;
BEGIN
    PERFORM require_permission('module.finance.edit');

    -- ★ FIN-CHAIN-1(Tim 2026-10-20,Step 0 Q7 · APR4-FREIGHT-REVERSAL-DATED-TODAY):【冲销日由人选,必填,不默认】——
    --   与日记账冲销申请 · 发票作废 · 代扣税缴纳 · 银行划转那四个由人给日期的冲销同一条(FIN-10:决定期间的日期不许默认)。
    --   不许早于原分录(reverse_journal_entry_internal 按名拒 REVERSAL_BEFORE_ORIGINAL);落在已关账的期间按名拒
    --   PERIOD_LOCKED(post_journal_entry)—— 锁永远赢。
    IF p_reversal_date IS NULL THEN
        RAISE EXCEPTION 'REVERSAL_DATE_REQUIRED';
    END IF;

    -- 【理由必填,拒绝按名】—— AUDEL 家族那一条。
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'FREIGHT_REVERSAL_REASON_REQUIRED|%',
            COALESCE((SELECT code FROM freight_documents WHERE id = p_freight_document_id), '?')
          USING HINT = '没有理由的冲销,事后没人答得出为什么';
    END IF;

    SELECT * INTO v_orig FROM freight_documents
     WHERE id = p_freight_document_id AND deleted_at IS NULL FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'FREIGHT_NOT_FOUND|%', COALESCE(p_freight_document_id::text, '?');
    END IF;
    IF v_orig.status <> 'posted' THEN
        RAISE EXCEPTION 'FREIGHT_ALREADY_REVERSED|%', v_orig.code;
    END IF;

    -- 【已被结清的单据不许冲销】—— 冲掉它,账龄里那一行消失,而指向它的核销行
    -- 原样留着:一笔真的付过的钱,从此挂在一张"不欠任何人"的单据上。
    -- 与 FIN-22 的 EXPENSE_HAS_ASSET 同一条:先把下游拆掉,或走人工分录改正。
    SELECT COALESCE(SUM(pa.allocated_ccy), 0) INTO v_settled
      FROM payment_allocations pa
      JOIN payments p ON p.id = pa.payment_id AND p.status = 'posted'
     WHERE pa.freight_document_id = p_freight_document_id;
    IF v_settled > 0 THEN
        RAISE EXCEPTION 'FREIGHT_HAS_SETTLEMENT|%|%', v_orig.code, v_settled
          USING HINT = '这张运费单已经被付过款 —— 先冲掉那笔付款,再冲销单据';
    END IF;

    -- 冲其分录(冲销日 = 人选的那一天;期间锁在 post_journal_entry 内生效)。
    -- 【镜像的是原分录本身】,所以两个方向自动各自对称:进料侧冲掉 1200/5000,
    -- 出境侧冲掉 6300 —— 这个函数一个科目码都不需要知道。
    -- FIN-CHAIN-1:冲销日 = p_reversal_date(此前是 reversal_date_for —— 今天与原分录日里较晚的那个,没有人选得了)
    v_je := reverse_journal_entry_internal(v_orig.journal_entry_id, p_reversal_date,
        'Freight reversal ' || v_orig.code);

    -- 【状态只能从这里改】—— 守卫认这个标记,PostgREST 够不着它。
    PERFORM set_config('evoltrya.freight_reverse_ctx', '1', true);
    UPDATE freight_documents
       SET status = 'reversed', reversed_at = now(), reversed_by = v_user,
           reversal_reason = btrim(p_reason),
           reversal_entry_id = (v_je->>'reversal_id')::uuid,
           updated_by = v_user
     WHERE id = p_freight_document_id;
    PERFORM set_config('evoltrya.freight_reverse_ctx', '', true);   -- 用毕即清

    RETURN jsonb_build_object(
        'freight_document_id', p_freight_document_id, 'code', v_orig.code,
        'direction', v_orig.direction, 'status', 'reversed',
        'reversed_by', v_user, 'reason', btrim(p_reason),
        'reversal_entry_id', v_je->>'reversal_id', 'journal_code', v_je->>'code');
END;
$function$

