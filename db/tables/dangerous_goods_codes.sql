-- db/tables/dangerous_goods_codes.sql
-- MES-3b(2026-10-07,MES-0 Q38 · V30;MES-3b Step 0 Q11 · Q12,Tim):【危险品 UN 编号】字典 —— 一种物料选一个,批次跟着物料走。
--   引导播四行,第 9 类:UN3480 · UN3481 · UN3090 · UN3091,名称是联合国《关于危险货物运输的建议书》里的【正式运输名称】
--   (照抄,不是编的)。这张表是一份【可编辑的清单】(Q38):加一个编号是加一行。
--   【marking_text · packing_instruction · label_size 三列从空开始,而这是一个决定】包装上的标记、包装说明与标签尺寸
--   是有 DG 资质的货代按运输方式给的(V30,第一次出口之前),不是这里能编的。为空 = "Not yet set",/settings/pending-values 上一行。
--   【它不能从物料上推出来】(MES-3b Step 0 §1.5):电池化学字典里没有锂金属那一行,也没有"装在设备里"这件事 ——
--   所以是每一种物料由人选(materials.dg_code,V35)。
--   【不打印受监管的包装标记】(Q14):第 9 类的菱形标签、锂电池标记的尺寸与样式归货代(V30);系统只印数据。
--   RUNTIME CONFIG:加一个编号或填一条标记文字是加 / 改一行(/settings/dictionaries,module.materials.edit),记进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.dangerous_goods_codes (
    code                text PRIMARY KEY CHECK (code ~ '^UN[0-9]{4}$'),
    name_en             text NOT NULL,
    name_zh             text NOT NULL,
    is_active           boolean NOT NULL DEFAULT true,
    sort_order          integer NOT NULL DEFAULT 0,
    notes               text,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    updated_by          uuid DEFAULT auth.uid(),
    dg_class            text NOT NULL CHECK (btrim(dg_class) <> ''),
    marking_text        text,
    packing_instruction text,
    label_size          text
);

COMMENT ON TABLE public.dangerous_goods_codes IS
    'MES-3b:危险品 UN 编号字典(RUNTIME CONFIG;引导四行 UN3480 · UN3481 · UN3090 · UN3091,第 9 类,联合国正式运输名称)。物料选一个(materials.dg_code),批次跟着物料。marking_text / packing_instruction / label_size 为空 = Not yet set(V30,货代给)。系统只印数据,不印受监管的包装标记。';

INSERT INTO public.dangerous_goods_codes (code, name_en, name_zh, dg_class, sort_order) VALUES
    ('UN3480', 'LITHIUM ION BATTERIES (including lithium ion polymer batteries)', '锂离子电池(包括锂离子聚合物电池)', '9', 10),
    ('UN3481', 'LITHIUM ION BATTERIES CONTAINED IN EQUIPMENT or LITHIUM ION BATTERIES PACKED WITH EQUIPMENT (including lithium ion polymer batteries)',
               '装在设备中的锂离子电池或同设备包装在一起的锂离子电池(包括锂离子聚合物电池)', '9', 20),
    ('UN3090', 'LITHIUM METAL BATTERIES (including lithium alloy batteries)', '锂金属电池(包括锂合金电池)', '9', 30),
    ('UN3091', 'LITHIUM METAL BATTERIES CONTAINED IN EQUIPMENT or LITHIUM METAL BATTERIES PACKED WITH EQUIPMENT (including lithium alloy batteries)',
               '装在设备中的锂金属电池或同设备包装在一起的锂金属电池(包括锂合金电池)', '9', 40);

CREATE TRIGGER trg_dangerous_goods_codes_updated_at
    BEFORE UPDATE ON public.dangerous_goods_codes
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.dangerous_goods_codes ENABLE ROW LEVEL SECURITY;
-- 读:要用到它的模块(物料主数据、库存、进料 / 产出、物流、销售)—— 不是 USING (true):那 44 条开着的读策略不再加一条(MES-0 Q86)。
CREATE POLICY "dangerous_goods_codes select by permission"
    ON public.dangerous_goods_codes AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.materials.view') OR has_permission('module.inventory.view')
           OR has_permission('module.inbound.view') OR has_permission('module.output.view')
           OR has_permission('module.logistics.view') OR has_permission('module.sales.view'));
CREATE POLICY "dangerous_goods_codes write by permission"
    ON public.dangerous_goods_codes AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.materials.edit'))
    WITH CHECK (has_permission('module.materials.edit'));

REVOKE ALL ON public.dangerous_goods_codes FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"(与 nea_waste_categories 同一条)。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.dangerous_goods_codes
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.materials.edit');
