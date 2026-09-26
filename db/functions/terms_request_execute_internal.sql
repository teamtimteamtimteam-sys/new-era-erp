-- db/functions/terms_request_execute_internal.sql
-- APR-8(2026-09-26):一张条款申请的【生效本身】—— 只从批准、审批关着时的提交与试跑里调用。
--   0. fingerprint 再算一遍,与提交时不一样 → TERMS_CHANGED_SINCE_REQUEST|label(grilling Q5)。
--   公式三种:主体要在(FORMULA_NOT_FOUND);修改时仍要在用(FORMULA_NOT_ACTIVE);proposed 就地写进表头与
--     逐金属比例(不在 proposed 里的金属删掉 = 不计价;没变的比例不写,于是 pricing_formula_history 只记真的变动),
--     is_active = true。
--   合同:仍是 draft 或 suspended(CONTRACT_NOT_ACTIVATABLE)→ status = active。条款在七张表里,提交时已冻结。
-- 属主路径写(本支 SECURITY DEFINER):两支直连写守卫看不见它,那正是它们该有的样子。
-- 内层算子,无调用者检查;EXECUTE 已从 authenticated 收回。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.terms_request_execute_internal(p_request_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_r      terms_requests%ROWTYPE;
    v_code   text;
    v_active boolean;
    v_status text;
    v_t      jsonb;
BEGIN
    SELECT * INTO v_r FROM terms_requests WHERE id = p_request_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'TERMS_REQUEST_NOT_FOUND|%', COALESCE(p_request_id::text, '?');
    END IF;
    IF terms_request_fingerprint(v_r.kind, COALESCE(v_r.formula_id, v_r.contract_id)) IS DISTINCT FROM v_r.fingerprint THEN
        RAISE EXCEPTION 'TERMS_CHANGED_SINCE_REQUEST|%', v_r.label;
    END IF;

    IF v_r.kind = 'contract_activate' THEN
        SELECT code, status INTO v_code, v_status FROM contracts
         WHERE id = v_r.contract_id AND deleted_at IS NULL FOR UPDATE;
        IF v_code IS NULL THEN
            RAISE EXCEPTION 'CONTRACT_NOT_FOUND|%', v_r.contract_id;
        END IF;
        IF v_status NOT IN ('draft', 'suspended') THEN
            RAISE EXCEPTION 'CONTRACT_NOT_ACTIVATABLE|%|%', v_code, v_status;
        END IF;
        UPDATE contracts SET status = 'active' WHERE id = v_r.contract_id;
        RETURN jsonb_build_object('contract_id', v_r.contract_id, 'code', v_code, 'status', 'active');
    END IF;

    SELECT code, is_active INTO v_code, v_active FROM pricing_formulas
     WHERE id = v_r.formula_id AND deleted_at IS NULL FOR UPDATE;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'FORMULA_NOT_FOUND|%', v_r.formula_id;
    END IF;
    IF v_r.kind = 'formula_change' AND NOT v_active THEN
        RAISE EXCEPTION 'FORMULA_NOT_ACTIVE|%', v_code;
    END IF;
    v_t := v_r.proposed;
    UPDATE pricing_formulas
       SET name = v_t->>'name',
           direction = v_t->>'direction',
           price_basis = v_t->>'price_basis',
           average_days = (v_t->>'average_days')::integer,
           treatment_charge_usd_per_tonne = (v_t->>'treatment_charge_usd_per_tonne')::numeric,
           flat_discount_pct = (v_t->>'flat_discount_pct')::numeric,
           supplier_id = (v_t->>'supplier_id')::uuid,
           customer_id = (v_t->>'customer_id')::uuid,
           price_index = v_t->>'price_index',
           notes = v_t->>'notes',
           is_active = true
     WHERE id = v_r.formula_id;
    DELETE FROM pricing_formula_metals m
     WHERE m.formula_id = v_r.formula_id
       AND m.metal NOT IN (SELECT e->>'metal' FROM jsonb_array_elements(v_t->'metals') e);
    INSERT INTO pricing_formula_metals (formula_id, metal, payable_pct)
    SELECT v_r.formula_id, e->>'metal', (e->>'payable_pct')::numeric
      FROM jsonb_array_elements(v_t->'metals') e
    ON CONFLICT (formula_id, metal) DO UPDATE SET payable_pct = EXCLUDED.payable_pct
     WHERE pricing_formula_metals.payable_pct IS DISTINCT FROM EXCLUDED.payable_pct;
    RETURN jsonb_build_object('formula_id', v_r.formula_id, 'code', v_code, 'is_active', true);
END;
$function$;
