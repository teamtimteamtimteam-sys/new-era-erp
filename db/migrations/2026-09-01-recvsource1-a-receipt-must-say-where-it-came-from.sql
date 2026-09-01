-- RECV-SOURCE-1:一张收货单必须说得出它从哪来 —— 采购行,或一个具名理由,永远不许两者皆无
--
-- ═══════════════════════════════════════════════════════════════════════════
-- 【缺陷的形状】(EFF-0 §4.4 缝 1 量过:16 个未软删进料批,8 个不带采购行)
-- 收货有两条路:对着采购单收,或直接建批(purchase_order_line_id 可空)。
-- 没人说过那 8 张是错的 —— 客户退货、免费样品、盘盈、(将来)来料加工,
-- 都是【正当地】没有采购单的收货。缺陷不是"没有 PO 的收货",而是
-- 【"本来就不该有 PO"与"没人填"在数据里一模一样】—— 本仓库反复修的那一种
-- 沉默,而这一次它长在审计轨迹的第一环:这批料从哪来。
--
-- 【Tim 的裁定】(RECV-SOURCE-1,已结)
--   R1 收货时必须给出【采购行 或 字典理由】之一,永远不许两者皆无
--      (至少其一,不互斥 —— 对着采购单又附送样品行是现实,不该拒);
--   R2 理由字典是【可扩展的数据】,播 4 行;第五个理由是一行,不是一次改码;
--   R3 "other" 必须带书面说明 —— 没有句子的 other 什么都没说
--      (与损耗类别拒绝匿名 other 桶是同一条推理);
--   R4 既有 8 张不回填 —— 猜一个理由是伪造历史。它们留着、在屏幕上【看得出
--      没说明】,Tim 哪天知道答案了再亲手补;
--   R5 拒绝在服务端 —— 禁用的提交按钮不是管控,本仓库证明过不止一次。
--
-- ★【为什么是触发器,不是 brief 点名的 CHECK … NOT VALID —— 判过,别再回来】★
-- NOT VALID 对 UPDATE 也强制。本表有【七个】函数会 UPDATE 它(commit/rollback_
-- processing_run、apply_assay_result、reprice ×2、post_stocktake、soft_delete),
-- IN-2026-0001 此刻正在加工中(余 887kg)。NOT VALID 会让那 8 张【加工不了、
-- 化验不了、改价不了、注销不了】,直到有人给它们编一个理由 —— 把 R4 的
-- "留着不说明"改写成"留着不能用",亲手制造 R4 禁止的回填压力。
-- 这笔账仓库已经付过:materials_kind_stated 至今冻着 7 行物料(assay_results
-- 的表注为此把"必填"改成了触发器,PROC-5 那一课)。本表自己的先例就在两条
-- 约束之外:guard_arrival_date_not_cleared —— 只拒 INSERT + 拒【由有变无】,
-- 历史的缺失活着,而且照样改得动。本刀逐字沿用那个形状。
--
-- 【三条建批路径,规则怎么够到每一条】(全部实测,pg_proc 里恰好两个函数插本表)
--   ① create_inbound_batch(DEFINER)—— 触发器在库里,够到;
--   ② receive_inbound_batch_against_po(DEFINER;名字带 PO 但 p_purchase_order_id
--      DEFAULT NULL,它也建无单批)—— 同上;
--   ③ postgres / service_role 直插(迁移、fixture、Management API、admin 客户端;
--      两者 rolbypassrls,RLS 拦不住)—— 触发器对它们照样开火。
--   这正是 SUP-TYPE-1a 把守卫放进触发器而不是 RPC 的同一条理由,原文就在
--   trg_inbound_batches_supplier_supplies_goods 头上。
--
-- 【A3 顺手落的第二道闸】只挂单头不挂明细行,说不出这批货对着【哪一行】——
-- 对"从哪来"它不是一个答案。线上实测 0 行,今天免费,以后不可能加
-- (EQP-PAY-1 的混单拒绝是同一笔账)。它是自己的具名拒绝
-- (PO_HEADER_WITHOUT_LINE),不混进来源规则里。
--
-- 【遮蔽表加列 = 三件事一支迁移】ADD COLUMN + 列级授权 + _masked 视图,全在本文件。
-- 【RUNTIME CONFIG】inbound_source_reasons 进 check_mirrors 的
-- RUNTIME_CONFIG_TABLES(同一提交)。
BEGIN;

-- ═══ 1 · 理由字典(R2:可扩展的数据,不是枚举)═══════════════════════════════

CREATE TABLE public.inbound_source_reasons (
    code                 text PRIMARY KEY,
    name_en              text NOT NULL,
    name_zh              text NOT NULL,
    -- 【规则列】这个理由要不要一句书面说明(R3)。做成列而不是把 'other' 写死在
    -- 触发器里:否则"第五个理由也要说明"就是一次改码 —— R2 与 R3 打架。
    -- 先例:material_sources.implies_never_charged / loss_categories.metal_fate。
    requires_explanation boolean NOT NULL,
    is_active            boolean NOT NULL DEFAULT true,
    sort_order           integer NOT NULL DEFAULT 0,
    notes                text
);

COMMENT ON TABLE public.inbound_source_reasons IS
'RECV-SOURCE-1:一张【没有采购行】的收货,为什么没有。RUNTIME CONFIG,加一个理由是加一行。

【与 material_sources 不是同一张表,不设外键,也永远不要"统一"它们】
基数就不对:那张表答"这一【种】物料从哪来",是【物料种类】的属性;
本表答"这一【张】收货为什么没挂采购行",是【这一票货】的属性。
一种厂内边角料(production_scrap)的货,完全可以以盘盈(stocktake_gain)的
方式出现在收货台上 —— 两个问题独立成立,谁也推不出谁。
(material_sources 的表注为它与 supplier_types 的独立写过三条理由;
本条与它同形,记在这里省得下一个人重推一遍。)

【is_active 只管表单下拉,触发器不看它】停用一个理由是"以后别再用",
不是"用过它的行从此非法" —— certificate_types 的处置同一条。';

COMMENT ON COLUMN public.inbound_source_reasons.requires_explanation IS
'RECV-SOURCE-1 R3:这个理由必须带一句书面说明才算说了话。播种时只有 other 为真 ——
一个没有句子的 other 什么都没说(损耗类别拒绝匿名 other 桶的同一条推理)。
guard_receipt_source_stated 读本列拒绝,所以"第五个理由也要说明"是一行数据。';

INSERT INTO public.inbound_source_reasons (code, name_en, name_zh, requires_explanation, sort_order, notes) VALUES
    ('return',         'Customer return', '客户退货', false, 1, '客户退回的货 —— 出过厂又回来,来路是那一单销售,不是一张采购单。'),
    ('sample',         'Free sample',     '免费样品', false, 2, '供应商送验的样品 —— 没有对价,所以没有采购单。'),
    ('stocktake_gain', 'Stocktake gain',  '盘盈',     false, 3, '盘点发现的多出之数 —— 货在,纸不在。它的"从哪来"只能诚实到这一步。'),
    ('other',          'Other',           '其他',     true,  4, 'R3:必须带书面说明(requires_explanation)。没有句子的 other 什么都没说。');

ALTER TABLE public.inbound_source_reasons ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 material_sources / certificate_types 同一处置。
CREATE POLICY "inbound_source_reasons select all"
    ON public.inbound_source_reasons AS PERMISSIVE FOR SELECT TO authenticated USING (true);
-- 编辑权跟收货走(module.inbound.edit)—— 这本字典管的是收货台上的一个必答项。
CREATE POLICY "inbound_source_reasons insert by permission"
    ON public.inbound_source_reasons AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));
CREATE POLICY "inbound_source_reasons update by permission"
    ON public.inbound_source_reasons AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text))
    WITH CHECK (has_permission('module.inbound.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inbound_source_reasons TO authenticated;

-- ═══ 2 · 四列上表(遮蔽表加列 = 三件事,本节做第一、二件)══════════════════════

ALTER TABLE public.inbound_batches
    ADD COLUMN source_reason_code        text REFERENCES public.inbound_source_reasons (code),
    ADD COLUMN source_reason_note        text,
    ADD COLUMN source_reason_recorded_by uuid REFERENCES auth.users (id),
    ADD COLUMN source_reason_recorded_at timestamptz,
    -- 记录人与记录时刻【同生同灭】—— 与 inbound_import_verified_pair 同形。
    ADD CONSTRAINT inbound_source_recorded_pair
        CHECK ((source_reason_recorded_by IS NULL) = (source_reason_recorded_at IS NULL)),
    -- 没有理由,就不该有说明、也不该有记录人 —— 那三列都是理由的从属。
    ADD CONSTRAINT inbound_source_fields_only_with_reason
        CHECK (source_reason_code IS NOT NULL
               OR (source_reason_note IS NULL
                   AND source_reason_recorded_by IS NULL
                   AND source_reason_recorded_at IS NULL));

COMMENT ON COLUMN public.inbound_batches.source_reason_code IS
'RECV-SOURCE-1 R1:没有采购行时,这张收货【为什么】没有 —— 字典理由(inbound_source_reasons)。
【至少其一,不互斥】有采购行时本列可以同时成立(对着采购单又附送样品是现实)。
【NULL 的含义取决于行的年纪】8 张早于本刀的无单收货本列为 NULL = 【没人说明过】,
按 R4 不回填、屏幕上读作"未说明"(琥珀色),永远不是空白格、不是默认理由。
新行不可能两者皆无 —— guard_receipt_source_stated 按名拒(RECEIPT_SOURCE_REQUIRED)。';

COMMENT ON COLUMN public.inbound_batches.source_reason_note IS
'RECV-SOURCE-1 R3:理由的书面说明。requires_explanation 的理由(播种时只有 other)
缺了它按名拒(SOURCE_REASON_EXPLANATION_REQUIRED)—— 由触发器读字典执行,不是写死的 if。';

COMMENT ON COLUMN public.inbound_batches.source_reason_recorded_at IS
'RECV-SOURCE-1(3e):【事后】补说明的人与时刻 —— 对过去的一个新断言必须带自己的出处。
★收货当场给的理由这两列为 NULL(出处就是 created_by/created_at)★ —— 于是
recorded_at 非空 = 事后补的,NULL = 收货当场说的,R4 要的"看得出区别"在 8 张被
补完之后仍然成立。同生同灭由 inbound_source_recorded_pair 钉住;
收货当场想冒充事后记录,SOURCE_PROVENANCE_NOT_AT_INTAKE 按名拒。';

-- 列级授权(第二件)—— 都不敏感,进列清单;敏感的仍然只有 unit_price。
GRANT SELECT (source_reason_code, source_reason_note,
              source_reason_recorded_by, source_reason_recorded_at)
    ON public.inbound_batches TO authenticated;

-- ═══ 3 · _masked 视图(第三件)—— 新列追加在末尾 ═══════════════════════════════

CREATE OR REPLACE VIEW public.inbound_batches_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    material_id,
    supplier_id,
    quantity,
    unit,
    remaining_qty,
    arrival_date,
    stage,
        CASE
            WHEN has_permission('data.view_prices'::text) THEN unit_price
            ELSE NULL::numeric
        END AS unit_price,
    notes,
    status,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    purchase_order_id,
    purchase_order_line_id,
    pricing_formula_id,
    pricing_status,
    deleted_by,
    delete_reason,
    declared_qty,
    chemistry_certainty_code,
    imported,
    import_permit_ref,
    import_permit_verified_by,
    import_permit_verified_at,
    deep_discharge_actual_code,
    -- RECV-SOURCE-1:四列不遮蔽,原样透出 —— 它们是审计轨迹的第一环,不是钱。
    source_reason_code,
    source_reason_note,
    source_reason_recorded_by,
    source_reason_recorded_at
   FROM inbound_batches
  WHERE has_permission('module.inbound.view'::text);

-- ═══ 4 · 来源守卫(R1/R3/R5 的执行者)════════════════════════════════════════

-- 【只拒 INSERT + 拒转移,绝不是 NOT VALID】理由在文件抬头,一字不少 ——
-- 下一个想在这里写 NOT VALID 的人,先去看 materials 那 7 行冻着的账。
CREATE OR REPLACE FUNCTION public.guard_receipt_source_stated()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_requires boolean;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- R1:新收货必须说得出从哪来 —— 采购行,或理由,永远不许两者皆无。
        IF NEW.purchase_order_line_id IS NULL AND NEW.source_reason_code IS NULL THEN
            RAISE EXCEPTION 'RECEIPT_SOURCE_REQUIRED'
              USING HINT = '收货要么对着一张采购行,要么给一个理由(退货/样品/盘盈/其他)。'
                        || '两者皆无的收货,审计轨迹第一环就是断的。';
        END IF;
        -- 出处列只属于【事后】补的说明;收货当场的出处是 created_by/created_at。
        -- 放行这一格,"事后补的"与"当场说的"就再也分不开了(R4 的看得出区别)。
        IF NEW.source_reason_recorded_by IS NOT NULL OR NEW.source_reason_recorded_at IS NOT NULL THEN
            RAISE EXCEPTION 'SOURCE_PROVENANCE_NOT_AT_INTAKE'
              USING HINT = '收货当场给的理由不填 recorded_by/recorded_at —— '
                        || '那两列的意思是【事后】补记,当场的出处就是 created_by。';
        END IF;
    ELSE  -- UPDATE
        -- 转移守卫:说明过的不许改回没说明(与 guard_arrival_date_not_cleared 同形)。
        -- 8 张历史行两者皆无 → OLD 侧不成立 → 它们的每一次 UPDATE 照过 ——
        -- 加工、化验、改价、注销,一样都不冻(这正是不用 NOT VALID 买到的东西)。
        IF NEW.purchase_order_line_id IS NULL AND NEW.source_reason_code IS NULL
           AND (OLD.purchase_order_line_id IS NOT NULL OR OLD.source_reason_code IS NOT NULL) THEN
            RAISE EXCEPTION 'RECEIPT_SOURCE_REQUIRED|%', OLD.code
              USING HINT = '这张收货已经说明过来路,不能改回两者皆无 —— '
                        || '历史上缺失的那些留着,新的缺失不许再产生。';
        END IF;
        -- 3e:事后给一个(新的)理由,是对过去的一个新断言 —— 必须带谁、什么时候。
        -- 正门是 explain_inbound_source(它盖章);直连 UPDATE 不盖章就按名拒。
        IF NEW.source_reason_code IS DISTINCT FROM OLD.source_reason_code
           AND NEW.source_reason_code IS NOT NULL
           AND NEW.source_reason_recorded_at IS NULL THEN
            RAISE EXCEPTION 'SOURCE_PROVENANCE_REQUIRED|%', NEW.code
              USING HINT = '事后补的理由必须记下谁、什么时候 —— 走 explain_inbound_source,'
                        || '不要直接 UPDATE 本表。';
        END IF;
    END IF;

    -- R3(INSERT 与 UPDATE 都查):要说明的理由,没有句子不算说了话。
    -- 查的是字典的 requires_explanation,不是写死的 'other' —— 第五个也要说明的
    -- 理由是一行数据(R2 与 R3 就此不打架)。字典里查无此码时这里放过,
    -- 让外键用它自己的方式说"没有这个理由"。
    IF NEW.source_reason_code IS NOT NULL THEN
        SELECT requires_explanation INTO v_requires
          FROM inbound_source_reasons WHERE code = NEW.source_reason_code;
        IF FOUND AND v_requires AND COALESCE(btrim(NEW.source_reason_note), '') = '' THEN
            RAISE EXCEPTION 'SOURCE_REASON_EXPLANATION_REQUIRED|%', NEW.source_reason_code
              USING HINT = '这个理由要求一句书面说明(requires_explanation)——'
                        || '没有句子的 other 什么都没说(R3)。';
        END IF;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_inbound_batches_source_stated
    BEFORE INSERT OR UPDATE ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_receipt_source_stated();

-- ═══ 5 · 单头无行的闸(A3;自己的具名拒绝,不混进来源规则)═══════════════════

CREATE OR REPLACE FUNCTION public.guard_inbound_po_line_match()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_line_po uuid;
    v_asset   uuid;
BEGIN
    -- RECV-SOURCE-1(A3):只挂单头不挂明细行,说不出这批货对着【哪一行】——
    -- 对"从哪来"这个问题它不是一个答案。线上实测 0 行:今天免费,以后不可能。
    IF NEW.purchase_order_id IS NOT NULL AND NEW.purchase_order_line_id IS NULL THEN
        RAISE EXCEPTION 'PO_HEADER_WITHOUT_LINE|%', NEW.code
          USING HINT = '挂采购单必须挂到明细行 —— 单头说不出这批货对着哪一行订的什么。';
    END IF;
    IF NEW.purchase_order_line_id IS NULL THEN
        RETURN NEW;
    END IF;
    SELECT purchase_order_id, asset_id INTO v_line_po, v_asset
    FROM purchase_order_lines WHERE id = NEW.purchase_order_line_id;
    -- 给了明细行却没给 PO,或明细行不属于所给的 PO —— 两种都是挂错单
    IF v_line_po IS NULL OR NEW.purchase_order_id IS DISTINCT FROM v_line_po THEN
        RAISE EXCEPTION 'PO_LINE_MISMATCH|%', NEW.code;
    END IF;
    -- EQP-1a:设备行不可收货
    IF v_asset IS NOT NULL THEN
        RAISE EXCEPTION 'PO_LINE_EQUIPMENT_NOT_RECEIVABLE|%', NEW.code
          USING HINT = '这一行订的是一台机器 —— 机器到货不是一次入库(不产生批次、没有化验、不进库位)。它"到货"记在资产卡的投用日上。';
    END IF;
    RETURN NEW;
END;
$function$;

-- ═══ 6 · 两条建批路各接两个尾部参数(照抄 PROC-2c:DROP + CREATE,签名变了)═════

DROP FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text);

CREATE OR REPLACE FUNCTION public.create_inbound_batch(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_unit text DEFAULT 'kg'::text, p_arrival_date date DEFAULT NULL::date, p_stage text DEFAULT '待加工'::text, p_unit_price numeric DEFAULT NULL::numeric, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text)
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
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, unit, remaining_qty, arrival_date,
        stage, unit_price, notes, purchase_order_id, purchase_order_line_id,
        declared_qty, chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, COALESCE(p_unit,'kg'), p_quantity, p_arrival_date,
        COALESCE(p_stage,'待加工'), p_unit_price, p_notes, p_purchase_order_id, p_purchase_order_line_id,
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
    -- IOD-2:返回值从 uuid 变成 jsonb —— 告警要有地方回去。batch_id 仍在里面。
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_inbound_batch(uuid, uuid, numeric, text, date, text, numeric, text, uuid, uuid, uuid, numeric, text[], text, text, text) TO authenticated, service_role;

DROP FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text);

CREATE OR REPLACE FUNCTION public.receive_inbound_batch_against_po(p_material_id uuid, p_supplier_id uuid, p_quantity numeric, p_arrival_date date DEFAULT NULL::date, p_notes text DEFAULT NULL::text, p_purchase_order_id uuid DEFAULT NULL::uuid, p_purchase_order_line_id uuid DEFAULT NULL::uuid, p_location_id uuid DEFAULT NULL::uuid, p_declared_qty numeric DEFAULT NULL::numeric, p_safety_states text[] DEFAULT NULL::text[], p_chemistry_certainty text DEFAULT NULL::text, p_source_reason_code text DEFAULT NULL::text, p_source_reason_note text DEFAULT NULL::text)
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

    -- IOD-2-fu1:同上 —— 现场收货这条路一样进得到 FIN-32 的约束。
    IF p_arrival_date IS NULL THEN
        RAISE EXCEPTION 'ARRIVAL_DATE_REQUIRED';
    END IF;

    PERFORM set_config('evoltrya.location_ctx',
                       COALESCE(resolve_receipt_location(p_location_id)::text, ''), true);

    -- IOD-2:落闸,写入之前。
    v_warn := check_location_class(p_location_id, p_material_id);
    -- NTF-1:告警留一份下来 —— 此前它渲染一次就没了,连响过的痕迹都没有。
    PERFORM notify_landing_warnings(v_warn, p_location_id, p_material_id);

    -- 单位固定 kg、stage 用默认值 —— 与收货表单今天的行为逐字一致。
    -- 【采购单侧的那一串拒绝(PO_NOT_RECEIVABLE / PO_LINE_MISMATCH /
    --  PO_NOT_APPROVED / SUPPLIER_QUALIFICATION_EXPIRED)仍由表上的触发器抛出】,
    -- 这个函数一个字都不重复它们 —— 重复一遍就是第二份会漂开的判断。
    -- RECV-SOURCE-1 的两条拒绝(RECEIPT_SOURCE_REQUIRED / PO_HEADER_WITHOUT_LINE)
    -- 同一条:触发器抛,这里不抄。
    -- 【GRN-1a:收错料【不拒绝】】—— 换料是一个正当的、可以谈成的场景,
    -- 而拒绝会把它变成一次不可能完成的收货。它由 grn_discrepancies 点名
    -- (material_mismatch),由人去判断。
    INSERT INTO inbound_batches (
        material_id, supplier_id, quantity, remaining_qty, unit, arrival_date,
        notes, purchase_order_id, purchase_order_line_id, declared_qty,
        chemistry_certainty_code, source_reason_code, source_reason_note,
        created_by, updated_by)
    VALUES (
        p_material_id, p_supplier_id, p_quantity, p_quantity, 'kg', p_arrival_date,
        p_notes, p_purchase_order_id, p_purchase_order_line_id, p_declared_qty,
        p_chemistry_certainty, p_source_reason_code,
        NULLIF(btrim(COALESCE(p_source_reason_note, '')), ''),
        v_user, v_user)
    RETURNING id INTO v_id;

    -- PROC-2c:见 create_inbound_batch 里同一段注释 —— NULL 与 '{}' 是两件事。
    IF p_safety_states IS NOT NULL THEN
        PERFORM set_inbound_safety_states(v_id, p_safety_states);
    END IF;

    PERFORM set_config('evoltrya.location_ctx', '', true);
    RETURN jsonb_build_object('batch_id', v_id, 'warnings', to_jsonb(v_warn));
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.receive_inbound_batch_against_po(uuid, uuid, numeric, date, text, uuid, uuid, uuid, numeric, text[], text, text, text) TO authenticated, service_role;

-- ═══ 7 · 事后补说明的门(3e)═══════════════════════════════════════════════════

-- 【为什么是一扇门,不是"表单直接 UPDATE"】事后补的理由是对过去的一个新断言,
-- 必须带自己的出处(谁、什么时候)—— 本函数盖章;直连 UPDATE 不盖章会被
-- guard_receipt_source_stated 按名拒(SOURCE_PROVENANCE_REQUIRED)。
-- 【RETURNS void,所以必须 RAISE】—— 一个只返回 NULL 的断言等于没断言。
CREATE OR REPLACE FUNCTION public.explain_inbound_source(p_batch_id uuid, p_reason_code text, p_note text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    PERFORM require_permission('module.inbound.edit');
    IF p_reason_code IS NULL OR btrim(p_reason_code) = '' THEN
        -- 这扇门只做一件事:给理由。不给理由就没有可盖章的东西。
        RAISE EXCEPTION 'RECEIPT_SOURCE_REQUIRED';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM inbound_batches WHERE id = p_batch_id AND deleted_at IS NULL) THEN
        RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', p_batch_id;
    END IF;
    -- 说明本身与它的出处【一笔写完】。R3 的句子检查、外键的查无此码,
    -- 都由表上的守卫与约束抛 —— 这里一个字不重复。
    -- 【auth.uid() 为空时 recorded_pair 会拒】—— 没有人,就没有"谁补的",
    -- 这扇门便不该开(出处不能是 NULL 冒充的)。
    UPDATE inbound_batches SET
        source_reason_code        = p_reason_code,
        source_reason_note        = NULLIF(btrim(COALESCE(p_note, '')), ''),
        source_reason_recorded_by = auth.uid(),
        source_reason_recorded_at = now(),
        updated_by                = auth.uid()
    WHERE id = p_batch_id;
END;
$function$;

REVOKE EXECUTE ON FUNCTION public.explain_inbound_source(uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.explain_inbound_source(uuid, text, text) TO authenticated, service_role;

COMMIT;
