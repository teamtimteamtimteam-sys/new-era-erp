-- db/migrations/2026-08-13-iod2-allowed-classes-enforcement.sql
-- IOD-2:allowed_classes 在【那一扇门】上落闸 —— 三态判词只写一处
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【这一刀把哪句话变成过去时】
-- LOC-1 建了 storage_location_allowed_classes,并写下"落闸的地方是出入库单据
-- 那一刀";IOD-1 落完了、没有设闸;IOD-1 的 fu3 把那句指着已过去时点的注释改
-- 指 IOD-2。今天这一刀落闸,所以【同一支迁移里把那条记录退役】—— 一句描述
-- 已不存在的状态的注释,和一句断言不可能发生的危险的注释,是同一种缺陷
-- (AGENTS.md)。表头从"本表只记录,不设闸"改成"闸在哪里"。
--
-- 【为什么只有一处判词】IOD-1b 把建批次收归三个 RPC,理由写得很直白:一个留着
-- 侧门的卡口不是卡口,而两处判断迟早漂开。那一刀把门收成一扇,这一刀只需要在
-- 门上加判断 —— 四个落地点共用 check_location_class 一个函数,判词因此只有一份。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【落闸的范围:只在"货落进某处"的那一条腿上】
--
-- 检查发生在【落地腿】:三个建批次 RPC(收货落进库位)与 create_stock_transfer
-- 的【入】腿(transfer_in)。
--
-- 【出库腿与状态变更永不检查】—— transfer_out、销售排空、投料消耗、暂扣/释放,
-- 一个都不查。理由不是"以后再说",是判据本身:分类管的是【货可以待在哪里】,
-- 不是【货能不能离开】。一批放错地方的货,拦住它【离开】只会把它焊死在错的
-- 地方 —— 那恰好是与合规意图相反的结果。同理,暂扣/释放动的是状态不是位置,
-- 没有任何东西落进新的地方,也就没有任何关于"哪里"的断言需要成立。
--
-- 【明确不在本刀范围内:已经躺在那里的货】
-- 配置是会变的 —— 有人今天把某一类从某个库位的许可里删掉,而那个库位上【已经
-- 躺着】那一类货。本刀【不】处理这件事,一次都不查。因为落地腿只在货移动的那
-- 一刻被调用,而那批货不会再移动一次给它机会;要发现它,必须有人【主动去扫】
-- 全部现存库存。那是一个报表/告警问题,不是一个卡口问题:卡口只能拦住正在发生
-- 的事。已排入告警/通知那一刀。在此之前,【本系统不会告诉任何人这种存量冲突
-- 存在】—— 这句话写在这里,是因为落闸之后最容易产生的错觉恰恰是"分类现在被
-- 管住了"。管住的只有【新落地的货】。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【三态,以及那个被实测撞到过的陷阱】
--
-- 天真的谓词是这一句:
--     EXISTS (SELECT 1 FROM storage_location_allowed_classes
--             WHERE location_id = ? AND classification_code = m.waste_classification_code)
-- 它读起来像"这个库位允许这类物料吗",而它【在两处各撒一次谎】:
--
--   1. 库位一行都没配 → EXISTS 为假 → 拒绝。可是零行的意思是【还没有人决定
--      过】,不是"决定了不许"。把"没人想过"演成"想过、结论是不行"。
--   2. 物料 waste_classification_code IS NULL(未分类)→ 等值比较得 NULL →
--      EXISTS 为假 → 拒绝。【IOD-1 的 survey 在本地重建上真的撞到了这一条】:
--      未分类物料落在一个配置齐全的库位上,天真谓词把它送进拒绝,而没有任何人
--      做过这个决定。未分类不是"被排除",是【没人分过类】。
--
-- 所以判据是三分而不是二分,而分界线是【有没有人做过决定】:
--
--   零行(库位未配置)          → 告警 IOD_CLASS_UNCONFIGURED_LOCATION|<库位>
--   物料未分类                  → 告警 IOD_MATERIAL_UNCLASSIFIED|<物料>
--                                 【包括落在已配置库位上的时候】
--   配了、且不含这一类          → 拒绝 IOD_CLASS_EXCLUDED|<库位>|<分类>
--   配了、且含这一类;或未指定库位 → 静默
--
-- 一句话:【只有一次明确的人为排除才拒绝;缺失的决定一律告警】。前两态都是
-- "还没有人决定过",而拒绝一次没人做过的决定,是把系统的沉默说成人的意志。
-- 第三态是决定得出来的 —— 有人配了这个库位、并且没有把这一类放进去 —— 所以
-- 它【可以】拒绝。
--
-- 两个告警可以【同时】出现(库位没配 且 物料没分类):它们是两个各自独立缺失
-- 的决定,压成一条会让操作员只去补其中一件。
--
-- 【未指定库位一次都不查】p_location_id IS NULL 是一等状态(LOC-1/STK-1),
-- 不是缺失。没有货落进任何"那里",也就没有任何关于"那里"的断言需要成立。
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【为什么三个建批次 RPC 必须 DROP 再 CREATE】
-- 告警要随【返回值】回到界面(抛不得 —— 抛了就成了拒绝),而那三个今天
-- RETURNS uuid,装不下一个告警数组。改返回类型不是 CREATE OR REPLACE 能做的事
-- (PostgreSQL 直接拒绝),所以【同一支迁移里先 DROP 后 CREATE】,参数签名一个
-- 字不改。preflight 认得这个形状(它只认本文件里、在 CREATE 之前出现的 DROP)。
--
-- 【DROP 会一并丢掉 EXECUTE 授权】—— 而 apply_migration.sh 在同一个事务里重放
-- db/views/zzz_function_grants.sql,那里的 GRANT ... ON ALL FUNCTIONS TO
-- authenticated 会把三个入口重新授回。check_location_class 是内层函数,反过来
-- 需要在那个文件里【显式 REVOKE】,否则同一句 GRANT 会把它敞开(见该文件)。
--
-- 镜像:db/functions/{check_location_class,create_inbound_batch,
--       receive_inbound_batch_against_po,create_output_batch,
--       create_stock_transfer}.sql、db/tables/storage_location_allowed_classes.sql、
--       db/views/zzz_function_grants.sql。
-- 行为断言:fixture 59。
-- ═══════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 判词:一处,四个落地点共用 ═════════════════════════════════════════
-- 【返回告警、抛出拒绝】两种结果的性质不同,所以走两条通道:告警是"这一次成功
-- 了,但有件事没人决定过",必须让写入发生;拒绝是"这一次什么都不该发生",必须
-- 中止事务。把告警也做成返回值的另一个好处:调用方【不可能忽略它而仍然编译通过】
-- ——它就在返回的 jsonb 里,而不是某个要记得去查的旁路。
--
-- 【库位的存在性/停用不在这里】那两条由 resolve_receipt_location(三个收货 RPC)
-- 与 create_stock_transfer 自己的 IOD_TRANSFER_TO_INACTIVE 各自先判过。这里再判
-- 一遍就是第二份会漂开的判断。
CREATE OR REPLACE FUNCTION public.check_location_class(p_location_id uuid, p_material_id uuid)
 RETURNS text[]
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_loc_code   text;
    v_mat_code   text;
    v_class      text;
    v_configured boolean;
    v_warn       text[] := '{}';
BEGIN
    -- 未指定库位:什么都没被断言,什么都不查。
    IF p_location_id IS NULL THEN
        RETURN v_warn;
    END IF;

    SELECT code INTO v_loc_code
    FROM storage_locations WHERE id = p_location_id;

    SELECT code, waste_classification_code INTO v_mat_code, v_class
    FROM materials WHERE id = p_material_id;

    v_configured := EXISTS (
        SELECT 1 FROM storage_location_allowed_classes
        WHERE location_id = p_location_id);

    -- 【第一态】没有人给这个库位配过任何一类 —— 告警,绝不拒绝。
    IF NOT v_configured THEN
        v_warn := v_warn || ('IOD_CLASS_UNCONFIGURED_LOCATION|' || COALESCE(v_loc_code, '?'));
    END IF;

    -- 【第二态】没有人给这个物料分过类 —— 告警,【在已配置的库位上也是告警】。
    -- 这一支就是天真谓词撒的第二个谎所在:等值比较遇上 NULL 得 NULL,于是
    -- "没人分过类"被判成"不在允许清单里"。两者在合规上不是一回事。
    IF v_class IS NULL THEN
        v_warn := v_warn || ('IOD_MATERIAL_UNCLASSIFIED|' || COALESCE(v_mat_code, '?'));
    END IF;

    -- 【第三态,也是唯一会拒绝的一态】两个决定都在:有人配了这个库位,并且
    -- 没有把这一类放进去。这是一次可判定的、明确的人为排除,所以它【可以】拒绝。
    IF v_configured AND v_class IS NOT NULL
       AND NOT EXISTS (
           SELECT 1 FROM storage_location_allowed_classes
           WHERE location_id = p_location_id
             AND classification_code = v_class) THEN
        RAISE EXCEPTION 'IOD_CLASS_EXCLUDED|%|%', COALESCE(v_loc_code, '?'), v_class;
    END IF;

    RETURN v_warn;
END;
$function$;

-- ═══ 2 · 落地点一:建进料批次 ═══════════════════════════════════════════════
DROP FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    -- 【顺序要紧】库位先校验再落库:拒绝必须发生在写入之前,否则一次被拒的
    -- 收货会留下半个批次(单事务会回滚,但错误信息的语义也该是"什么都没发生")。
    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸。同样在写入之前 —— 它可能抛 IOD_CLASS_EXCLUDED。
    v_warn := check_location_class(p_location_id, p_material_id);

    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, unit_price, notes, purchase_order_id, purchase_order_line_id,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_unit_price, p_notes, p_purchase_order_id, p_purchase_order_line_id,
        v_user, v_user)
    RETURNING id INTO v_id;

    -- 用毕即清 —— 同 commit_processing_run 的 movement_ctx:免得同事务内后续的
    -- 插入把这个库位当成自己的(那正是 ctx 这种机制唯一的锋利处)。
    PERFORM set_config('evoltrya.location_ctx', '', true);
    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

-- ═══ 3 · 落地点二:凭采购单收货 ═════════════════════════════════════════════
DROP FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid);

CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.inbound.edit');

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);

    -- 单位固定 kg、stage 用默认值 —— 与收货表单今天的行为逐字一致。
    -- 【采购单侧的那一串拒绝(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
    --  PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED)仍由表上的触发器抛出】,
    -- 这个函数一个字都不重复它们 —— 重复一遍就是第二份会漂开的判断。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

-- ═══ 4 · 落地点三:建产出批次 ═══════════════════════════════════════════════
DROP FUNCTION public.create_output_batch(uuid, numeric, text, date, text, uuid, text, text, uuid);

CREATE OR REPLACE FUNCTION public.create_output_batch(p_material_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_output_date date DEFAULT NULL::date, p_state text DEFAULT '库存中'::text, p_customer_id uuid DEFAULT NULL::uuid, p_purity text DEFAULT NULL::text, p_notes text DEFAULT NULL::text, p_location_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_warn text[];
BEGIN
    PERFORM require_permission('module.output.edit');

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);

    INSERT INTO output_batches (
        material_id, customer_id, quantity, unit, remaining_qty, output_date,
        state, purity, notes, created_by, updated_by)
    VALUES (
        p_material_id, p_customer_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_output_date,
        COALESCE(p_state,'库存中'), p_purity, p_notes, v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

-- ═══ 5 · 落地点四:转移的【入】腿 ═══════════════════════════════════════════
-- 返回类型本来就是 jsonb —— 这一个不需要 DROP,加一个 warnings 键即可。
CREATE OR REPLACE FUNCTION public.create_stock_transfer(p_qty numeric, p_to_location_id uuid, p_inbound_batch_id uuid DEFAULT NULL::uuid, p_output_batch_id uuid DEFAULT NULL::uuid, p_from_location_id uuid DEFAULT NULL::uuid, p_stock_status text DEFAULT 'available'::text, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_pair     uuid := gen_random_uuid();
    v_have     numeric;
    v_today    date := CURRENT_DATE;
    v_material uuid;
    v_warn     text[];
BEGIN
    PERFORM require_permission('module.inventory.edit');

    IF num_nonnulls(p_inbound_batch_id, p_output_batch_id) <> 1 THEN
        RAISE EXCEPTION 'STK_ONE_BATCH';
    END IF;
    IF p_qty IS NULL OR p_qty <= 0 THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_qty::text, '?');
    END IF;
    IF p_stock_status IS NULL OR p_stock_status NOT IN ('available','on_hold') THEN
        RAISE EXCEPTION 'STK_QTY_INVALID|%', COALESCE(p_stock_status, '?');
    END IF;
    -- 【源与目的相同】不是一次无害的空操作:它会写下两行互相抵消的流水,
    -- 把台账弄脏,而且几乎总是意味着操作的人选错了一边。
    IF p_from_location_id IS NOT DISTINCT FROM p_to_location_id THEN
        RAISE EXCEPTION 'IOD_TRANSFER_SAME_LOCATION';
    END IF;
    -- 目的地必须是一个【在用】的库位。停用的库位不该再收货(LOC-1 的停用语义)。
    IF p_to_location_id IS NULL
       OR NOT EXISTS (SELECT 1 FROM storage_locations WHERE id = p_to_location_id AND is_active) THEN
        RAISE EXCEPTION 'IOD_TRANSFER_TO_INACTIVE|%', COALESCE(p_to_location_id::text, '?');
    END IF;

    -- 【同一粒度】对着派生桶比,与 STK-1 的暂扣/释放一模一样:
    -- remaining_qty 没有库位轴,在这个粒度上现算是唯一可能的来源。
    v_have := derived_stock_qty(p_inbound_batch_id, p_output_batch_id, p_from_location_id, p_stock_status);
    IF p_qty > v_have THEN
        RAISE EXCEPTION 'IOD_TRANSFER_EXCEEDS_BUCKET|%|%', p_qty, v_have;
    END IF;

    -- IOD-2:落闸,【只在入腿上】。物料从批次反查 —— 两种批次二选一(上面的
    -- XOR 已经保证恰好一个非空),两张表都有 material_id NOT NULL。
    -- 【出腿一个字都不查】:分类管的是货可以待在哪里,不是货能不能离开;拦住
    -- 一批放错地方的货【离开】,只会把它焊死在错的地方。
    v_material := COALESCE(
        (SELECT material_id FROM inbound_batches WHERE id = p_inbound_batch_id),
        (SELECT material_id FROM output_batches  WHERE id = p_output_batch_id));
    v_warn := check_location_class(p_to_location_id, v_material);

    -- 成对:出源库位、进目的库位。【状态原样带过去】—— 转移搬的是位置,
    -- 不是状态;一批被扣住的货换个货架仍然是被扣住的。
    INSERT INTO inventory_movements
        (inbound_batch_id, output_batch_id, location_id, movement_type,
         qty_delta, stock_status, pair_id, business_date, notes, created_by)
    VALUES
        (p_inbound_batch_id, p_output_batch_id, p_from_location_id, 'transfer_out',
         -p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user),
        (p_inbound_batch_id, p_output_batch_id, p_to_location_id, 'transfer_in',
          p_qty, p_stock_status, v_pair, v_today, NULLIF(btrim(COALESCE(p_note,'')),''), v_user);

    RETURN jsonb_build_object('pair_id', v_pair, 'qty', p_qty,
                              'stock_status', p_stock_status,
                              'warnings', to_jsonb(v_warn));
END;
$function$;

-- ═══ 6 · 退役那条指向未来的记录 ═════════════════════════════════════════════
-- "落闸归 IOD-2"从今天起是过去时。新表头说清【闸在哪里、放过什么、以及它看
-- 不见什么】—— 最后一条尤其要写:落闸之后最容易产生的错觉就是"分类被管住了"。
COMMENT ON TABLE public.storage_location_allowed_classes IS
    'LOC-1:库位可存放的受控物料分类。一行 = 这个库位可以放这一类。【零行 = 未配置 = 还没决定】,检查对它告警而绝不拒绝 —— 与"配了、但不含这一类"(有人做过决定,该拒)是两回事,压成一个布尔量就是把"没人想过"演成"想过、结论是不行"。【IOD-2 起本表设闸】:判词是 check_location_class(库位, 物料),由四个落地点共用 —— 三个建批次 RPC 与 create_stock_transfer 的入腿。三态:零行告警 IOD_CLASS_UNCONFIGURED_LOCATION;物料未分类告警 IOD_MATERIAL_UNCLASSIFIED(【在已配置库位上也只是告警】—— 未分类不是被排除,是没人分过类,天真的 EXISTS 谓词会把它送进拒绝);配了且不含这一类才拒绝 IOD_CLASS_EXCLUDED。【闸只拦正在落地的货】:出库腿与状态变更永不检查(分类管的是货待在哪里,不是能不能离开);而【配置改变后已经躺在那里的存量冲突,本系统今天不会告诉任何人】—— 那要主动扫全量库存,是报表/告警问题,已排入告警那一刀。';

COMMIT;
