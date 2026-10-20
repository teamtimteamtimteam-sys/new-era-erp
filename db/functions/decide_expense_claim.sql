-- db/functions/decide_expense_claim.sql
-- 报销单的决定路径(旧签名)。CLAIM-1 建的;APR-3 接上审批引擎;CLAIM-GST-1 拆税。
-- ★ EXPENSE-MULTILINE-1(Tim 2026-10-20,Step 0b Q8):这一支现在是 decide_expense_claim_items 的【单笔包装】 ——
--   签名一个字不变(12 份 fixture 里 32 处调用、7 支证明脚本照旧);一张单只有一笔明细时,把 (科目, 税码) 包成那一笔的选择,
--   交给按明细的那一支。门、四眼、分档、驳回、凭据、入账日与过账的全部说明都在 decide_expense_claim_items.sql —— 读那一份。
--   【多笔的单走这里按名拒】EXPENSE_CLAIM_HAS_ITEMS|单号|笔数 —— 一个科目套在几笔上,就是替财务把逐笔的判断做掉了(Step 0b Q1);
--   驳回也一样拒:走旧调用的那个人手里没有逐笔的界面,让他一律去新的那一支,比一半走得通一半走不通好读。
CREATE OR REPLACE FUNCTION public.decide_expense_claim(p_claim_id uuid, p_approve boolean, p_account_code text DEFAULT NULL::text, p_tax_code text DEFAULT NULL::text, p_posting_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code text;
    v_n    integer;
BEGIN
    PERFORM require_permission('module.finance.view');
    PERFORM require_permission('data.view_prices');
    SELECT c.code, (SELECT count(*) FROM expense_claim_items i WHERE i.claim_id = c.id)
      INTO v_code, v_n FROM expense_claims c WHERE c.id = p_claim_id;
    IF v_n > 1 THEN
        RAISE EXCEPTION 'EXPENSE_CLAIM_HAS_ITEMS|%|%', v_code, v_n
          USING HINT = '这张报销单有多笔明细 —— 用 decide_expense_claim_items 逐笔给科目与税码';
    END IF;
    RETURN decide_expense_claim_items(
        p_claim_id     := p_claim_id,
        p_approve      := p_approve,
        p_items        := CASE WHEN p_approve THEN jsonb_build_array(jsonb_build_object(
                              'line_no', 1, 'account_code', p_account_code, 'tax_code', p_tax_code)) END,
        p_posting_date := p_posting_date,
        p_notes        := p_notes);
END;
$function$;
