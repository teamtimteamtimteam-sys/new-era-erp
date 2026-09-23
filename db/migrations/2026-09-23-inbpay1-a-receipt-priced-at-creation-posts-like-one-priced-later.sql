-- INB-PAY-1(2026-09-23):建单时带价的收货,与之后再定价的收货【过同一条账】
--
-- 【缺陷】create_inbound_batch 把 p_unit_price 直接写进 inbound_batches.unit_price:
-- 没有 purchase 分录(没有 Cr 2000 应付)、没有 price_history 行。之后再对它定价,
-- reprice_inbound_batch 只按【价差】过账(新价 − 旧价)× 数量 —— 于是建单时那一段
-- 旧价 × 数量【永远不进总账】,而 ap_open_items / apply_prepayment 按
-- 数量 × 单价认欠款:明细账与总账 2000 各说各话。
--
-- 【线上没有实例】(以 postgres 读基表,rolbypassrls = t):有价而无 price_history 行
-- 的批次 0 张;每张有价批次的第一条 price_history 都从 old_unit_price = NULL 起。
-- IN-2026-0011 / 0012 不是本缺陷 —— 它们在 2026-07-05 经定价那一步定的价,
-- 早于 2026-07-06 开始过应付(见 docs/known-wrong-until-cutover.md)。
--
-- 【修法 · Tim Q2 = A】建单【先不带价落库】,再在同一事务里调 reprice_inbound_batch ——
-- 与定价那一步是【同一份实现】:同一张分录、同一行价格史、同一组拒绝
-- (PRICE_INVALID / CURRENCY_INVALID / FX_RATE_MISSING)。本函数一个字都不重复它们。
-- 任何一条拒绝 = 整笔建单回滚,不会留下一张没价的半截批次。
--
-- 【新增尾部参数 p_currency】价格的币种。【没有默认值】:币种决定汇率,
-- 而汇率决定入账金额 —— AGENTS.md 那条"决定汇率的字段不给服务端默认值"。
-- 带价而不给币种 → reprice_inbound_batch 按名拒 CURRENCY_INVALID|?。
-- 不带价时 p_currency 不被读取(表单总是带着币种选择器的值)。
--
-- 【过账日】沿用"记于定价日"(Tim Q5):reprice_inbound_batch 按 CURRENT_DATE 入账
-- 并按 CURRENT_DATE 的 tt_sell 估值 —— 与之后再定价逐字相同。
--
-- 签名变了(多一个尾部参数),照 PROC-2c / RECV-SOURCE-1 的先例:DROP + CREATE,
-- 再把 EXECUTE 收回、授出。

BEGIN;

DROP FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text);

CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_id      uuid;
    v_warn    text[];
    v_pricing jsonb := NULL;
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- GRN-1a:p_declared_qty 原样落库,【不拒绝任何差异】,也【绝不从采购行推断】。
    -- PROC-2c:确定度随表头一起落 —— 适用性由 trg_inbound_batches_condition_applicable
    -- 判(它在库里,所以这条路、批次页面、直连 SQL 三条一起盖住)。
    -- RECV-SOURCE-1:理由原样落库,拒绝(RECEIPT_SOURCE_REQUIRED /
    -- SOURCE_REASON_EXPLANATION_REQUIRED)由 guard_receipt_source_stated 抛 ——
    -- 本函数一个字都不重复它们,重复一遍就是第二份会漂开的判断。
    -- INB-PAY-1:unit_price 【不在这里落】—— 见下面定价那一段。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user)
    RETURNING id INTO v_id;

    -- PROC-2c:安全状态【只在给了参数时才碰】。
    -- 【NULL 与 '{}' 在这里是两件事】NULL = "这条路没提这件事"(既有调用点),
    -- '{}' = "明说了:一个状态都没有"。两者结果相同(零行),但只有前者
    -- 保证【一个字节都不动】—— F1 钉的正是这个。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);

    -- INB-PAY-1:建单带价 = 建单 + 定价,【同一事务、同一份定价实现】。
    -- reprice_inbound_batch 写 price_history、按定价日过 purchase 分录(Dr 1200 / Cr 2000),
    -- 并按名拒绝非正价格、非法币种与缺牌价 —— 任何一条拒绝都让整笔建单回滚。
    IF p_unit_price IS NOT NULL THEN
        v_pricing := reprice_inbound_batch(v_id, p_unit_price, p_currency, NULL, NULL);
    END IF;

    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    -- INB-PAY-1:定价的分解(含分录号)随之返回;不带价时为 null。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn),
                              'pricing', v_pricing);
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text, text) TO authenticated, service_role;

COMMIT;
