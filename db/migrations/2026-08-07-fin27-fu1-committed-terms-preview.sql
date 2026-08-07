-- FIN-27-fu1(2026-08-07):按承诺条款重计价的【试算】伴生函数。
--
-- 【为什么是马上补的一件事,而不是下一切】/inbound/[id]/edit 的"按当前含量重计价"
-- 面板是【先算后交】:点一下看到完整明细与影响,确认再提交。主切把提交侧换成了
-- 承诺副本(reprice_from_committed_terms),而预览侧仍在调 calculate_metal_price
-- ——【读的是活公式】。于是公式改过之后,面板会展示按新条款算的一个数,按下提交
-- 却按承诺条款落另一个数。那正是 AGENTS.md 里数过四次的同一个 bug:
-- "预览页面重实现记账规则,两份实现写下的当天一致、之后无声漂移,
-- 而人们信的偏偏是看得见的那一个。"
--
-- 【一份实现,两个调用方】把"解析承诺 + 取当前含量 + 算价"抽成
-- committed_terms_price();提交与试算都调它,谁也不许自己再算一遍
-- (reprice_split 之于 reprice / preview_reprice 的同一条关系)。
--
-- 应用:./db/apply_migration.sh db/migrations/2026-08-07-fin27-fu1-committed-terms-preview.sql

BEGIN;

-- 解析承诺 → 按批次【当前已录含量】算价。没有副本就点名拒(与提交侧同一句错误)。
CREATE OR REPLACE FUNCTION public.committed_terms_price(p_inbound_batch_id uuid, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_metals jsonb;
    v_calc   jsonb;
BEGIN
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
            COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
    END IF;

    SELECT jsonb_agg(jsonb_build_object('metal', ibm.metal, 'content_pct', ibm.content_pct))
    INTO v_metals
    FROM inbound_batch_metals ibm WHERE ibm.inbound_batch_id = v_batch.id;
    IF v_metals IS NULL THEN
        RAISE EXCEPTION 'NO_METALS';
    END IF;

    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), v_metals, v_batch.quantity, p_reference_date);

    RETURN v_calc || jsonb_build_object('commitment_id', v_commit, 'batch_code', v_batch.code);
END;
$function$;

-- 提交侧改为调用共用算子(其余不变)
CREATE OR REPLACE FUNCTION public.reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_batch   record;
    v_commit  uuid;
    v_formula uuid;
    v_calc    jsonb;
    v_unit    numeric;
    v_rep     jsonb;
BEGIN
    PERFORM require_permission('module.inbound.edit');

    SELECT id, code, pricing_formula_id INTO v_batch
    FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL
    FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    -- 【与试算同一份算术】committed_terms_price 里做承诺解析、含量读取与算价;
    -- 这里只负责落账。两条路不可能各算各的。
    v_calc   := committed_terms_price(p_inbound_batch_id, p_reference_date);
    v_commit := (v_calc->>'commitment_id')::uuid;
    v_unit   := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_unit IS NULL OR v_unit <= 0 THEN
        -- 净值 ≤ 0 的料不进价格机器(与 apply_assay_result 同一判断),但这里是人
        -- 主动按的按钮,所以点名说清楚,而不是默默什么都不做。
        RAISE EXCEPTION 'PRICE_NOT_POSITIVE|%', COALESCE(v_unit::text, '?');
    END IF;

    v_rep := reprice_inbound_batch(v_batch.id, v_unit, 'USD', NULL,
                                   'Repriced from committed terms');

    -- 批次上记下这张公式,界面据此显示"这批货归哪张公式管"(结算仍只读副本)
    SELECT c.source_formula_id INTO v_formula
    FROM pricing_term_commitments c WHERE c.id = v_commit;
    IF v_batch.pricing_formula_id IS NULL AND v_formula IS NOT NULL THEN
        UPDATE inbound_batches SET pricing_formula_id = v_formula, updated_by = v_user
        WHERE id = v_batch.id;
    END IF;

    RETURN jsonb_build_object(
        'inbound_batch_id', v_batch.id,
        'batch_code', v_batch.code,
        'commitment_id', v_commit,
        'unit_price_usd_per_kg', v_unit,
        'calc', v_calc,
        'old_unit_price', v_rep->'old_unit_price',
        'new_unit_price', v_rep->'new_unit_price',
        'price_delta_usd', v_rep->'price_delta_usd',
        'journal_code', v_rep->'journal_code'
    );
END;
$function$;

-- 试算:同一份算价 + 既有的拆账试算(preview_reprice_inbound_batch)。
-- 权限与提交侧一致地要求 module.inbound.edit —— 这个面板本来就只对能改价的人出现;
-- 拆账试算自己再要一次 data.view_prices(它对没有价格权限的人抛 PERMISSION_DENIED,
-- 界面显示"受限",这是既有行为)。
CREATE OR REPLACE FUNCTION public.preview_reprice_from_committed_terms(p_inbound_batch_id uuid, p_reference_date date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    v_calc := committed_terms_price(p_inbound_batch_id, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    -- 单价 ≤ 0 时不试算拆账(它会 PRICE_INVALID),但明细照给 —— 那种料
    -- apply_assay_result 本来也不会给它定价,摆一个"调整 −X 元"反而是误导。
    IF v_unit > 0 THEN
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit);
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;


-- 化验录入/详情页的"如果应用会怎样"。【同一条解析、同一份算术】——
-- 与 apply_assay_result 逐字同构:承诺解析 → 承诺条款算价 → 既有的拆账试算。
-- 差别只有一个:含量由调用方给(录入页上含量还在动,尚未落库)。
--
-- 三种结局,与 apply_assay_result 一一对应:
--   * 有副本 → 按副本算(哪怕公式此后被改、被停用、被软删);
--   * 没有副本但有活公式引用 → PRICING_TERMS_NOT_COMMITTED,当场说,而不是等
--     操作员录完一张化验单、按下"应用"才说;
--   * 连公式引用都没有 → calc 为 null(不是错误):手工定价的采购本来就由人定价。
CREATE OR REPLACE FUNCTION public.preview_assay_price(p_inbound_batch_id uuid, p_metals jsonb, p_reference_date date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_batch  record;
    v_commit uuid;
    v_live   uuid;
    v_calc   jsonb;
    v_unit   numeric;
    v_impact jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reference_date IS NULL THEN
        RAISE EXCEPTION 'REFERENCE_DATE_REQUIRED';
    END IF;

    SELECT id, code, quantity, pricing_formula_id, purchase_order_line_id
    INTO v_batch FROM inbound_batches
    WHERE id = p_inbound_batch_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', COALESCE(p_inbound_batch_id::text, '?');
    END IF;

    v_commit := resolve_pricing_commitment(v_batch.id);
    IF v_commit IS NULL THEN
        v_live := COALESCE(v_batch.pricing_formula_id,
                           (SELECT pol.pricing_formula_id FROM purchase_order_lines pol
                             WHERE pol.id = v_batch.purchase_order_line_id));
        IF v_live IS NOT NULL THEN
            RAISE EXCEPTION 'PRICING_TERMS_NOT_COMMITTED|%|%', v_batch.code,
                COALESCE((SELECT pf.code FROM pricing_formulas pf WHERE pf.id = v_live), '?');
        END IF;
        RETURN jsonb_build_object('calc', NULL, 'impact', NULL);
    END IF;

    v_calc := calculate_metal_price_from_terms(
        pricing_terms_of_commitment(v_commit), p_metals, v_batch.quantity, p_reference_date);
    v_unit := (v_calc->>'unit_price_usd_per_kg')::numeric;
    IF v_unit > 0 THEN
        v_impact := preview_reprice_inbound_batch(p_inbound_batch_id, v_unit);
    END IF;
    RETURN jsonb_build_object('calc', v_calc, 'impact', v_impact);
END;
$function$;

-- committed_terms_price 是内层算子(DEFINER、不查调用者)—— 靠调不到,不靠检查。
REVOKE EXECUTE ON FUNCTION public.committed_terms_price(uuid, date) FROM PUBLIC, anon, authenticated;

COMMIT;
