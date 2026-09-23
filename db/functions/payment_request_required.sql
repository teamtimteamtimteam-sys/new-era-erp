-- db/functions/payment_request_required.sql
-- PAY-REQ-1(2026-09-23):【这一笔出款要不要先提付款申请】—— 一份判据,两个读它的人:
--   · record_payment(拦):true 就按名拒 PAYMENT_REQUEST_REQUIRED;
--   · /finance/payments/new 的 server action(问):true 就改提一张申请。
-- 屏幕问的与库里拦的是同一句话,所以它们不可能各说各的(预览规则)。
--
-- ★ 答 false 的只有两种(Tim 的裁定):
--   ① 收款('in')—— 钱进来,不批;
--   ② Q1 的豁免:付给【员工】,并且【整笔】都核销到【已被一个人批过】的费用上 ——
--      也就是 decide_expense_claim(报销单批准时生成)或 pay_medical_claim
--      (医疗申报付款时生成)造出来的那张费用单。那个数已经被批过一次,再批一次
--      只是让 CFO 重复签一个他没有理由改的数(医疗付款 Tim 明说不批)。
--
-- 【"整笔"是怎么判的 —— 刻意写窄】
--   每一条核销都只能是 expense_id,且那张费用单的币种 = 付款币种,
--   Σ amount_doc = p_amount。★ 跨币种付报销 / 带挂账余额 → 不豁免,要申请。
--   写窄的理由:跨币种要牌价才算得出"整笔",而一个要查牌价才答得出的豁免,
--   在查不到牌价那天会答错方向。窄的那一边错了,代价是多提一张申请;
--   宽的那一边错了,代价是一笔没批过的钱走了。
--
-- 【为什么是 SECURITY DEFINER】它要读 medical_claims(RLS 要 module.hr.view)与
--   expense_claims;财务付一笔医疗报销时不一定持 hr.view,读不到就会把豁免
--   答成"要申请"—— 安全方向,但会拦下一件 Tim 明说不批的事。
--   调用者检查:module.finance.view(读它的人本来就是财务)。
--
-- NOTE: introduced by db/migrations/2026-09-23-payreq1a-money-leaves-only-after-approval.sql.

CREATE OR REPLACE FUNCTION public.payment_request_required(p_direction text, p_counterparty_kind text, p_counterparty_id uuid, p_amount numeric, p_currency text, p_allocations jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_kind  text;
    v_alloc jsonb;
    v_exp   uuid;
    v_sum   numeric := 0;
    v_n     integer := 0;
BEGIN
    PERFORM require_permission('module.finance.view');

    IF p_direction IS DISTINCT FROM 'out' THEN
        RETURN false;
    END IF;
    v_kind := COALESCE(NULLIF(btrim(p_counterparty_kind), ''), 'supplier');
    IF v_kind <> 'employee' THEN
        RETURN true;
    END IF;
    IF p_allocations IS NULL OR jsonb_typeof(p_allocations) <> 'array'
       OR jsonb_array_length(p_allocations) = 0 THEN
        RETURN true;
    END IF;

    FOR v_alloc IN SELECT * FROM jsonb_array_elements(p_allocations) LOOP
        -- 只许 expense_id 一种去处:任何别的键出现(哪怕为空)都不算"整笔付报销"
        IF jsonb_typeof(v_alloc) <> 'object'
           OR EXISTS (SELECT 1 FROM jsonb_object_keys(v_alloc) k
                       WHERE k NOT IN ('expense_id', 'amount_doc')) THEN
            RETURN true;
        END IF;
        BEGIN
            v_exp := (v_alloc->>'expense_id')::uuid;
        EXCEPTION WHEN invalid_text_representation THEN
            RETURN true;
        END;
        IF v_exp IS NULL OR (v_alloc->>'amount_doc') IS NULL THEN
            RETURN true;
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM expenses e
             WHERE e.id = v_exp
               AND e.employee_id = p_counterparty_id
               AND e.currency = p_currency
               AND (EXISTS (SELECT 1 FROM expense_claims c
                             WHERE c.expense_id = e.id AND c.status = 'approved')
                 OR EXISTS (SELECT 1 FROM medical_claims m
                             WHERE m.expense_id = e.id))
        ) THEN
            RETURN true;
        END IF;
        v_sum := v_sum + (v_alloc->>'amount_doc')::numeric;
        v_n := v_n + 1;
    END LOOP;

    RETURN NOT (v_n > 0 AND round(v_sum, 2) = round(p_amount, 2));
END;
$function$
;
