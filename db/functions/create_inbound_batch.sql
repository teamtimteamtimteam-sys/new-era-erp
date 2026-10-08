-- db/functions/create_inbound_batch.sql
-- MES-2(2026-10-06,MES-2 Step 0 Q19,Tim):末尾多三个参数(p_ticket_id · p_ticket_share_kg · p_quantity_reason),都带默认值 ——
--   签名变了,所以迁移是 DROP + CREATE(preflight 不许 CREATE OR REPLACE 换签名);已部署的旧应用不传它们,照样解析到这一支。
-- MES-3a(2026-10-06,MES-3a Step 0 Q9 · Q10 · Q19,Tim):写入之前过隔离闸(请求里带着要隔离的状态,就只能收进隔离库位);
--   落库之后对着执照的库存上限判一次并记下来(receipt_ceiling_check_internal)。签名不变;返回值多一个 'ceiling'(那一行)。
-- MES-4b(2026-10-07,MES-4b Step 0 Q4,Tim):末尾多一个可缺省的参数 p_cell_construction(电芯结构,收货时可选;空 = 没记)——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它,照样解析到这一支。适用性与锁由表上的 guard_batch_cell_construction 判。

-- MES-5a-1(2026-10-08,MES-5a Step 0 Q4,Tim):末尾多一个可缺省的参数 p_module_count(这一批有几个模组,收货时可选;空 = 没记)——
--   签名变了,迁移是 DROP + CREATE;已部署的旧应用不传它,照样解析到这一支。适用性由表上的 guard_batch_module_count 判。
CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text, p_currency text DEFAULT NULL::text, p_ticket_id uuid DEFAULT NULL::uuid, p_ticket_share_kg numeric DEFAULT NULL::numeric, p_quantity_reason text DEFAULT NULL::text, p_cell_construction text DEFAULT NULL::text, p_module_count integer DEFAULT NULL::integer)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ceiling jsonb;
    v_user    uuid := auth.uid();
    v_id      uuid;
    v_warn    text[];
    v_pricing jsonb := NULL;
BEGIN
    -- ★ ROLE-1 Batch 3b(Tim 2026-09-25,Batch 3 grilling Q1):建收货单归仓库 —— action.receive_goods
    --   (warehouse · admin),不再是 module.inbound.edit。先问它,所以拒绝点名的是它;带价那一支另外
    --   还要 action.price_receipts + data.view_purchase_prices(下面,不变 —— Batch 3b Q5)。
    PERFORM require_permission('action.receive_goods');
    -- ★ ROLE-1 Batch 4a(grilling Q4):建单【带价】就是定价 —— 要 action.price_receipts 与
    --   data.view_purchase_prices,在【写入之前】按名拒,整笔建单回滚;绝不悄悄丢掉那个价。
    --   不带价的建单只要 module.inbound.edit(仓库照建)。
    IF p_unit_price IS NOT NULL THEN
        PERFORM require_permission('action.price_receipts');
        PERFORM require_permission('data.view_purchase_prices');
    END IF;

    -- IOD-2-fu1:到货日【按名】必填。不写这一句,漏出去的是 FIN-32 的约束原文。
    -- 【不给默认值】:CURRENT_DATE 会让留空比填对更容易通过。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    -- MES-2(Tim 2026-10-06,MES-0 Q21 · MES-2 Step 0 Q19):建单【那一刻】挂一张地磅单的份 —— 数量默认 = 这一份,
    --   人填了别的数要写理由(收货单两个都留着:份的公斤数在 weighbridge_ticket_shares,数量在这里)。写入之前按名拒。
    IF p_ticket_id IS NULL AND (p_ticket_share_kg IS NOT NULL OR p_quantity_reason IS NOT NULL) THEN
        RAISE EXCEPTION 'TICKET_SHARE_WITHOUT_TICKET';
    END IF;
    IF p_ticket_id IS NOT NULL THEN
        IF COALESCE(p_unit, 'kg') <> 'kg' THEN
            RAISE EXCEPTION 'RECEIPT_TICKET_NEEDS_KG|%', p_unit;
        END IF;
        IF p_ticket_share_kg IS NULL OR p_ticket_share_kg <= 0 THEN
            RAISE EXCEPTION 'TICKET_SHARE_KG_INVALID';
        END IF;
        IF p_quantity IS DISTINCT FROM p_ticket_share_kg AND btrim(COALESCE(p_quantity_reason, '')) = '' THEN
            RAISE EXCEPTION 'RECEIPT_QUANTITY_REASON_REQUIRED|%|%', p_quantity, p_ticket_share_kg;
        END IF;
    END IF;

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- MES-3a(2026-10-06,MES-0 Q34;MES-3a Step 0 Q19,Tim):带着要隔离的状态(鼓包或漏液)只能收进一个在用的隔离库位 ——
    --   读的是【请求里】的状态(状态在落库之后才写,所以不能等它们),写入之前按名拒 QUARANTINE_LOCATION_REQUIRED。
    PERFORM assert_quarantine_landing(p_safety_states, p_location_id);

    -- GRN-1a:p_declared_qty 原样落库,【不拒绝任何差异】,也【绝不从采购行推断】。
    -- PROC-2c:确定度随表头一起落 —— 适用性由 trg_inbound_batches_condition_applicable
    -- 判(它在库里,所以这条路、批次页面、直连 SQL 三条一起盖住)。
    -- RECV-SOURCE-1:理由原样落库,拒绝(RECEIPT_SOURCE_REQUIRED /
    -- SOURCE_REASON_EXPLANATION_REQUIRED)由 guard_receipt_source_stated 抛 ——
    -- 本函数一个字都不重复它们,重复一遍就是第二份会漂开的判断。
    -- INB-PAY-1:unit_price 【不在这里落】—— 见下面定价那一段。
    -- MES-4b(Q4):电芯结构可选;给了就必须是一个在用的值(写入之前按名拒,不让外键报一串约束名)。
    IF NULLIF(btrim(COALESCE(p_cell_construction, '')), '') IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM cell_constructions c WHERE c.code = btrim(p_cell_construction) AND c.is_active) THEN
        RAISE EXCEPTION 'CELL_CONSTRUCTION_UNKNOWN|%', btrim(p_cell_construction);
    END IF;
    -- MES-5a-1(Q4):模组数可选;给了就必须是正数(写入之前按名拒,不让 CHECK 报一串约束名)。适用性由 guard_batch_module_count 判。
    IF p_module_count IS NOT NULL AND p_module_count <= 0 THEN
        RAISE EXCEPTION 'MODULE_COUNT_INVALID|%', p_module_count;
    END IF;

    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by, cell_construction_code, module_count)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_notes, p_purchase_order_id, p_purchase_order_line_id,
        p_declared_qty, p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user, NULLIF(btrim(COALESCE(p_cell_construction, '')), ''), p_module_count)
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

    -- MES-3a(2026-10-06,MES-0 Q32 · Q33;MES-3a Step 0 Q5–Q10,Tim):对着执照的库存上限判一次,并且【每一张都记下来】
    --   (receipt_ceiling_checks)。在落库之后判 —— 这一批的入库流水已经在存量里;超过一个给了的上限就按名拒
    --   STORAGE_CEILING_EXCEEDED,整笔回滚。没给上限 / 没有类别 / 没有在效执照:照收,记下是哪一种。
    v_ceiling := receipt_ceiling_check_internal(v_id, NULL);

    -- MES-2:地磅单的份【先于】定价落下 —— 建单带价时的定价会过校准闸,闸要看得见这张单的读数。
    IF p_ticket_id IS NOT NULL THEN
        PERFORM weighbridge_share_internal(p_ticket_id, v_id, NULL, p_ticket_share_kg,
                                           CASE WHEN p_quantity IS DISTINCT FROM p_ticket_share_kg THEN p_quantity_reason END);
    END IF;

    -- INB-PAY-1:建单带价 = 建单 + 定价,【同一事务】。
    -- ★ ROLE-1 Batch 4b(Tim 的 Q4):建单带价从此是【建单(不带价)+ 同一事务里提一张定价申请】
    --   (来源 desk)—— CFO 批了才进账;收货页上看得见它在等 CFO。提交时照批准那一刻的同一支过账
    --   试跑,所以非正价格、非法币种、缺牌价照旧按名拒,任何一条拒绝都让整笔建单回滚。
    --   审批关着时申请生下来就是 approved 并当场过账(与从前一样一步到位)。
    IF p_unit_price IS NOT NULL THEN
        v_pricing := receipt_price_submit_internal(v_id, p_unit_price, p_currency, 'desk', NULL, NULL, NULL);
    END IF;

    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    -- INB-PAY-1:定价的分解随之返回;不带价时为 null。ROLE-1 Batch 4b 起它是那张申请
    -- (request_id / label / status;审批关着时还有 journal_code)。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn),
                              'pricing', v_pricing, 'ceiling', v_ceiling);
END;
$function$

;
