CREATE OR REPLACE FUNCTION public.record_sale_settlement(p_sales_order_id uuid, p_output_batch_id uuid, p_assay_result_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
-- SETTLE-1:把一次结算**记下来**。算术不在这里 —— 它在 sale_settlement_compute。
--
-- ★【一处实现,两个调用者】★ 预览与落库读**同一段算术**。本仓库为
--   "两份实现在写下来那天一致、之后悄悄分开"付过四次账(AGENTS.md 的预览规则)。
--
-- ★【它是 SECURITY DEFINER,所以它【自己】问一次权限】★
--   sales_settlements 没有 INSERT 策略(刻意的:检查与写入必须同一笔事务,
--   否则分两步之间那道缝足够让一份不合口径的结算先被写下来)。
--   而"一支 definer 函数没有权限检查"是本仓库点名过的陷阱 —— 所以下面第一件事
--   就是按名问一次,而不是靠调用它的人记得先问。
--
-- ★【它【不过账】】★ 一分钱都不进总账。理由两条,各自独立:
--   ① 会计政策 5.7 自己标着 NOT BUILT;② PRICE-1 声明过断点,两阶段开票还不存在。
DECLARE
    v_r  jsonb;
    v_id uuid;
BEGIN
    IF NOT has_permission('module.customers.edit'::text) THEN
        RAISE EXCEPTION 'SETTLEMENT_PERMISSION_DENIED|%', 'module.customers.edit'
          USING HINT = '记录一次销售结算要有客户模块的编辑权限 —— 这不是数据缺失,是权限';
    END IF;

    -- 算(所有拒绝都在那一支里,而它们与写入在同一笔事务)
    v_r := sale_settlement_compute(p_sales_order_id, p_output_batch_id, p_assay_result_id);

    INSERT INTO sales_settlements (
        sales_order_id, output_batch_id, assay_result_id,
        settling_party_used, weight_basis_used,
        gross_weight_kg, moisture_pct, settlement_weight_kg,
        metal_value_usd, refining_charge_usd, penalty_usd, amount_usd,
        breakdown, terms_snapshot, computed_by)
    VALUES (
        p_sales_order_id, p_output_batch_id, p_assay_result_id,
        v_r->>'settling_party_used', v_r->>'weight_basis_used',
        (v_r->>'gross_weight_kg')::numeric,
        (v_r->>'moisture_pct')::numeric,
        (v_r->>'settlement_weight_kg')::numeric,
        (v_r->>'metal_value_usd')::numeric,
        (v_r->>'refining_charge_usd')::numeric,
        (v_r->>'penalty_usd')::numeric,
        (v_r->>'amount_usd')::numeric,
        v_r->'breakdown', v_r->'terms_snapshot', auth.uid())
    RETURNING id INTO v_id;

    RETURN v_r || jsonb_build_object('settlement_id', v_id, 'posted_to_ledger', false);
END
$function$;

COMMENT ON FUNCTION public.record_sale_settlement(uuid, uuid, uuid) IS
    'SETTLE-1:把一次销售结算**记下来** —— **它不过账**(返回值里那句 posted_to_ledger=false 是刻意印出来的)。算术在 sale_settlement_compute:**一处实现,两个调用者**,预览与落库读同一段算术(本仓库为「两份实现悄悄分开」付过四次账)。★**它是 SECURITY DEFINER,所以它自己先按名问一次权限**★ —— sales_settlements 没有 INSERT 策略(刻意的:检查与写入必须同一笔事务),而「definer 函数没有权限检查」是本仓库点名过的陷阱。★**为什么不过账**★:① 会计政策 5.7 自己标着 NOT BUILT(差额科目已裁定、过账路径没有);② PRICE-1 声明过断点,两阶段开票还不存在,**没有开票就没有东西喂给过账路**。';
