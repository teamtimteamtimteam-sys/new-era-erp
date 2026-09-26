-- db/functions/guard_contract_terms_frozen.sql
-- APR-8(2026-09-26,grilling Q2 · Q5):七张条款表(品位 · 保险 · 数量 · 计价 · 结算 · 精炼费 · 罚则)在合同
-- 生效中、或挂着一张在等的生效申请时,任何直连写按名拒 CONTRACT_TERMS_FROZEN|合同编号|active 或那一张申请。
-- 改条款 = 暂停合同、编辑、申请重新生效(CFO 看见与上一次批准时那一份的差别)。
-- 行级,BEFORE INSERT OR UPDATE OR DELETE;UPDATE 把一行挪到别的合同上时两份都问。属主路径一律放行。
-- NOTE: introduced by db/migrations/2026-09-26-apr8-contract-terms-and-pricing-formulas-wait-for-the-cfo.sql.

CREATE OR REPLACE FUNCTION public.guard_contract_terms_frozen()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_id   uuid;
    v_lock text;
BEGIN
    IF NOT row_security_active(TG_RELID) THEN
        RETURN COALESCE(NEW, OLD);
    END IF;
    FOR v_id IN SELECT DISTINCT x FROM unnest(ARRAY[
                    CASE WHEN TG_OP <> 'INSERT' THEN OLD.contract_id END,
                    CASE WHEN TG_OP <> 'DELETE' THEN NEW.contract_id END]) x WHERE x IS NOT NULL LOOP
        v_lock := contract_terms_lock_reason(v_id);
        IF v_lock IS NOT NULL THEN
            RAISE EXCEPTION 'CONTRACT_TERMS_FROZEN|%|%',
                (SELECT c.code FROM contracts c WHERE c.id = v_id),
                CASE WHEN v_lock LIKE 'request:%' THEN substr(v_lock, 9) ELSE v_lock END;
        END IF;
    END LOOP;
    RETURN COALESCE(NEW, OLD);
END;
$function$;
