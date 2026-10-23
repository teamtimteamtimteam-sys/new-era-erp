-- db/migrations/2026-10-23-table-export-2b1-formula-masked-terms-unchanged.sql
-- TABLE-EXPORT-2b-1(v1.4.69)—— Tim 2026-10-23 TABLE-EXPORT-2b Q5:改一张定价公式时,看不见它条款的人【不能】把被遮住的条款存成 0。
--
-- 【缺陷,量过的】/tools/pricing/formulas/[id]/edit 读 pricing_formulas_masked;看不见条款的人(sale 公式缺 data.view_prices、
--   purchase / both 缺 data.view_purchase_prices)读到的加工费与折扣是 NULL,表单预填成空白,actions.ts 把空白读成 0 提交;
--   formula_terms_normalize 也把缺的两项读成 0。批准之后公式上的加工费与折扣就是 0。计价比例同理(被遮的比例清空 = 不计价)。
-- 【本刀做什么】两扇改公式的门(submit_formula_change_request · submit_formula_reactivate_request)在交给
--   terms_request_submit_internal 之前,对看不见条款的提交人把三项换回库里此刻的值(formula_terms_state)——「受限」的格子是【不改】。
--   判据仍是那一支 pricing_formula_terms_visible(此刻的方向),不另写一份。看得见的人一个字节都不变。
--   签名不变(不是重载;preflight 会查)。新建公式的门不动:新公式没有「此刻的值」。
-- 【不做什么】不碰审批开关、hook、存储、任何账号与角色;不建任何单据;不改任何一行数据 —— 只换两支函数体。
-- 【破窗】旧应用 + 新库:旧的编辑页对看不见条款的人仍预填空白、仍提交 0;新库把那三项换回原值 —— 窗口里坏掉的方向是【变好】,没有路被打断。
-- 证明:db/fixtures/292(gate 里跑,看不见的人 / 看得见的人两臂分得开)与 db/scripts/2026-10-23-table-export-2b1-live-proof.mjs(线上,整支回滚)。

BEGIN;

CREATE OR REPLACE FUNCTION public.submit_formula_change_request(p_formula_id uuid, p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_dir text;
    v_now jsonb;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    IF p_terms IS NULL THEN
        RAISE EXCEPTION 'TERMS_FORMULA_INVALID|terms';
    END IF;
    SELECT direction INTO v_dir FROM pricing_formulas WHERE id = p_formula_id AND deleted_at IS NULL;
    IF v_dir IS NOT NULL AND NOT pricing_formula_terms_visible(v_dir) THEN
        v_now := formula_terms_state(p_formula_id);
        p_terms := p_terms || jsonb_build_object(
            'treatment_charge_usd_per_tonne', v_now->'treatment_charge_usd_per_tonne',
            'flat_discount_pct', v_now->'flat_discount_pct',
            'metals', v_now->'metals');
    END IF;
    RETURN terms_request_submit_internal('formula_change', p_formula_id, p_terms, p_reason);
END;
$function$;

CREATE OR REPLACE FUNCTION public.submit_formula_reactivate_request(p_formula_id uuid, p_terms jsonb, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_dir text;
    v_now jsonb;
BEGIN
    PERFORM require_permission('module.pricing.edit');
    SELECT direction INTO v_dir FROM pricing_formulas WHERE id = p_formula_id AND deleted_at IS NULL;
    IF p_terms IS NOT NULL AND v_dir IS NOT NULL AND NOT pricing_formula_terms_visible(v_dir) THEN
        v_now := formula_terms_state(p_formula_id);
        p_terms := p_terms || jsonb_build_object(
            'treatment_charge_usd_per_tonne', v_now->'treatment_charge_usd_per_tonne',
            'flat_discount_pct', v_now->'flat_discount_pct',
            'metals', v_now->'metals');
    END IF;
    RETURN terms_request_submit_internal('formula_reactivate', p_formula_id, p_terms, p_reason);
END;
$function$;

-- 自证:审批仍开着;签名仍是一个(没有重载)。
DO $$
BEGIN
    IF NOT approvals_enabled() THEN
        RAISE EXCEPTION 'TE2B1_SELFCHECK|approvals are off';
    END IF;
    IF (SELECT count(*) FROM pg_proc WHERE proname IN ('submit_formula_change_request', 'submit_formula_reactivate_request')
          AND pronamespace = 'public'::regnamespace) <> 2 THEN
        RAISE EXCEPTION 'TE2B1_SELFCHECK|overload';
    END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';

COMMIT;
