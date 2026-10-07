-- db/migrations/2026-10-07-mes3b-labels-scanning.sql
-- MES-3b —— 标签与扫码(MES 组的第四刀,v1.4.40;发布那一行在 docs/handbacks/MES-3b.md 的抬头)。
-- 由 db/scripts/build_mes3b_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-07:MES-3b Step 0 的 Q0–Q31 全部照建议裁定;docs/surveys/MES-3b/STEP0-HANDBACK.md §11)
--   ① 标签(功能 7):四张新表里的三张 —— label_templates(固定形状的模板字典,引导六行:三种东西 × A6 / A5)·
--      label_prints(每一次印标签,只追加;第一次之后都是补印,要理由)· dangerous_goods_codes(UN3480 · UN3481 · UN3090 · UN3091,
--      第 9 类;标记文字等三列从空开始 —— V30)。materials 加 dg_code(V35)与 hs_code(V31,形状检查)。
--      label_object_data / label_print_context / label_print_preview / record_label_print:标签印什么、谁能印、模板、补印 ——
--      物料名与供应商名以属主身份读(Q2 的并入:仓库印出来的标签不再缺物料名)。
--   ② 扫码(功能 8):scan_events(只追加,不进变更记录)与 resolve_scan_code(四种写法、四种结果,只返回、不抛;看不见的人拿不到 id)。
--      ship_order 认一个可选的核对扫码(SHIP_SCAN_MISMATCH)。
--   ③ 发货的数据:shipment_document 每一行多带危险品、HS 与开着的要隔离的状态;shipping_queue_rows 末尾三列(返回类型变了 → DROP + CREATE)。
--      要隔离的状态只【标出来】,不拒(Q16);危险品编号没选只提示,不拒(Q15)。
--   ④ 视图:pending_values 多三个值(V30 · V31 · V35)。
--   ⑤ 并入:nea_waste_categories 的变更记录绑定从 'id' 改成它真正的主键 'code'(MES-3a 绑错了一列 —— 那张表没有 id,
--      每一次改动都会记下一个空的键;线上 0 行,所以没有一行要补)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;不加任何权限码、不改任何授权;不写、不改任何一张既有单据;
--   不给任何物料选危险品编号或 HS 编码,不填任何标记文字;不碰任何类别、上限、滞留天数、隔离库位;require_calibrated_since 保持空。
--   只播两本字典的引导行(四个 UN 编号、六张模板)与两行例外表登记。
--
-- 【破窗】见 docs/surveys/MES-3b/STEP0-HANDBACK.md §9:只加东西。旧的标签路由照样印(只是那段时间不留印的记录);
--   旧的发货页不带 scanned_code(可选);旧页面按列名读 shipping_queue_rows,末尾三列不碍事;shipment_document 多出来的键旧页面不读。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权一行没动;在途单据一张不少、一张不多;七个账号一个都没被停;
--   变更记录只在两本新字典(引导)与例外表(两行)上动了;两张日志表是空的;没有一种物料有危险品编号或 HS 编码;MES-3a 的东西一样都没设;
--   开关是空的;anon 能执行的【恰好】两支;内层谁都调不到;那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 7 → 8);
--   每一张被记录的表的绑定键都是它的主键;提醒臂 55 支;每一张在途单据仍有一个不是它当事人的决定人。断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES3B_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.dangerous_goods_codes') IS NOT NULL OR to_regclass('public.label_templates') IS NOT NULL
       OR to_regclass('public.label_prints') IS NOT NULL OR to_regclass('public.scan_events') IS NOT NULL THEN
        RAISE EXCEPTION 'MES3B_PRE|MES-3b tables already exist';
    END IF;
    IF EXISTS (SELECT 1 FROM information_schema.columns WHERE table_schema = 'public' AND table_name = 'materials'
                 AND column_name IN ('dg_code', 'hs_code')) THEN
        RAISE EXCEPTION 'MES3B_PRE|MES-3b columns already exist';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES3B_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES3B_PRE|expected 105 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 55 THEN
        RAISE EXCEPTION 'MES3B_PRE|operations_now should have 55 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 10 THEN
        RAISE EXCEPTION 'MES3B_PRE|pending_values should have 10 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES3B_PRE|require_calibrated_since must be empty';
    END IF;
    IF EXISTS (SELECT 1 FROM nea_waste_categories) THEN
        RAISE EXCEPTION 'MES3B_PRE|nea_waste_categories is expected empty (its change-log binding is re-keyed with no rows to repair)';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes3b_pending_before ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';
CREATE TEMP TABLE mes3b_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes3b_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes3b_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;

-- ── 1 · 触发器函数(镜像原样)—— 表上的触发器要先有它 ──────────────────────────

-- db/functions/guard_append_only_log.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q8 · Q20):label_prints 与 scan_events 只追加 —— 一行记下来就不改、不删。
--   UPDATE / DELETE / TRUNCATE 一律语句级拒(没有写策略时 authenticated 的 UPDATE / DELETE 在 RLS 那里是零行,行级触发器不会醒 ——
--   与 guard_ceiling_check_append_only 同一个理由)。APPEND_ONLY|<表>|<操作>。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.guard_append_only_log()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    RAISE EXCEPTION 'APPEND_ONLY|%|%', TG_TABLE_NAME, lower(TG_OP);
END;
$function$;

-- ── 2 · 两本字典(镜像原样,带引导)与两张只追加的日志表 ──────────────────────────

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

-- db/tables/label_templates.sql
-- MES-3b(2026-10-07,MES-0 Q40;MES-3b Step 0 Q4 · Q5,Tim):【标签模板】—— 一张字典,在【固定的几种形状】里选:
--   给哪一种东西印(进料批 · 产出批 · 库位)、纸多大(A6 · A5,横放)、印不印危险品那一行。
--   版式本身只有一份(app/components/labels/labelHtml.ts):模板只是挑一种形状,永远不能往标签里塞一段标记(Q5 的 a,不是 c)。
--   默认 = 那一种东西下面启用着、sort_order 最小的那一行。
--   引导播六行:每一种东西一张 A6(= 今天的那张标签)与一张 A5 —— 页面上那个"A6 还是 A5"的选择从第一天就在(Tim 的 v1.4.40 发布行)。
--   热敏打印机(D10)来了之后的尺寸与 DPI 不在这里:那时它们是新的形状,加行之前先加 CHECK 里的值(一支迁移)。
--   RUNTIME CONFIG:改名、停用、换默认是改一行(/settings/dictionaries,module.inventory.edit —— 库存的写码,标签是仓库的事)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.label_templates (
    code        text PRIMARY KEY,
    name_en     text NOT NULL,
    name_zh     text NOT NULL,
    is_active   boolean NOT NULL DEFAULT true,
    sort_order  integer NOT NULL DEFAULT 0,
    notes       text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  uuid DEFAULT auth.uid(),
    object_kind text NOT NULL CHECK (object_kind IN ('inbound_batch', 'output_batch', 'storage_location')),
    page_size   text NOT NULL CHECK (page_size IN ('A6', 'A5')),
    show_dg     boolean NOT NULL DEFAULT true
);

COMMENT ON TABLE public.label_templates IS
    'MES-3b:标签模板(RUNTIME CONFIG)。一行 = 一种固定形状:object_kind(inbound_batch · output_batch · storage_location)× page_size(A6 · A5,横放)× show_dg(印不印危险品那一行)。版式只有一份,模板只挑形状。默认 = 那一种东西启用着、sort_order 最小的一行。';

INSERT INTO public.label_templates (code, name_en, name_zh, object_kind, page_size, show_dg, sort_order) VALUES
    ('inbound_a6',  'Inbound batch · A6',  '进料批 · A6', 'inbound_batch',    'A6', true,  10),
    ('inbound_a5',  'Inbound batch · A5',  '进料批 · A5', 'inbound_batch',    'A5', true,  20),
    ('output_a6',   'Output batch · A6',   '产出批 · A6', 'output_batch',     'A6', true,  30),
    ('output_a5',   'Output batch · A5',   '产出批 · A5', 'output_batch',     'A5', true,  40),
    ('location_a6', 'Location · A6',       '库位 · A6',   'storage_location', 'A6', false, 50),
    ('location_a5', 'Location · A5',       '库位 · A5',   'storage_location', 'A5', false, 60);

CREATE TRIGGER trg_label_templates_updated_at
    BEFORE UPDATE ON public.label_templates
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.label_templates ENABLE ROW LEVEL SECURITY;
-- 读:印得了哪一种标签的人(进料 / 产出 / 库存查看)。写:库存的编辑码。
CREATE POLICY "label_templates select by permission"
    ON public.label_templates AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view') OR has_permission('module.inbound.view')
           OR has_permission('module.output.view'));
CREATE POLICY "label_templates write by permission"
    ON public.label_templates AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.inventory.edit'))
    WITH CHECK (has_permission('module.inventory.edit'));

REVOKE ALL ON public.label_templates FROM anon;

-- SILENT-1:被拒绝的写要抛,不许是一次"成功的空操作"。
CREATE TRIGGER enforce_write_permission
    BEFORE UPDATE OR DELETE ON public.label_templates
    FOR EACH STATEMENT EXECUTE FUNCTION public.enforce_write_permission('module.inventory.edit');

-- db/tables/label_prints.sql
-- MES-3b(2026-10-07,MES-0 Q40 · §4.3;MES-3b Step 0 Q6–Q8,Tim):【每一次印标签】—— 一行一次,只追加。
--   一行记:印的是哪一样东西(进料批 · 产出批 · 库位,三选一)、用的哪个模板与纸、几份、是不是补印(补印要理由)、
--   二维码里装的是什么(短链接的路径,/b/<批号> 或 /loc/<库位号>)、印上去的那几个字段的快照、谁、什么时候。
--   【记的是"发去打印了",不是"纸出来了"】浏览器不告诉页面纸有没有出来;页面先写这一行,再调 window.print()(Q6)。
--   【补印】同一样东西第一次之后的每一次,不论模板 —— 理由必填,在函数里拒(LABEL_REPRINT_REASON_REQUIRED),不只是页面上。
--   【没有 PDF,没有 sha256】什么都不归档:标签是浏览器印的 HTML(Q8)。
--   写它的只有 record_label_print(属主身份,先按那样东西自己的查看码把关)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.label_prints (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    object_kind         text NOT NULL CHECK (object_kind IN ('inbound_batch', 'output_batch', 'storage_location')),
    inbound_batch_id    uuid REFERENCES public.inbound_batches (id),
    output_batch_id     uuid REFERENCES public.output_batches (id),
    storage_location_id uuid REFERENCES public.storage_locations (id),
    template_code       text NOT NULL REFERENCES public.label_templates (code),
    page_size           text NOT NULL CHECK (page_size IN ('A6', 'A5')),
    copies              integer NOT NULL CHECK (copies >= 1),
    is_reprint          boolean NOT NULL,
    reprint_reason      text,
    qr_payload          text NOT NULL,
    printed_fields      jsonb NOT NULL,
    printed_at          timestamptz NOT NULL DEFAULT now(),
    printed_by          uuid NOT NULL DEFAULT auth.uid(),
    -- 【两句,不是一句】第一句写成 num_nonnulls(…) = 1 这个形状是承重的:关联图(db/views/document_relations.sql 第 ② 条筛子)
    --   只认这个形状为"三选一",认出来才不会把这张表当成一座 inbound_batches ↔ output_batches 的假桥(fixture 103 实测抓到)。
    CONSTRAINT label_prints_one_object CHECK (num_nonnulls(inbound_batch_id, output_batch_id, storage_location_id) = 1),
    CONSTRAINT label_prints_kind_matches CHECK (
        (object_kind = 'inbound_batch') = (inbound_batch_id IS NOT NULL)
        AND (object_kind = 'output_batch') = (output_batch_id IS NOT NULL)
        AND (object_kind = 'storage_location') = (storage_location_id IS NOT NULL)),
    CONSTRAINT label_prints_reprint_reason CHECK (
        (NOT is_reprint AND reprint_reason IS NULL)
     OR (is_reprint AND reprint_reason IS NOT NULL AND btrim(reprint_reason) <> ''))
);

COMMENT ON TABLE public.label_prints IS
    'MES-3b:每一次印标签(只追加)。一样东西(进料批 · 产出批 · 库位)× 模板 × 份数;第一次之后都是补印,要理由。qr_payload = 短链接路径;printed_fields = 印上去的字段快照。记的是"发去打印了",浏览器不报纸出没出来。只有 record_label_print 写。';

CREATE INDEX idx_label_prints_inbound  ON public.label_prints (inbound_batch_id, printed_at)    WHERE inbound_batch_id IS NOT NULL;
CREATE INDEX idx_label_prints_output   ON public.label_prints (output_batch_id, printed_at)     WHERE output_batch_id IS NOT NULL;
CREATE INDEX idx_label_prints_location ON public.label_prints (storage_location_id, printed_at) WHERE storage_location_id IS NOT NULL;

-- 【语句级,连 UPDATE 也是】没有写策略时 authenticated 的 UPDATE / DELETE 在 RLS 那里是零行,行级触发器不会醒(SILENT-1 那一族)。
CREATE TRIGGER trg_label_prints_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.label_prints
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.label_prints ENABLE ROW LEVEL SECURITY;

-- 跟着那样东西判:进料批要进料查看码,产出批要产出查看码,库位要库存查看码。没有写策略:只有 record_label_print(属主身份)写。
CREATE POLICY "label_prints select by permission" ON public.label_prints
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (((inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
            OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text))
            OR (storage_location_id IS NOT NULL AND has_permission('module.inventory.view'::text))));

REVOKE ALL ON public.label_prints FROM anon;

-- db/tables/scan_events.sql
-- MES-3b(2026-10-07,MES-0 §3.1 · Q28 · Q29;MES-3b Step 0 Q19 · Q20,Tim):【每一次扫码】—— 一次解析一行,只追加。
--   写它的只有 resolve_scan_code(属主身份):页面上扫到 / 敲进去的那一串、在什么场合(查看 · 收货 · 转移 · 投料 · 预留 · 发货)、
--   用的什么(keyboard = 扫码枪或手敲 —— 对一个页面来说这两样一模一样;camera = 浏览器的 BarcodeDetector;
--   link = 有人打开了标签上的短链接 /b/… /loc/…)、认出来是什么、结果(found · restricted · unknown · unreadable)。
--   【id 只记给看得见它的人】resolved_id 只在 outcome = found 时有;restricted 只记那是哪一种东西、编号是什么(Q19)。
--   【不进变更记录】(Q20,MES-0 Q14 的先例):它自己就是一本只追加的日志,再记一遍只是翻倍。
--   读:库存查看码;页面上只画"你最近的扫码"(/inventory/scan)。
--   id 是 bigserial —— "最近"要排得出先后(AGENTS.md「取最新那一行要先问:这张表排得出先后吗」)。
--   固定式扫码器走 ingest 的 scan 类(MES-1),它的转换器这一刀不建(Q25):那些行照设计停在 awaiting_transform。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.scan_events (
    id             bigserial PRIMARY KEY,
    scanned_at     timestamptz NOT NULL DEFAULT now(),
    scanned_by     uuid NOT NULL DEFAULT auth.uid(),
    context        text NOT NULL CHECK (context IN ('lookup', 'receipt', 'transfer', 'feed', 'reserve', 'ship')),
    method         text NOT NULL CHECK (method IN ('keyboard', 'camera', 'link')),
    raw_value      text NOT NULL,
    parsed_code    text,
    resolved_kind  text CHECK (resolved_kind IN ('inbound_batch', 'output_batch', 'storage_location')),
    resolved_id    uuid,
    outcome        text NOT NULL CHECK (outcome IN ('found', 'restricted', 'unknown', 'unreadable')),
    CONSTRAINT scan_events_id_only_when_found CHECK (resolved_id IS NULL OR outcome = 'found'),
    CONSTRAINT scan_events_kind_when_resolved CHECK (outcome NOT IN ('found', 'restricted') OR resolved_kind IS NOT NULL)
);

COMMENT ON TABLE public.scan_events IS
    'MES-3b:每一次扫码的解析(只追加,不进变更记录)。context · method(keyboard · camera · link)· raw_value · 认出来的种类与编号 · outcome(found · restricted · unknown · unreadable);resolved_id 只在 found 时有。只有 resolve_scan_code 写。';

CREATE INDEX idx_scan_events_by ON public.scan_events (scanned_by, id DESC);

CREATE TRIGGER trg_scan_events_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.scan_events
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.scan_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY "scan_events select by permission" ON public.scan_events
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inventory.view'::text));

REVOKE ALL ON public.scan_events FROM anon;

-- 带 code 列的表要么是单据、要么在例外表里带一句理由(fixture 102 · check-document-registry)。镜像原样。
INSERT INTO public.document_type_exceptions (table_name, reason) VALUES
    ('dangerous_goods_codes',         '危险品 UN 编号目录(MES-3b):code 是 UN 编号,物料引用它'),
    ('label_templates',               '标签模板目录(MES-3b):code 是模板代号,印标签的记录引用它');

-- ── 3 · 物料上的危险品编号与 HS 编码(Q12 · Q17)────────────────────────────────────
ALTER TABLE public.materials ADD COLUMN dg_code text REFERENCES public.dangerous_goods_codes (code);
ALTER TABLE public.materials ADD COLUMN hs_code text CONSTRAINT materials_hs_code_shape
    CHECK (hs_code ~ '^[0-9]+(\.[0-9]+)*$' AND length(replace(hs_code, '.', '')) BETWEEN 6 AND 12);
COMMENT ON COLUMN public.materials.dg_code IS
    'MES-3b(MES-0 Q38 · V35):这个物料的危险品 UN 编号(dangerous_goods_codes),人选的 —— 从化学、形态都推不出来。批次跟着物料走:标签、发货单、发货队列都印它。NULL = 没人选过:电池料上提示"没给",不拒(Q15)。';
COMMENT ON COLUMN public.materials.hs_code IS
    'MES-3b(MES-0 Q39 · V31):HS 编码,可空,报关行在第一次出口之前给。6–12 位数字,可带点(materials_hs_code_shape —— 形状,不是标准)。物料页、清单、导出与发货单上印它;标签上不印(Q17)。';

-- ── 4 · 并入:nea_waste_categories 的变更记录绑定换成它真正的主键 code(MES-3a 绑的是一列不存在的 id)──────────
DROP TRIGGER zzz_change_log ON public.nea_waste_categories;
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.nea_waste_categories
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');

-- ── 5 · 新函数(镜像原样)──────────────────────────────────────────────────────

-- db/functions/label_object_data.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q2 · Q10 · Q13,Tim):【一张标签上印什么】—— 一份,预览与打印问同一支(AGENTS.md「一份实现,两个调用方」)。
--   进料批:批号 · 物料(编号与名称)· 数量与单位 · 供应商的法定名称 · 危险品那一行。
--   产出批:批号 · 物料 · 数量与单位 · 纯度 · 危险品那一行。
--   库位:库位号 · 名称 · 区 · 是不是隔离库位。
--   【物料名与供应商名是这张单据的展示标签】(常设决定 3;MES-3b Q2 并入):此前标签以读者身份内嵌读 materials / suppliers,
--     仓库不持 module.materials.view,于是仓库印出来的标签物料那一格是"—"(MES-3b Step 0 §1.3,实测)。这里以属主身份读,
--     能看这一批的人就看得到它是什么料、谁送来的 —— 【只有名字】,不带价格、不带供应商的任何别的属性。
--   【危险品】物料选了 UN 编号 → 编号、类别、正式运输名称、标记文字(V30,可能为空);电池料(material_kinds.has_condition_axes)
--     没选 → dg_missing = true(Q15:只提示,不拒)。
--   找不到、或批次已删 → NULL(调用方说"找不到")。
--   【内层】不是 SECURITY DEFINER、没有调用者检查,EXECUTE 从 authenticated 收回;调用方 label_print_preview / record_label_print
--   各自先按那样东西的查看码把关,再以属主身份调它。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.label_object_data(p_kind text, p_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    r record;
BEGIN
    IF p_kind = 'inbound_batch' THEN
        SELECT b.id, b.code, b.quantity, b.unit, m.code AS m_code, m.name AS m_name, s.legal_name AS detail,
               m.dg_code, g.dg_class, g.name_en AS dg_name_en, g.name_zh AS dg_name_zh, g.marking_text,
               COALESCE(mk.has_condition_axes, false) AS battery
          INTO r
          FROM inbound_batches b
          LEFT JOIN materials m ON m.id = b.material_id
          LEFT JOIN material_kinds mk ON mk.code = m.kind_code
          LEFT JOIN suppliers s ON s.id = b.supplier_id
          LEFT JOIN dangerous_goods_codes g ON g.code = m.dg_code
         WHERE b.id = p_id AND b.deleted_at IS NULL;
    ELSIF p_kind = 'output_batch' THEN
        SELECT b.id, b.code, b.quantity, b.unit, m.code AS m_code, m.name AS m_name, b.purity::text AS detail,
               m.dg_code, g.dg_class, g.name_en AS dg_name_en, g.name_zh AS dg_name_zh, g.marking_text,
               COALESCE(mk.has_condition_axes, false) AS battery
          INTO r
          FROM output_batches b
          LEFT JOIN materials m ON m.id = b.material_id
          LEFT JOIN material_kinds mk ON mk.code = m.kind_code
          LEFT JOIN dangerous_goods_codes g ON g.code = m.dg_code
         WHERE b.id = p_id AND b.deleted_at IS NULL;
    ELSIF p_kind = 'storage_location' THEN
        SELECT l.id, l.code, l.name, l.zone, l.is_quarantine, l.is_active INTO r
          FROM storage_locations l WHERE l.id = p_id;
        IF NOT FOUND THEN
            RETURN NULL;
        END IF;
        RETURN jsonb_build_object('kind', p_kind, 'id', r.id, 'code', r.code, 'name', r.name, 'zone', r.zone,
                                  'is_quarantine', r.is_quarantine, 'is_active', r.is_active);
    ELSE
        RETURN NULL;
    END IF;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;
    RETURN jsonb_build_object(
        'kind', p_kind, 'id', r.id, 'code', r.code,
        'material_code', r.m_code, 'material_name', r.m_name,
        'quantity', r.quantity, 'unit', r.unit,
        'detail_kind', CASE p_kind WHEN 'inbound_batch' THEN 'supplier' ELSE 'purity' END,
        'detail_value', r.detail,
        'dg', CASE WHEN r.dg_code IS NULL THEN NULL
                   ELSE jsonb_build_object('code', r.dg_code, 'class', r.dg_class, 'name_en', r.dg_name_en,
                                           'name_zh', r.dg_name_zh, 'marking_text', r.marking_text) END,
        'dg_missing', r.battery AND r.dg_code IS NULL);
END;
$function$;

-- db/functions/label_print_context.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q5–Q9,Tim):【印一张标签之前要问的每一件事】—— 预览(label_print_preview)与打印(record_label_print)
--   问同一支,所以页面上看见的那张与记下来的那张不可能是两份算法。
--   ① 哪一种东西:inbound_batch · output_batch · storage_location,别的 → LABEL_KIND_INVALID|<种类>。
--   ② 谁印得了:那样东西自己的查看码(进料 module.inbound.view · 产出 module.output.view · 库位 module.inventory.view)——
--      Q28:能看就能印,没有新码;没有 → PERMISSION_DENIED|<码>(在找之前问:不告诉一个看不见的人那样东西在不在)。
--   ③ 找不到或已删 → LABEL_OBJECT_NOT_FOUND|<种类>。
--   ④ 模板:不给 → 那一种东西下启用着、sort_order 最小的一张(Q5 的默认);一张都没有 → LABEL_TEMPLATE_NONE|<种类>;
--      给了却不存在、停用了或不是这一种东西的 → LABEL_TEMPLATE_INVALID|<模板>。
--   ⑤ 二维码:短链接的【路径】/b/<批号> 或 /loc/<库位号>(Q9;域名由页面补上 —— 数据库不知道自己被哪个域名访问)。
--   ⑥ 之前印过几次、最后一次是谁什么时候、是不是补印 —— 页面据此决定要不要问理由。
--   【内层】不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回;外面两支是 DEFINER,以属主身份调它。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.label_print_context(p_kind text, p_id uuid, p_template text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_code  text;
    v_data  jsonb;
    v_tpl   record;
    v_n     integer;
    v_last  record;
BEGIN
    v_code := CASE p_kind WHEN 'inbound_batch' THEN 'module.inbound.view'
                          WHEN 'output_batch' THEN 'module.output.view'
                          WHEN 'storage_location' THEN 'module.inventory.view' END;
    IF v_code IS NULL THEN
        RAISE EXCEPTION 'LABEL_KIND_INVALID|%', COALESCE(p_kind, '?');
    END IF;
    IF NOT has_permission(v_code) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|%', v_code;
    END IF;

    v_data := label_object_data(p_kind, p_id);
    IF v_data IS NULL THEN
        RAISE EXCEPTION 'LABEL_OBJECT_NOT_FOUND|%', p_kind;
    END IF;

    IF NULLIF(btrim(p_template), '') IS NULL THEN
        SELECT t.code, t.name_en, t.name_zh, t.page_size, t.show_dg INTO v_tpl
          FROM label_templates t
         WHERE t.object_kind = p_kind AND t.is_active
         ORDER BY t.sort_order, t.code
         LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'LABEL_TEMPLATE_NONE|%', p_kind;
        END IF;
    ELSE
        SELECT t.code, t.name_en, t.name_zh, t.page_size, t.show_dg INTO v_tpl
          FROM label_templates t
         WHERE t.code = btrim(p_template) AND t.object_kind = p_kind AND t.is_active;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'LABEL_TEMPLATE_INVALID|%', btrim(p_template);
        END IF;
    END IF;

    SELECT count(*) INTO v_n FROM label_prints lp
     WHERE (p_kind = 'inbound_batch' AND lp.inbound_batch_id = p_id)
        OR (p_kind = 'output_batch' AND lp.output_batch_id = p_id)
        OR (p_kind = 'storage_location' AND lp.storage_location_id = p_id);
    SELECT lp.printed_at, lp.printed_by, lp.is_reprint, lp.reprint_reason INTO v_last
      FROM label_prints lp
     WHERE (p_kind = 'inbound_batch' AND lp.inbound_batch_id = p_id)
        OR (p_kind = 'output_batch' AND lp.output_batch_id = p_id)
        OR (p_kind = 'storage_location' AND lp.storage_location_id = p_id)
     ORDER BY lp.printed_at DESC, lp.id
     LIMIT 1;

    RETURN jsonb_build_object(
        'data', v_data,
        'template', jsonb_build_object('code', v_tpl.code, 'name_en', v_tpl.name_en, 'name_zh', v_tpl.name_zh,
                                       'page_size', v_tpl.page_size, 'show_dg', v_tpl.show_dg),
        'qr_path', CASE WHEN p_kind = 'storage_location' THEN '/loc/' ELSE '/b/' END || (v_data ->> 'code'),
        'prints_so_far', v_n,
        'next_is_reprint', v_n > 0,
        'last_printed_at', v_last.printed_at,
        'last_printed_by', v_last.printed_by);
END;
$function$;

-- db/functions/label_print_preview.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q6,Tim):打印页上的【预览】—— 与 record_label_print 问同一支 label_print_context,只读、什么都不写
--   (一次打开页面不该写:MES-2 §7 决定 10)。拒绝与 label_print_context 一字不差。
--   【调用者检查,两层】外面这一句:三个查看码一个都没有 → 拒(没有人能拿它当一扇随便问的门);
--   里面那一句(label_print_context 第 ②)才是精确的:那样东西【自己的】查看码。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.label_print_preview(p_kind text, p_id uuid, p_template text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NOT (has_permission('module.inbound.view') OR has_permission('module.output.view')
            OR has_permission('module.inventory.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.inventory.view';
    END IF;
    RETURN label_print_context(p_kind, p_id, p_template);
END;
$function$;

-- db/functions/record_label_print.sql
-- MES-3b(2026-10-07,MES-0 Q40;MES-3b Step 0 Q6–Q8,Tim):【印一张标签】—— 打印页按下"打印"时调,【先写这一行,再 window.print()】。
--   判断全在 label_print_context(与预览同一支):种类、查看码、找得到、模板。这里只加三件:
--   ① 份数:不给 = 1;给了要 ≥ 1 → 否则 LABEL_COPIES_INVALID|<份数>(没有上限 —— 那不是这里能定的数)。
--   ② 补印:这样东西以前印过(不论哪个模板)→ 这一次是补印,理由必填 → LABEL_REPRINT_REASON_REQUIRED|<编号>。
--      Q40:能印的人就能补印。第一次给了理由也不记(那不是一次补印,理由列为空 —— 表上的 CHECK 也这么说)。
--      "以前印过"在一把每样东西一把的咨询锁里判:两个人同时按,第二个看得见第一个,于是只有一个"第一次"。
--   ③ 记下:模板与纸、份数、补印与理由、二维码路径、印上去的字段快照(label_object_data 的那一份 + 模板)、谁、何时。
--   返回:这一行的 id、第几次、是不是补印,以及页面画标签要的全部数据(与预览同形)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.record_label_print(p_kind text, p_id uuid, p_template text DEFAULT NULL::text, p_copies integer DEFAULT NULL::integer, p_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_ctx     jsonb;
    v_copies  integer := COALESCE(p_copies, 1);
    v_reprint boolean;
    v_id      uuid;
    v_n       integer;
BEGIN
    IF NOT (has_permission('module.inbound.view') OR has_permission('module.output.view')
            OR has_permission('module.inventory.view')) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|module.inventory.view';
    END IF;
    IF v_copies < 1 THEN
        RAISE EXCEPTION 'LABEL_COPIES_INVALID|%', v_copies;
    END IF;

    -- 先问种类与查看码(不告诉一个看不见的人那样东西在不在),再上锁、再数以前印过几次
    v_ctx := label_print_context(p_kind, p_id, p_template);
    PERFORM pg_advisory_xact_lock(hashtext('label_print_' || p_kind || '_' || p_id::text)::bigint);
    SELECT count(*) INTO v_n FROM label_prints lp
     WHERE (p_kind = 'inbound_batch' AND lp.inbound_batch_id = p_id)
        OR (p_kind = 'output_batch' AND lp.output_batch_id = p_id)
        OR (p_kind = 'storage_location' AND lp.storage_location_id = p_id);
    v_reprint := v_n > 0;
    IF v_reprint AND NULLIF(btrim(p_reason), '') IS NULL THEN
        RAISE EXCEPTION 'LABEL_REPRINT_REASON_REQUIRED|%', v_ctx -> 'data' ->> 'code';
    END IF;

    INSERT INTO label_prints (object_kind, inbound_batch_id, output_batch_id, storage_location_id, template_code, page_size,
                              copies, is_reprint, reprint_reason, qr_payload, printed_fields, printed_by)
    VALUES (p_kind,
            CASE WHEN p_kind = 'inbound_batch' THEN p_id END,
            CASE WHEN p_kind = 'output_batch' THEN p_id END,
            CASE WHEN p_kind = 'storage_location' THEN p_id END,
            v_ctx -> 'template' ->> 'code', v_ctx -> 'template' ->> 'page_size',
            v_copies, v_reprint, CASE WHEN v_reprint THEN btrim(p_reason) END,
            v_ctx ->> 'qr_path',
            (v_ctx -> 'data') || jsonb_build_object('template', v_ctx -> 'template'),
            auth.uid())
    RETURNING id INTO v_id;

    RETURN v_ctx || jsonb_build_object('print_id', v_id, 'print_no', v_n + 1, 'is_reprint', v_reprint, 'copies', v_copies,
                                       'prints_so_far', v_n + 1, 'next_is_reprint', true,
                                       'last_printed_at', now(), 'last_printed_by', auth.uid());
END;
$function$;

-- db/functions/resolve_scan_code.sql
-- MES-3b(2026-10-07,MES-0 Q28 · Q29;MES-3b Step 0 Q9 · Q18–Q20,Tim):【扫到的这一串是什么】—— 每一个扫码框、每一条短链接都问它,
--   页面自己从不判断身份。
--   认得四种写法(Q18):
--     · 光秃秃的编号(两头的空白、制表符、回车换行先去掉 —— 扫码枪打完一串会补一个回车):IN-2026-0012 · OUT-2026-0381 · 一个库位号(先认批次,再认库位;批号不分大小写,库位号先精确、再不分大小写且唯一);
--     · 短链接:…/b/<批号>(只认批次)· …/loc/<库位号>(只认库位)—— 有没有域名都行,%xx 会被解开;
--     · 旧标签上的地址:…/inbound/<uuid>/edit · …/output/<uuid>/edit(Q9:已经印出去的标签照样能用)。
--   四种结果(Q19),【只返回、从不抛】—— 扫码日志那一行因此一定留得下(ingest_submit / cod_verification 同一个理由):
--     found       认出来了,而且你看得见 → 种类、编号、id(库位另带在不在用、是不是隔离库位);
--     restricted  认出来了,你看不见 → 种类、编号、要哪个码 ——【不给 id】(Q19);
--     unknown     没有这个编号(批次已删也算);
--     unreadable  一个字都没有、或者解析不了。
--   没登录(auth.uid() 为空)→ signed_out,不记日志(scanned_by 必填;没登录的人走不到这里 —— 中间件先把他送去登录)。
--   每一次(除 signed_out)写一行 scan_events:场合、方式、原文(截到 500 字)、解析出的编号、结果;id 只在 found 时记。
--   【门】谁都能问(结果本身按码分);看得见什么由那样东西自己的查看码定:进料 module.inbound.view · 产出 module.output.view ·
--   库位 module.inventory.view(与 label_print_context 同一张表)。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.resolve_scan_code(p_value text, p_context text DEFAULT 'lookup'::text, p_method text DEFAULT 'keyboard'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_raw     text := left(COALESCE(p_value, ''), 500);
    v_ctx     text := CASE WHEN p_context IN ('lookup', 'receipt', 'transfer', 'feed', 'reserve', 'ship') THEN p_context ELSE 'lookup' END;
    v_method  text := CASE WHEN p_method IN ('keyboard', 'camera', 'link') THEN p_method ELSE 'keyboard' END;
    v         text := btrim(COALESCE(p_value, ''), E' \t\r\n');
    m         text[];
    v_hint    text;           -- 'b' · 'loc' · 'id_in' · 'id_out' · NULL(光秃秃的编号)
    v_code    text;
    v_kind    text;
    v_id      uuid;
    v_found   text;           -- 认出来的编号(库里的写法)
    v_need    text;
    v_outcome text;
    v_extra   jsonb := '{}'::jsonb;
    v_scan    bigint;
    r         record;
BEGIN
    IF auth.uid() IS NULL THEN
        RETURN jsonb_build_object('outcome', 'signed_out');
    END IF;

    BEGIN
        -- ── 解析 ──
        m := regexp_match(v, '/(b|loc)/([^/?#[:space:]]+)/?([?#].*)?$');
        IF m IS NOT NULL THEN
            v_hint := m[1];
            SELECT convert_from(string_agg(CASE WHEN t.tok ~ '^%[0-9A-Fa-f]{2}$' THEN decode(substr(t.tok, 2), 'hex')
                                                ELSE convert_to(t.tok, 'UTF8') END, ''::bytea ORDER BY t.ord), 'UTF8')
              INTO v_code
              FROM regexp_matches(m[2], '%[0-9A-Fa-f]{2}|[^%]+|%', 'g') WITH ORDINALITY AS t0(mm, ord)
              CROSS JOIN LATERAL (SELECT t0.mm[1] AS tok, t0.ord) t;
        ELSE
            m := regexp_match(v, '/(inbound|output)/([0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})(/[a-z]*)?/?([?#].*)?$');
            IF m IS NOT NULL THEN
                v_hint := CASE m[1] WHEN 'inbound' THEN 'id_in' ELSE 'id_out' END;
                v_id := lower(m[2])::uuid;
            ELSE
                v_code := v;
            END IF;
        END IF;
        v_code := NULLIF(btrim(v_code, E' \t\r\n'), '');

        IF v_code IS NULL AND v_id IS NULL THEN
            v_outcome := 'unreadable';
        ELSE
            -- ── 认 ──
            IF v_hint = 'id_in' THEN
                SELECT b.code INTO v_found FROM inbound_batches b WHERE b.id = v_id AND b.deleted_at IS NULL;
                IF FOUND THEN v_kind := 'inbound_batch'; ELSE v_id := NULL; END IF;
            ELSIF v_hint = 'id_out' THEN
                SELECT b.code INTO v_found FROM output_batches b WHERE b.id = v_id AND b.deleted_at IS NULL;
                IF FOUND THEN v_kind := 'output_batch'; ELSE v_id := NULL; END IF;
            END IF;
            IF v_kind IS NULL AND v_code IS NOT NULL AND v_hint IS DISTINCT FROM 'loc' THEN
                SELECT b.id, b.code INTO v_id, v_found FROM inbound_batches b
                 WHERE upper(b.code) = upper(v_code) AND b.deleted_at IS NULL LIMIT 1;
                IF FOUND THEN
                    v_kind := 'inbound_batch';
                ELSE
                    SELECT b.id, b.code INTO v_id, v_found FROM output_batches b
                     WHERE upper(b.code) = upper(v_code) AND b.deleted_at IS NULL LIMIT 1;
                    IF FOUND THEN v_kind := 'output_batch'; END IF;
                END IF;
            END IF;
            IF v_kind IS NULL AND v_code IS NOT NULL AND v_hint IS DISTINCT FROM 'b' THEN
                SELECT l.id, l.code, l.is_active, l.is_quarantine INTO r FROM storage_locations l WHERE l.code = v_code;
                IF NOT FOUND THEN
                    SELECT l.id, l.code, l.is_active, l.is_quarantine INTO r FROM storage_locations l
                     WHERE lower(l.code) = lower(v_code)
                       AND (SELECT count(*) FROM storage_locations l2 WHERE lower(l2.code) = lower(v_code)) = 1;
                END IF;
                IF FOUND THEN
                    v_kind := 'storage_location'; v_found := r.code; v_id := r.id;
                    v_extra := jsonb_build_object('is_active', r.is_active, 'is_quarantine', r.is_quarantine);
                END IF;
            END IF;

            IF v_kind IS NULL THEN
                v_outcome := 'unknown';
                v_extra := '{}'::jsonb;
            ELSE
                v_need := CASE v_kind WHEN 'inbound_batch' THEN 'module.inbound.view'
                                      WHEN 'output_batch' THEN 'module.output.view'
                                      ELSE 'module.inventory.view' END;
                IF has_permission(v_need) THEN
                    v_outcome := 'found';
                ELSE
                    v_outcome := 'restricted';
                    v_id := NULL;
                    v_extra := '{}'::jsonb;
                END IF;
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        v_outcome := 'unreadable'; v_kind := NULL; v_id := NULL; v_found := NULL; v_need := NULL; v_extra := '{}'::jsonb;
    END;

    INSERT INTO scan_events (scanned_by, context, method, raw_value, parsed_code, resolved_kind, resolved_id, outcome)
    VALUES (auth.uid(), v_ctx, v_method, v_raw, COALESCE(v_found, v_code), v_kind,
            CASE WHEN v_outcome = 'found' THEN v_id END, v_outcome)
    RETURNING id INTO v_scan;

    RETURN jsonb_build_object(
        'outcome', v_outcome,
        'kind', v_kind,
        'code', COALESCE(v_found, v_code),
        'id', CASE WHEN v_outcome = 'found' THEN v_id END,
        'needs', CASE WHEN v_outcome = 'restricted' THEN v_need END,
        'scan_id', v_scan) || v_extra;
END;
$function$;

-- db/functions/batch_quarantine_states.sql
-- MES-3b(2026-10-07,MES-3b Step 0 Q16,Tim):【这一批身上开着的、要隔离的安全状态】—— 发货队列与发货单拿它【标出来,不拒】。
--   预留与发货此前一个安全状态都不看(MES-3b Step 0 §1.11);Tim 裁:标,不拒 —— 受损电池怎么运归货代(V30),
--   一道拒绝还会挡住把它们送去有执照的回收商。
--   读 output_batch_safety_states(开着的,ended_at 为空)× inbound_safety_states.requires_quarantine = true(V4 为空 = 不要求,
--   与 MES-3a 的隔离闸同一句)。返回以逗号连起来的状态码,按码排序;一个都没有 → NULL。
--   【内层】不是 SECURITY DEFINER,EXECUTE 从 authenticated 收回;shipment_document 与 shipping_queue_rows(各自查过码的 DEFINER)调它。
--
-- NOTE: introduced by db/migrations/2026-10-07-mes3b-labels-scanning.sql.

CREATE OR REPLACE FUNCTION public.batch_quarantine_states(p_output_batch_id uuid)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT string_agg(s.safety_state_code, ',' ORDER BY s.safety_state_code)
      FROM output_batch_safety_states s
      JOIN inbound_safety_states st ON st.code = s.safety_state_code
     WHERE s.output_batch_id = p_output_batch_id AND s.ended_at IS NULL AND st.requires_quarantine IS TRUE;
$function$;

-- ── 6 · 改过的函数(镜像原样,同签名)──────────────────────────────────────────

-- db/functions/shipment_document.sql
-- APR-5b(2026-09-25,5b grilling Q7):一张发货单要印的东西 —— 表头(发货单号、日期、订单编号、客户编号与
-- 法定名称)与行(数量、批次、单位、物料、废物分类、发货时的库位)。发货单页与发货单 PDF 都读它。
--
-- 【为什么是一支属主权限的读者】发货单此前经内嵌读 sales_orders 与 customers(RLS:module.sales.view /
-- module.customers.view)与 materials(module.materials.view);仓库三个都不持(Q7:不给仓库 sales.view),
-- 于是它发得了货、印不出它刚发的那张单。这里读全量,先按调用者的码把关。
-- 【没有价格】发货单本来就不带价(发货单行没有价格列);客户只给编号与法定名称(常设决定 3 的展示标签)。
-- 【门】module.sales.view 或 action.ship_goods —— 与三张发货表的读策略同一对码。
-- ★ MES-3b(2026-10-07,MES-3b Step 0 Q13 · Q15 · Q16 · Q17,Tim):每一行再带物料的危险品数据与 HS 编码,以及那一批身上开着的要隔离的状态 ——
--   dg_code · dg_class · dg_name_en · dg_name_zh(物料选的 UN 编号与联合国正式运输名称)· dg_missing(电池料没选编号 → 只提示,Q15)·
--   hs_code(V31,可空)· quarantine_states(batch_quarantine_states:标出来,不拒 —— Q16)。签名与返回类型一字未动(jsonb 多了键)。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.shipment_document(p_shipment_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_s record;
BEGIN
    IF NOT has_any_permission(ARRAY['module.sales.view', 'action.ship_goods']) THEN
        RAISE EXCEPTION 'PERMISSION_DENIED|action.ship_goods';
    END IF;

    SELECT s.id, s.code, s.ship_date, s.created_at, so.id AS order_id, so.code AS order_code,
           c.code AS customer_code, c.legal_name AS customer_name
      INTO v_s
      FROM shipments s
      JOIN sales_orders so ON so.id = s.sales_order_id
      LEFT JOIN customers c ON c.id = so.customer_id
     WHERE s.id = p_shipment_id;
    IF NOT FOUND THEN
        RETURN NULL;
    END IF;

    RETURN jsonb_build_object(
        'id', v_s.id,
        'code', v_s.code,
        'ship_date', v_s.ship_date,
        'created_at', v_s.created_at,
        'order_id', v_s.order_id,
        'order_code', v_s.order_code,
        'customer_code', v_s.customer_code,
        'customer_name', v_s.customer_name,
        'lines', COALESCE((
            SELECT jsonb_agg(jsonb_build_object(
                       'id', sl.id,
                       'qty', sl.qty,
                       'line_no', sol.line_no,
                       'batch_code', ob.code,
                       'unit', ob.unit,
                       'material_code', m.code,
                       'material_name', m.name,
                       'waste_classification_code', m.waste_classification_code,
                       'location_code', loc.code,
                       'location_name', loc.name,
                       'dg_code', m.dg_code,
                       'dg_class', g.dg_class,
                       'dg_name_en', g.name_en,
                       'dg_name_zh', g.name_zh,
                       'dg_missing', COALESCE(mk.has_condition_axes, false) AND m.dg_code IS NULL,
                       'hs_code', m.hs_code,
                       'quarantine_states', batch_quarantine_states(ob.id)) ORDER BY sl.created_at, sol.line_no)
              FROM shipment_lines sl
              JOIN sales_order_lines sol ON sol.id = sl.sales_order_line_id
              JOIN output_batches ob ON ob.id = sl.output_batch_id
              LEFT JOIN materials m ON m.id = ob.material_id
              LEFT JOIN material_kinds mk ON mk.code = m.kind_code
              LEFT JOIN dangerous_goods_codes g ON g.code = m.dg_code
              LEFT JOIN storage_locations loc ON loc.id = sl.location_id
             WHERE sl.shipment_id = v_s.id), '[]'::jsonb));
END;
$function$
;

CREATE OR REPLACE FUNCTION public.ship_order(p_sales_order_id uuid, p_ship_date date, p_lines jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user     uuid := auth.uid();
    v_order    sales_orders%ROWTYPE;
    v_ship_id  uuid := gen_random_uuid();
    v_code     text;
    v_item     jsonb;
    v_res      record;
    v_res_id   uuid;
    v_split    jsonb;
    v_inv      record;
    v_line_ids uuid[] := ARRAY[]::uuid[];
    v_mv       uuid;
    v_sl_id    uuid;
    v_sale_id  uuid;
    v_rev_ccy  numeric := 0;
    v_fx       numeric;
    v_unit     numeric;
    v_cogs     numeric;
    v_je1      jsonb;
    v_je2      jsonb;
    v_rem      numeric;
    v_state    text;
    v_ordered  numeric;
    v_shipped  numeric;
    v_status   text;
    v_n        int;
    v_cust     record;
    v_ceiling  numeric;
    v_taken    jsonb := '{}'::jsonb;
    v_scanned  text;
    v_bcode    text;
BEGIN
    -- ════════════════════════════════════════════════════════════════════════
    -- ★ APR-5b(Tim 2026-09-25,APR-5 grilling Q7):【发货归仓库,在 CFO 放行之后】
    -- 门从 module.sales.edit 换成 action.ship_goods(warehouse · admin);cco 从此不发货。
    -- 此前这里写着"发货就是一次销售行为,做它的人是销售" —— Tim 的矩阵把它劈成两半:
    -- 【答应卖】(订单、预留、提放行)仍是销售的;【把货交出去】是仓库的,而且要 CFO 先放行。
    -- 部分发货的拆分改调 release_reservation_internal(不问码)—— 仓库不持 module.sales.edit。
    -- 台账的不变量仍不依赖调用者是谁:check_no_negative_bucket 与 check_ledger_invariant
    -- 都是约束触发器,对任何身份一视同仁。
    --
    -- 【收入与 COGS 的过账也在这里,而它们是财务的事】—— 但把这一步拆成
    -- "发货 + 财务过账"两次调用,就等于允许一个【发了货却没记收入】的
    -- 中间态存在。选项 C 的整条链是一个事务,所以它是一个函数。
    -- ★ APR-5b(5b grilling Q5):所以按发货的人【看不见】他触发的那笔收入 —— 返回值里不再有
    --   任何金额、币种或汇率(只剩发货单号、日期、行数、订单状态与收入分录的编号)。
    -- ════════════════════════════════════════════════════════════════════════
    PERFORM require_permission('action.ship_goods');

    -- 【发货日必填,永不默认】物理事件日,而且它决定收入落进哪个会计期间。
    IF p_ship_date IS NULL THEN
        RAISE EXCEPTION 'SHIP_DATE_REQUIRED';
    END IF;

    SELECT * INTO v_order FROM sales_orders WHERE id = p_sales_order_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'SO_NOT_FOUND|%', COALESCE(p_sales_order_id::text, '?');
    END IF;
    IF v_order.status NOT IN ('confirmed', 'partially_shipped') THEN
        RAISE EXCEPTION 'SO_SHIP_ORDER_NOT_SHIPPABLE|%|%', v_order.code, v_order.status;
    END IF;

    -- ★ APR-5 grilling Q6:【发货那一刻】客户在冻结上 → 按名拒。放行时不冻结不算数 ——
    --   CFO 放行之后客户被冻结,货就不该再离场。放行本身不失效(5b Q4:只有作废让放行失效),
    --   解冻之后照原放行发。
    SELECT c.code, c.credit_hold INTO v_cust FROM customers c WHERE c.id = v_order.customer_id;
    IF v_cust.credit_hold THEN
        RAISE EXCEPTION 'SO_SHIP_CUSTOMER_ON_HOLD|%|%', v_order.code, v_cust.code;
    END IF;

    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'SO_SHIP_NO_LINES|%', v_order.code;
    END IF;

    v_code := next_shipment_code(p_ship_date);
    INSERT INTO shipments (id, code, sales_order_id, ship_date, notes, created_by)
    VALUES (v_ship_id, v_code, p_sales_order_id, p_ship_date, NULL, v_user);

    FOR v_item IN SELECT * FROM jsonb_array_elements(p_lines)
    LOOP
        v_res_id := NULLIF(v_item->>'reservation_id', '')::uuid;

        SELECT r.id, r.sales_order_line_id, r.output_batch_id, r.location_id, r.qty,
               r.released_at, r.consumed_at,
               l.line_no, l.unit_price, l.sales_order_id,
               l.price_source, l.price_provenance
          INTO v_res
          FROM sales_order_reservations r
          JOIN sales_order_lines l ON l.id = r.sales_order_line_id
         WHERE r.id = v_res_id
         FOR UPDATE OF r;
        -- 【不是这张单的预留 / 不存在 / 已释放 / 已发过 —— 都是"没有这条预留"】
        IF NOT FOUND OR v_res.sales_order_id <> p_sales_order_id
           OR v_res.released_at IS NOT NULL OR v_res.consumed_at IS NOT NULL THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_RESERVED|%', COALESCE(v_res_id::text, '?');
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- ★ MES-3b(2026-10-07,MES-3b Step 0 Q24,Tim):【一次可选的核对扫码】—— 发货队列的那一行可以带上
        --   scanned_code(页面经 resolve_scan_code 认出来的那个批号);带了而与这条预留的批次不是同一个
        --   → SHIP_SCAN_MISMATCH|<扫到的>|<该发的>。不带照常发(Q24:不必扫;要必扫以后是一个开关,不是改码)。
        --   比的是批号本身(不分大小写、去掉两头空白)—— 不在这里再解析一遍短链接:认身份只有 resolve_scan_code 一处。
        -- ════════════════════════════════════════════════════════════════════
        v_scanned := NULLIF(btrim(v_item->>'scanned_code', E' \t\r\n'), '');
        IF v_scanned IS NOT NULL THEN
            SELECT ob.code INTO v_bcode FROM output_batches ob WHERE ob.id = v_res.output_batch_id;
            IF upper(v_scanned) IS DISTINCT FROM upper(v_bcode) THEN
                RAISE EXCEPTION 'SHIP_SCAN_MISMATCH|%|%', v_scanned, v_bcode;
            END IF;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【先开票后发货 —— 而判据是【派生】的,不是订单上的一个状态位】
        -- 这一行必须坐在一张【在册且已过账】的订单流发票上。状态位会与真相
        -- 漂开(作废一张票之后那个位还亮着),而这个问题每次都问得起。
        -- 顺带把那张票的【存下来的汇率】取出来:释放负债要按它,不按今天的行情
        -- —— 2500 里躺着的就是按它记进去的那个数(FIN-27 一族)。
        -- ════════════════════════════════════════════════════════════════════
        SELECT i.id, i.code, i.fx_rate, i.currency, il.id AS invoice_line_id
          INTO v_inv
          FROM invoice_lines il
          JOIN invoices i ON i.id = il.invoice_id
         WHERE il.sales_order_line_id = v_res.sales_order_line_id
           AND NOT il.invoice_voided
           AND i.kind = 'order' AND i.status = 'issued'
         LIMIT 1;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_INVOICED|%|%', v_order.code, v_res.line_no;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- ★ APR-5a(grilling Q10):【一张在等 CFO 的申请,把它要改的那一截货按住】
        -- 收款从不被挡(批准时的过账会按引擎原话拒);发货要挡 —— 否则等待期间发出去的一批货,
        -- 会把一张作废申请变成 INVOICE_SHIPPED_NOT_VOIDABLE,把一张"未发货取消"的贷项
        -- 变成对已经离场的货的取消。
        --   ① 这张发票挂着一张在等的【作废】申请 → INVOICE_VOID_REQUESTED|发票
        --   ② 这一条发票行挂在一张在等的【贷项】申请里、类型是 unshipped_cancel
        --      → INVOICE_CREDIT_REQUESTED|发票|行号
        -- ════════════════════════════════════════════════════════════════════
        IF EXISTS (SELECT 1 FROM invoice_requests q
                    WHERE q.invoice_id = v_inv.id AND q.status = 'submitted' AND q.kind = 'void') THEN
            RAISE EXCEPTION 'INVOICE_VOID_REQUESTED|%', v_inv.code;
        END IF;
        IF EXISTS (SELECT 1
                     FROM invoice_requests q
                     CROSS JOIN LATERAL jsonb_array_elements(q.lines) e
                     JOIN invoice_lines il ON il.id = NULLIF(e->>'invoice_line_id', '')::uuid
                    WHERE q.invoice_id = v_inv.id AND q.status = 'submitted' AND q.kind = 'credit_note'
                      AND e->>'kind' = 'unshipped_cancel'
                      AND il.sales_order_line_id = v_res.sales_order_line_id) THEN
            RAISE EXCEPTION 'INVOICE_CREDIT_REQUESTED|%|%', v_inv.code, v_res.line_no;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- ★ APR-5b(APR-5 grilling Q3 · 5b Q2):【这条发票行被一张 approved 的放行点了名】
        -- 覆盖是现算的:上面那一句已经要求发票行 NOT invoice_voided,所以作废过的发票
        -- 自己就不再被覆盖 —— 没有任何东西要去改放行。放行之后加的行要它自己的放行。
        -- ════════════════════════════════════════════════════════════════════
        IF NOT EXISTS (SELECT 1 FROM shipping_release_lines rl
                         JOIN shipping_releases r ON r.id = rl.release_id
                        WHERE rl.invoice_line_id = v_inv.invoice_line_id AND r.status = 'approved') THEN
            RAISE EXCEPTION 'SO_SHIP_NOT_RELEASED|%|%', v_order.code, v_res.line_no;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- ★ APR-5 grilling Q8 · 5b Q1:【天花板 = 开票数量 − Σ 未发货取消贷项的数量 − 已发】
        -- 取消掉的那一截已经从应收里拿走了(贷项借 2500),再把它发出去就是白送。
        -- 开票 − 取消的那一半只有一处推导:sales_order_line_releasable_all(发货队列与仪表盘读同一张)。
        -- 同一次调用里发过的同一行累计进去(v_taken)。
        -- 超出的那一截预留【不】自动释放:按名拒,由销售释放(5b Q1)。
        -- ════════════════════════════════════════════════════════════════════
        IF (v_item->>'qty') IS NOT NULL
           AND ((v_item->>'qty')::numeric <= 0 OR (v_item->>'qty')::numeric > v_res.qty) THEN
            RAISE EXCEPTION 'SO_SHIP_EXCEEDS_RESERVATION|%|%', v_item->>'qty', v_res.qty;
        END IF;
        v_ceiling := (SELECT ra.releasable_qty FROM sales_order_line_releasable_all ra
                       WHERE ra.invoice_line_id = v_inv.invoice_line_id)
                   - COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl
                                WHERE sl.sales_order_line_id = v_res.sales_order_line_id), 0)
                   - COALESCE((v_taken->>(v_res.sales_order_line_id::text))::numeric, 0);
        IF COALESCE((v_item->>'qty')::numeric, v_res.qty) > v_ceiling THEN
            RAISE EXCEPTION 'SO_SHIP_EXCEEDS_RELEASABLE|%|%|%|%', v_order.code, v_res.line_no,
                trim_scale(COALESCE((v_item->>'qty')::numeric, v_res.qty)), trim_scale(GREATEST(v_ceiling, 0));
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【部分发货:先把预留拆开,再整条消耗】(SO-2 的形状,一处实现)
        -- release_reservation(id, 要放回的数量, 理由) = 整笔释放 + 就地重新
        -- 预留剩余。所以要发 q(< 预留量 r)时,先把 (r − q) 放回 available,
        -- 剩下的那条新预留就正好是 q,然后【整条】消耗它。
        -- 【为什么不直接从这条预留里取走 q】那会让"committed 桶 = Σ 活预留"
        -- 不再成立:剩余的 (r − q) 还在桶里,却没有任何一行说它属于谁 ——
        -- 而 create_stock_transfer 的整桶搬正是靠那条不变量。
        -- 【也不在这里抄一份拆分逻辑】拆分只有一处实现,就是 release_reservation。
        -- ════════════════════════════════════════════════════════════════════
        IF (v_item->>'qty') IS NOT NULL AND (v_item->>'qty')::numeric <> v_res.qty THEN
            v_split := release_reservation_internal(v_res.id, v_res.qty - (v_item->>'qty')::numeric,
                                                    'partial shipment ' || v_code);
            v_res_id := (v_split->'rereserved'->>'reservation_id')::uuid;
            SELECT r.id, r.sales_order_line_id, r.output_batch_id, r.location_id, r.qty,
                   l.line_no, l.unit_price, l.price_source, l.price_provenance
              INTO v_res
              FROM sales_order_reservations r
              JOIN sales_order_lines l ON l.id = r.sales_order_line_id
             WHERE r.id = v_res_id;
        END IF;

        -- ════════════════════════════════════════════════════════════════════
        -- 【出库:直接写,不走 drain_stock】—— 预留【就是地址】(哪一批、哪个
        -- 库位、多少),所以这是一次【定址消耗】。drain_stock 是给【没有地址】
        -- 的消耗用的策略排空器(销售直接卖、投料、注销):它按 NULL 桶优先、
        -- 再按库位 code 升序去猜该动哪一份。这里没有可猜的 —— 猜反而会取错桶。
        -- 两个函数的函数头互相指着对方,免得下一个人以为这里漏用了它。
        -- ════════════════════════════════════════════════════════════════════
        INSERT INTO inventory_movements
            (output_batch_id, location_id, movement_type, qty_delta, stock_status,
             business_date, notes, created_by)
        VALUES (v_res.output_batch_id, v_res.location_id, 'sale', -v_res.qty, 'committed',
                p_ship_date, 'shipped ' || v_code, v_user)
        RETURNING id INTO v_mv;

        -- 销售记录:一条腿一行。价格与币种取【订单】的,汇率取【发票存下来的】。
        -- 出处从订单行原样抄过来(FIN-26:记录,不推断)。
        -- sales_order_line_id 就是那个标记 —— 它让这一行【不产生应收】
        -- (ar_open_items 第一支与 customer_ar_exposure_base 第一项都排除它)。
        INSERT INTO sales_records (output_batch_id, customer_id, quantity, unit_price,
                                   currency, fx_rate, amount_base, sale_date, notes,
                                   created_by, price_source, price_provenance,
                                   sales_order_line_id)
        VALUES (v_res.output_batch_id, v_order.customer_id, v_res.qty, v_res.unit_price,
                v_order.currency, v_inv.fx_rate,
                round(v_res.qty * v_res.unit_price * v_inv.fx_rate, 2),
                p_ship_date, 'shipped ' || v_code || ' · ' || v_order.code,
                v_user, v_res.price_source, v_res.price_provenance,
                v_res.sales_order_line_id)
        RETURNING id INTO v_sale_id;

        -- SO-2b:腿表 —— 一条出库腿一行(这里恰好一条,因为消耗是定址的)
        INSERT INTO sales_record_movements (sales_record_id, movement_id)
        VALUES (v_sale_id, v_mv);

        INSERT INTO shipment_lines (shipment_id, sales_order_line_id, reservation_id,
                                    output_batch_id, location_id, qty, sales_record_id)
        VALUES (v_ship_id, v_res.sales_order_line_id, v_res.id,
                v_res.output_batch_id, v_res.location_id, v_res.qty, v_sale_id)
        RETURNING id INTO v_sl_id;

        -- 预留的第二种终局:【消耗】。没有反向流水 —— 货离开了台账。
        -- 【不回写 shipment_line_id】那一列不存在:shipment_lines.reservation_id
        -- 已经是 UNIQUE,反向指针是冗余的,而两表互指会让镜像循环依赖、
        -- 重建排不出建表顺序(verify_rebuild 当场抓到过)。
        UPDATE sales_order_reservations
           SET consumed_at = now(), consumed_by = v_user
         WHERE id = v_res.id;

        -- 库存缓存:与 record_output_sale 逐字同一套(remaining_qty 与 state)
        SELECT remaining_qty INTO v_rem FROM output_batches WHERE id = v_res.output_batch_id FOR UPDATE;
        v_rem := v_rem - v_res.qty;
        v_state := CASE WHEN v_rem = 0 THEN '已售罄' ELSE '部分售出' END;
        UPDATE output_batches
           SET remaining_qty = v_rem, state = v_state, updated_by = v_user, updated_at = now()
         WHERE id = v_res.output_batch_id;

        -- COGS:与 record_output_sale 逐字同形 —— 有产出腿单位成本才挂,
        -- 没有就等 allocate_processing_costs 补挂(它读 sales_records,
        -- 而这一行就是一条普通的 sales_records,所以它自然看得见)。
        SELECT po.unit_cost_base INTO v_unit
        FROM processing_outputs po WHERE po.output_batch_id = v_res.output_batch_id LIMIT 1;
        IF v_unit IS NOT NULL THEN
            v_cogs := round(v_res.qty * v_unit, 2);
            IF v_cogs <> 0 THEN
                v_je2 := post_journal_entry(
                    p_ship_date,
                    'COGS ' || (SELECT code FROM output_batches WHERE id = v_res.output_batch_id),
                    'shipment', v_sale_id,
                    jsonb_build_array(
                        jsonb_build_object('account_code', '5000', 'side', 'debit',  'currency', base_currency_code(), 'amount_ccy', v_cogs),
                        jsonb_build_object('account_code', '1220', 'side', 'credit', 'currency', base_currency_code(), 'amount_ccy', v_cogs)));
                UPDATE sales_records SET cogs_entry_id = (v_je2->>'entry_id')::uuid WHERE id = v_sale_id;
            END IF;
        END IF;

        -- 收入侧按【发票存下来的汇率】累计(一张发货单属于一张订单,所以一个汇率)
        v_fx := v_inv.fx_rate;
        v_rev_ccy := v_rev_ccy + round(v_res.qty * v_res.unit_price, 2);
        v_line_ids := v_line_ids || v_res.sales_order_line_id;
        v_taken := jsonb_set(v_taken, ARRAY[v_res.sales_order_line_id::text],
            to_jsonb(COALESCE((v_taken->>(v_res.sales_order_line_id::text))::numeric, 0) + v_res.qty));
    END LOOP;

    -- ════════════════════════════════════════════════════════════════════════
    -- 【过账:借 2500 释放合同负债 / 贷 4000 收入】单据币种,按发票存下来的汇率。
    -- 这就是选项 C 的第二步 —— 开票认了债(借 1100 / 贷 2500),发货把那笔
    -- 负债换成收入。2500 因此在一张单全部发完之后精确归零(fixture 68 钉住)。
    -- ════════════════════════════════════════════════════════════════════════
    v_je1 := post_journal_entry(
        p_ship_date,
        'Shipment ' || v_code || ' · ' || v_order.code,
        'shipment', v_ship_id,
        jsonb_build_array(
            jsonb_build_object('account_code', '2500', 'side', 'debit',
                'currency', v_order.currency, 'amount_ccy', v_rev_ccy, 'fx_rate', v_fx),
            jsonb_build_object('account_code', '4000', 'side', 'credit',
                'currency', v_order.currency, 'amount_ccy', v_rev_ccy, 'fx_rate', v_fx)));

    -- ════════════════════════════════════════════════════════════════════════
    -- 【订单状态是【现算】出来的,不是人点的】已发 vs 已订,逐行比。
    -- 经 so_status_ctx 写入 —— 冻结守卫据此知道是"函数在动状态列"。
    -- 【SO-1b:这段推导搬进了 sales_order_fulfilment_status,两个消费方读同一份】
    -- 改单也要问同一个问题(加一行 / 把一行改到正好等于已发),抄一份过去,
    -- 两边会在写下的那天一致、此后各自漂移。v_ordered / v_shipped 仍然算,
    -- 因为下面那行历史要把 "已发/已订" 印出来 —— 那是【展示】,不是判据。
    -- ════════════════════════════════════════════════════════════════════════
    SELECT COALESCE(sum(l.quantity), 0) INTO v_ordered
      FROM sales_order_lines l WHERE l.sales_order_id = p_sales_order_id;
    SELECT COALESCE(sum(sl.qty), 0) INTO v_shipped
      FROM shipment_lines sl JOIN shipments s ON s.id = sl.shipment_id
     WHERE s.sales_order_id = p_sales_order_id;
    v_status := sales_order_fulfilment_status(p_sales_order_id);

    PERFORM set_config('evoltrya.so_status_ctx', '1', true);
    UPDATE sales_orders
       SET status = v_status, updated_at = now(), updated_by = v_user
     WHERE id = p_sales_order_id;
    PERFORM set_config('evoltrya.so_status_ctx', '', true);

    INSERT INTO sales_order_history (sales_order_id, change_type, detail, changed_by)
    VALUES (p_sales_order_id, 'shipped',
            v_code || ' · ' || trim_scale(v_shipped)::text || '/' || trim_scale(v_ordered)::text,
            v_user);

    -- 【断言,不是假设】发货行的条数必须等于递进来的条数。将来有人给上面任何
    -- 一段加一个提前 CONTINUE,这里当场炸,而不是留下一张少了几行的发货单
    -- (而那张单的收入分录已经按【全部】行算过了)。
    SELECT count(*) INTO v_n FROM shipment_lines WHERE shipment_id = v_ship_id;
    IF v_n <> jsonb_array_length(p_lines) THEN
        RAISE EXCEPTION 'SO_SHIP_LINES_LOST|%|%', jsonb_array_length(p_lines), v_n;
    END IF;

    -- ★ APR-5b(5b grilling Q5):发货的人是仓库,仓库看不见销售金额 —— 返回值里没有钱。
    --   收入分录的【编号】留着(它是一个编号,不是一个数;fixture 68 照它找分录)。
    RETURN jsonb_build_object(
        'shipment_id', v_ship_id,
        'code', v_code,
        'ship_date', p_ship_date,
        'line_count', v_n,
        'order_status', v_status,
        'revenue_journal', v_je1->>'code');
END;
$function$

;

-- db/functions/change_log_exclusions.sql
-- HISTORY-1(Tim 的 Q5):不挂变更记录触发器的表 —— 【唯一】的一份名单,每一条带理由。
--
-- 三处读它,所以它只能有一份:
--   · change_log_coverage_gaps() —— gate 的 changelog 那一行(线上 + 重建)与 fixture 234;
--   · scripts/check-change-log-coverage.mjs —— 构建里的静态检查,从本文件的 VALUES 里读;
--   · db/scripts/gen_change_log_bindings.py —— 生成绑定清单时跳过这几张。
-- ★ 规矩(docs/change-log.md):新建的每一张 public 表,要么在 db/views/zzz_change_log_triggers.sql
--   里有两条绑定,要么在这里有一行带理由的豁免。两者都没有,构建与 gate 都会红。
-- ★ MES-1(2026-10-06,MES-0 Q14,Tim):第二种被接受的豁免 —— 【采集层的三份日志】(收件箱 · 传输日志 · 网关中断)。
--   它们本身就是只追加的日志(守卫按名拒改与删);再记一遍是把规格 §2.1 警告的量翻一倍,而不多一个事实。
--   状态的变化记在行上(收件箱的 attempts · last_attempt_* · discarded_*)。
CREATE OR REPLACE FUNCTION public.change_log_exclusions()
 RETURNS TABLE(table_name text, reason text)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    VALUES
        ('change_log'::text, 'The change log itself; a trigger on it would record its own writes.'::text),
        ('festival_doodles', 'Home-screen holiday artwork; screen decoration with no business meaning.'),
        ('gateway_outages', 'Ingestion log (MES-1): itself an append-only record of gateway silences; logging it again doubles the volume and adds no fact.'),
        ('home_greetings', 'Home-screen greeting text; screen decoration with no business meaning.'),
        ('ingest_inbox', 'Ingestion log (MES-1): itself an append-only landing table; its status changes are recorded on the row (attempts, last attempt, discard).'),
        ('ingest_transmissions', 'Ingestion log (MES-1): itself an append-only log of every gateway call; logging it again doubles the volume and adds no fact.'),
        ('notification_reads', 'Per-viewer "seen" marks on notifications; screen state with no business meaning.'),
        ('scan_events', 'Scan log (MES-3b): itself an append-only record of every scan resolved on a page; logging it again doubles the volume and adds no fact.');
$function$;

-- db/functions/trail_subjects.sql
-- AUDIT-TRAIL-1a(Tim 的 Q5):审计记录的【主语登记表】。页面只说"哪一种记录、哪一条",从不说表名;
--   表名、根键、以及【这一页自己的查看权限码】只住在这里(服务端)。不在这里的主语 → TRAIL_SUBJECT_UNKNOWN。
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M1 · M3 · M6)多了三列:
--   view_codes   【任一】即可进(M1)—— 与页面守卫同一组码。一页只认一个码时就是一个元素的数组。
--                warehouse_request:/inventory 那一块(module.inventory.view)与财务(module.finance.view)都读它。
--   root_rule    (AUDIT-TRAIL-1d-1 多了两种:'collection' —— M11,一张表整张是一条记录;'gate:<名字>' —— M12,比表的规则更窄)
--                'table'(默认):根行还要过它自己那张表的读规则,过不了 → TRAIL_NOT_PERMITTED。
--                'page'(M3):页面的码就是门;根行自己的那几次改动照子行的规矩走 —— 读者过不了根表的读规则,
--                那几条就是 Restricted(Q4)。equipment 用它:根表 fixed_assets 只给财务读,而这一页给加工的人。
--   root_columns 非空(M6):根行只取这几列的改动(一块面板只管它自己编辑的那几个字段,Q25 的同一条规矩)。
--                NULL = 整行。1b-3 的三个阈值面板会用到它;本刀先建好,fixture 237 用一个临时主语证它。
-- view_codes 与页面守卫逐字同一组码:
--   purchase_order → /purchasing/orders/[id]        requireModule(MOD.purchasing) = module.purchasing.view
--   processing_run → /operation/processing/[id]     requireModule(MOD.processing) = module.processing.view
--   role           → /settings/roles/[id]           requireManagePermissions()     = action.manage_permissions
--   inbound_batch  → /inbound/[id]/edit             requireModule(MOD.inbound)     = module.inbound.view
--   output_batch   → /output/[id]/edit              requireModule(MOD.output)      = module.output.view
--   work_order     → /operation/orders/[id]         requireModule(MOD.processing)  = module.processing.view
--   stocktake      → /stocktakes/[id]               requireModule(MOD.stocktakes)  = module.stocktakes.view
--   equipment      → /operation/equipment/[id]      requireModule(MOD.processing)  = module.processing.view
--   shift_handover → /operation/handovers/[id]      requireModule(MOD.processing)  = module.processing.view
--   warehouse_request → /inventory 的申请一块        requireModule(MOD.inventory)   = module.inventory.view(+ 财务)
-- AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a 的商务那一半):
--   quote          → /sales/quotes/[id]              requireModule(MOD.sales)       = module.sales.view
--   sales_order    → /sales/orders/[id]              requireModule(MOD.sales)       = module.sales.view
--   shipment       → /sales/shipments/[id]           action.ship_goods,否则 requireModule(MOD.sales)(M1:任一)
--   customer       → /sales/customers/[id]           requireModule(MOD.customers)   = module.customers.view
--   commission_agreement → /sales/commissions/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   supplier       → /suppliers/[id]/edit(只有这一页,Q2)requireModule(MOD.suppliers) = module.suppliers.view
--   container      → /logistics/containers/[id]      requireModule(MOD.logistics)   = module.logistics.view
--   forwarder      → /logistics/forwarders/[id]      requireModule(MOD.logistics)   = module.logistics.view
--                    根表是 suppliers(读规则 module.suppliers.view)—— M3:页面的码是门,根行自己的改动逐行判
--   lane · port    → /logistics/lanes(只有清单页,按条合起来,见 app/components/trail/ListTrail.tsx)module.logistics.view
--   company_licence → /purchasing/licences(只有清单页)门是 module.purchasing.view,而这张表的读规则是
--                    module.suppliers.view —— 这一块只画在持 suppliers.view 的那一支里(页面本来就那样分),所以登记后者
-- AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a 的主数据与工具):
--   material       → /materials/[id]/edit(只有这一页,Q2)requireModule(MOD.materials) = module.materials.view
--   storage_location → /inventory/locations/[id]/edit(只有这一页)requireModule(MOD.inventory) = module.inventory.view
--   metal_price    → /tools/pricing/metal-prices/[id]/edit(只有这一页)requireEditPermission('action.metal_prices')
--   pricing_formula → /tools/pricing/formulas/[id]/edit(只有这一页)requireModule(MOD.pricing) = module.pricing.view
--   task           → /tools/tasks/[id]                requireModule(MOD.tasks)       = module.tasks.view
--                    私人任务也读得到(Q3):根行要过 tasks 自己的读规则(团队任务 · 自己的 · 或持 module.tasks.view_all)——
--                    那正是"谁打得开这一页"的同一个判据,而遮蔽那一步本来就先问任务隐私
--   processing_settings → /operation/orders 的工单阈值面板          module.processing.view;M6:只取面板编辑的两列
--   pricing_settings    → /tools/pricing/metal-prices 的异常阈值面板  module.pricing.view;M6:只取那一列
--   receiving_settings  → /purchasing/discrepancies 的收货阈值面板   module.inbound.view(面板只画在这一支里);M6:三列
--                    三张都是单行表,主键 id boolean —— M5:页面传 'true',读法按根行自己的类型重建那个键
-- AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第一刀:账上的单据):
--   journal_entry   → /finance/journal/[id]             requireModule(MOD.finance)     = module.finance.view
--   invoice         → /finance/invoices/[id]            requireModule(MOD.finance)     = module.finance.view
--   credit_note     → /finance/credit-notes/[id]        requireModule(MOD.finance)     = module.finance.view
--   payment         → /finance/payments/[id]            requireModule(MOD.finance)     = module.finance.view
--   payment_request → /finance/payment-requests/[id]    requireModule(MOD.finance)     = module.finance.view
--                    (行内转账、代扣税缴纳与它们的冲销也住在这一页 —— 它们没有自己的页,Q17)
--   expense         → /finance/expenses/[id]            requireModule(MOD.finance)     = module.finance.view
--   payable         → /finance/payables/[batchId]       requireModule(MOD.finance)     = module.finance.view
--                    根表是 inbound_batches(读规则 module.inbound.view)—— M3:页面的码是门(Q5,forwarder 的先例);
--                    M6:只取应付那几列(数量、单价、供应商、采购单、计价状态、到货日、注销三列)—— 批次的仓库那一面
--                    (化验、安全状态、库位……)住在 /inbound/[id]/edit 的 inbound_batch 上,不在应付页上再说一遍。
--                    注销那三列必须在里面:M6 丢掉 root_columns 之外的戳(record_trail),不在里面注销就看不见(Q5 的横幅)。
-- AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第二刀:其余的单据与合同):
--   sale            → /finance/receivables/[saleId]     requireModule(MOD.finance)     = module.finance.view
--   freight         → /finance/freight/[id]             requireModule(MOD.finance)     = module.finance.view
--                    (根表的读规则是 inbound.view OR finance.view,再加一条 finance.edit 的 ALL —— 页面的码过得了,不需要 M3)
--   fixed_asset     → /finance/assets/[id]              requireModule(MOD.finance)     = module.finance.view
--                    根表与 equipment 同一张 fixed_assets(supplier / forwarder 的先例:一张表两个主语,Q10)——
--                    equipment 的门是加工,这一页的门是财务;根表的读规则就是 finance.view,所以是 'table'
--   bank_statement  → /finance/bank/statements/[id]     requireModule(MOD.finance)     = module.finance.view
--                    删掉的对账单也读得到(Q6:持 data.view_deleted 的人只读打开;根表的读规则不过滤已删的行)
--   gst_period      → /finance/gst/[periodId]           requireModule(MOD.finance)     = module.finance.view
--   fx_rate         → /finance/fx/[id]/edit(只有这一页,Q2)requireModule(MOD.finance) = module.finance.view
--                    撤回了的汇率也读得到(Q7:页面对本来的读者只读打开)
--   management_pack → /finance/packs/[id]               requireModule(MOD.finance)     = module.finance.view
--   contract        → /contracts/[id]                   requireModule(MOD.suppliers)   = module.suppliers.view
--                    根表的读规则按方向:卖方合同要 customers.view、买方合同要 suppliers.view —— 页面在 RLS 下读、读不到就 404,
--                    所以 'table' 与页面同一个答案(看不见的合同对他而言不存在)
-- AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a,Q1 拆分的第三刀:期末、设置与清单页上的记录):
--   finance_lock    → /finance/settings 锁期面板之下 · /finance/close 关账史之下(Q25 · Q29)  module.finance.view
--                    根表 finance_settings(单行,id boolean —— M5,页面传 'true');M6:只取 locked_before 一列;
--                    月结 / 反结(period_closes)经 M7 整张表属于这一行(两张表之间一个键都没有,Q3)
--   finance_gst     → /finance/settings GST 面板之下                                       module.finance.view
--                    同一行(M5);M6:只取 gst_registered、gst_registration_no 两列 —— 两块面板各看各的(Q25);
--                    这一行上没有面板的六列(gst_rate_pct · system_start_date · 三个财年列 · default_allocation_basis)
--                    哪一块都不取,只在 /settings/change-history 上找得到(Q4);审批方针那四列归 AT-1d(Q2)
--   company_profile → /finance/company                                                     requireModule(MOD.finance)
--                    单行(M5),整行 —— 一块面板编辑整行;银行那五列按 HISTORY-1 的规则对不持 data.view_banking 的人遮
--   year_close      → /finance/close 年结那一块(清单块,ListTrail)                          module.finance.view
--   journal_request → /finance/journal 每一张申请卡片里(Q17,一张一块)                     module.finance.view
--   expense_claim   → /finance/claims 每一张报销单一块(Q20)                                module.finance.view
--   my_expense_claim → /me 报销人自己那几张(Q20 的另一半)—— ★ M8:没有页面码(view_codes 为空数组),
--                    根行自己那张表的读规则就是门(expense_claims:module.finance.view 或者【这张单说的就是你】);
--                    只许与 'table' 同用(record_trail 里拒绝 'page' —— 那会对每一个人敞开)。
--                    审批留痕那一支(approval_log 的 expense_claim)不给本人开口子,所以本人看到的是 Restricted(Q4)
--   bank_transfer   → /finance/bank 转账那一块(清单块)                                     module.finance.view
--   wht_remittance  → /finance/wht 缴纳那一块(清单块)                                      module.finance.view
--   cash_forecast · cash_forecast_line → /finance/cash-forecast(清单块,Q16:冻结 + 作废旧的一张是一次操作)
--   bank_import_profile → /finance/bank/import(清单块,删掉的也读)                         module.finance.view
--   (重估 / 折旧 / 工资付款 / 加工成本结算的批次与批量汇率【不】另立主语:它们各自的清单块读 journal_entry · expense ·
--    fx_rate 那几个现成主语,Q16 的 op_key 把一次操作并成一条 —— Q18 · Q19)
-- AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第一刀:机制、设置与员工):
--   account         → /settings/accounts 每一行一块(Q24)        requireManagePermissions()     = action.manage_permissions
--                    ★ M9:根表 auth.users 不在 public 里 —— trail_log_only_tables() 给它一份安全投影与声明的读码;
--                    事件(建立 / 停用 / 恢复 / 失败 / 回滚)住在 change_log(record_account_event)
--   approval_policy → /settings/approvals(Q25,1c 的 Q2 挪过来)requireFunction(FN.approvals) = action.manage_permissions
--                    同一行 finance_settings(M5);M6:只取它编辑的四列;修改史 finance_settings_history 经 M7 整张属于这一行。
--                    根表的读规则是 module.finance.view —— 'table':读者两个码都要(线上唯一持 manage_permissions 的 admin 两个都有,Q23)
--   employee        → /hr/employees/[id]                        requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这就是你】—— 与页面同一个答案
--   department      → /hr/departments/[id]/edit(只有这一页)   requireModule(MOD.hr)          = module.hr.view
--   training_record → /hr/training/[id]/edit(只有这一页,Q29) requireModule(MOD.hr)          = module.hr.view
--   import_batch    → /settings/import 的批次一块(清单块,Q24) can('action.bulk_import')      = action.bulk_import
--   dictionary_*    → /settings/dictionaries 每一段一块(Q4)    每一段自己的查看码(registry.ts 的 viewPermission)
--                    ★ M11:'collection' —— 没有根行,那张字典表的每一行、change_log 里它的每一行都属于这一块;根键照写那张表的主键
--                    (code),record_trail 不用它。
--   ☞ M12('gate:reviewer')本刀没有主语用它(它的第一个用户是 AT-1d-3 的 /my-reviews —— 1d-3 已接上,见下面 my_review);fixture 244 用一个临时主语证它。
-- AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第二刀:请假与考勤):
--   leave_request     → /hr/leave/[id]                  requireModule(MOD.hr)          = module.hr.view
--                    根表的读规则是 hr.view 或【这张单说的就是你】—— 与页面同一个答案
--   my_leave_request  → /me 本人那几张(Q14,M8:没有页面码 —— 根行自己的读规则就是门;审批与消耗那几行对本人是 Restricted)
--   leave_grant       → /hr/leave/grants 那一块(清单块,按年)         module.hr.view
--   leave_types       → /hr/leave/types(M11 集合,根键 code)         module.hr.view
--   public_holidays   → /hr/leave/holidays(M11 集合 —— 假期是【硬删】的,一行删掉之后只剩变更记录里那一份影像)
--   medical_claim     → /hr/claims/[id]                 requireModule(MOD.hr)          = module.hr.view
--   my_medical_claim  → /me 本人那几张(Q14,M8)
--   overtime_batch    → /hr/overtime/[id]               requireFunction(FN.overtime)   = M1:hr.view · overtime_enter · overtime_approve
--                    (与页面守卫、与 overtime_batches 的读规则逐字同一组码)
--   attendance_period → /hr/attendance/[id]             requireModule(MOD.hr)          = module.hr.view
-- AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a,Q1 拆分的第三刀:工资与评审):
--   payroll_period      → /hr/payroll/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 hr.view —— 与页面同一个答案;工资行的金额对不持 data.view_pay 的人照遮蔽规则说 Restricted
--   performance_review  → /hr/reviews/[id]              requireModule(MOD.hr)          = module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或审核人 或【这是你的、已批】—— 页面读 performance_reviews_masked,
--                      同一个谓词,读不到就 notFound;所以 auditor / finance(hr.view,不持 view_reviews)两边都进不去
--   my_review           → /my-reviews/[id](审核人那一页,没有模块守卫)  M8 + M12:没有页面码,root_rule 'gate:reviewer' ——
--                      根行先过表的读规则,【再】过 trail_root_gate('reviewer'):只给这一份评审点名的审核人,
--                      不给被评审的本人(他在批准之后经"own approved"那一条读得到行,但这一段不是给他的,Q5)
--   review_cycle        → /hr/reviews/cycles 那一块(清单块,每一轮一条)   module.hr.view(Q6:没有成员 —— 开轮时铺下的那几份评审
--                      不挂进来,轮次那一块只说"开了 / 关了";每一份评审自己的那一段以"Annual review opened (cycle …)"开头)
--   review_rating_scale → /hr/reviews/scale(M11 集合,根键 code)      module.hr.view
--   kpi_entry           → /hr/kpi/score 那一块(清单块,选中那一个月的条目;只在 canSeeScores 那一支里画)  module.hr.view
--                      根表的读规则是 (hr.view 且 view_reviews) 或本人 —— 不持 view_reviews 的读者在页面那一支就进不来
-- 【后面几刀加主语】加一行这里、在 trail_subject_members 里登记它的子行与相关行、需要的话在
--   trail_prelog_sources 里登记"记录开始之前"的来源,然后在 lib/trail/ 里补它的措辞 —— 见 docs/change-log.md §9。
-- MES-1(2026-10-06,MES-1 Step 0 Q21 · Q22,Tim):
--   device          → /operation/devices/[id]           requireModule(MOD.processing) = module.processing.view
--                     成员 gateway_keys(钥匙的发放与撤销;哈希被 never 规则遮住)。收件箱、传输日志与中断不进变更记录(MES-0 Q14),
--                     所以不在这里 —— 设备页把中断单独列成一块(Q21)。
--   ingest_settings → /operation/devices 上的传输上限面板  module.processing.view;单行设置作根(M5),修改史就是变更记录(Q22)
CREATE OR REPLACE FUNCTION public.trail_subjects()
 RETURNS TABLE(subject text, view_codes text[], root_table text, root_key text, root_rule text, root_columns text[])
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        ('purchase_order',    ARRAY['module.purchasing.view'],    'purchase_orders',    'id', 'table', NULL::text[]),
        ('processing_run',    ARRAY['module.processing.view'],    'processing_runs',    'id', 'table', NULL),
        ('role',              ARRAY['action.manage_permissions'], 'roles',              'id', 'table', NULL),
        ('inbound_batch',     ARRAY['module.inbound.view'],       'inbound_batches',    'id', 'table', NULL),
        ('output_batch',      ARRAY['module.output.view'],        'output_batches',     'id', 'table', NULL),
        ('work_order',        ARRAY['module.processing.view'],    'work_orders',        'id', 'table', NULL),
        ('stocktake',         ARRAY['module.stocktakes.view'],    'stocktakes',         'id', 'table', NULL),
        ('equipment',         ARRAY['module.processing.view'],    'fixed_assets',       'id', 'page',  NULL),
        ('shift_handover',    ARRAY['module.processing.view'],    'shift_handovers',    'id', 'table', NULL),
        ('warehouse_request', ARRAY['module.inventory.view', 'module.finance.view'], 'warehouse_requests', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-2
        ('quote',             ARRAY['module.sales.view'],         'quotes',             'id', 'table', NULL),
        ('sales_order',       ARRAY['module.sales.view'],         'sales_orders',       'id', 'table', NULL),
        ('shipment',          ARRAY['module.sales.view', 'action.ship_goods'], 'shipments', 'id', 'table', NULL),
        ('customer',          ARRAY['module.customers.view'],     'customers',          'id', 'table', NULL),
        ('commission_agreement', ARRAY['module.suppliers.view'],  'commission_agreements', 'id', 'table', NULL),
        ('supplier',          ARRAY['module.suppliers.view'],     'suppliers',          'id', 'table', NULL),
        ('container',         ARRAY['module.logistics.view'],     'containers',         'id', 'table', NULL),
        ('forwarder',         ARRAY['module.logistics.view'],     'suppliers',          'id', 'page',  NULL),
        ('lane',              ARRAY['module.logistics.view'],     'lanes',              'id', 'table', NULL),
        ('port',              ARRAY['module.logistics.view'],     'ports',              'id', 'table', NULL),
        ('company_licence',   ARRAY['module.suppliers.view'],     'company_compliance', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1b-3
        ('material',          ARRAY['module.materials.view'],     'materials',          'id', 'table', NULL),
        ('storage_location',  ARRAY['module.inventory.view'],     'storage_locations',  'id', 'table', NULL),
        ('metal_price',       ARRAY['action.metal_prices'],       'metal_prices',       'id', 'table', NULL),
        ('pricing_formula',   ARRAY['module.pricing.view'],       'pricing_formulas',   'id', 'table', NULL),
        ('task',              ARRAY['module.tasks.view'],         'tasks',              'id', 'table', NULL),
        ('processing_settings', ARRAY['module.processing.view'],  'processing_settings', 'id', 'table',
            ARRAY['wo_input_overrun_pct', 'wo_output_shortfall_pct']),
        ('pricing_settings',  ARRAY['module.pricing.view'],       'pricing_settings',   'id', 'table',
            ARRAY['metal_price_change_warn_pct']),
        ('receiving_settings', ARRAY['module.inbound.view'],      'receiving_settings', 'id', 'table',
            ARRAY['grn_short_pct', 'grn_over_pct', 'grn_assay_tolerance_pct']),
        -- AUDIT-TRAIL-1c-1
        ('journal_entry',     ARRAY['module.finance.view'],       'journal_entries',    'id', 'table', NULL),
        ('invoice',           ARRAY['module.finance.view'],       'invoices',           'id', 'table', NULL),
        ('credit_note',       ARRAY['module.finance.view'],       'credit_notes',       'id', 'table', NULL),
        ('payment',           ARRAY['module.finance.view'],       'payments',           'id', 'table', NULL),
        ('payment_request',   ARRAY['module.finance.view'],       'payment_requests',   'id', 'table', NULL),
        ('expense',           ARRAY['module.finance.view'],       'expenses',           'id', 'table', NULL),
        ('payable',           ARRAY['module.finance.view'],       'inbound_batches',    'id', 'page',
            ARRAY['supplier_id', 'purchase_order_id', 'quantity', 'unit', 'unit_price', 'pricing_status', 'arrival_date',
                  'deleted_at', 'deleted_by', 'delete_reason']),
        -- AUDIT-TRAIL-1c-2
        ('sale',              ARRAY['module.finance.view'],       'sales_records',      'id', 'table', NULL),
        ('freight',           ARRAY['module.finance.view'],       'freight_documents',  'id', 'table', NULL),
        ('fixed_asset',       ARRAY['module.finance.view'],       'fixed_assets',       'id', 'table', NULL),
        ('bank_statement',    ARRAY['module.finance.view'],       'bank_statements',    'id', 'table', NULL),
        ('gst_period',        ARRAY['module.finance.view'],       'gst_periods',        'id', 'table', NULL),
        ('fx_rate',           ARRAY['module.finance.view'],       'fx_rates',           'id', 'table', NULL),
        ('management_pack',   ARRAY['module.finance.view'],       'management_packs',   'id', 'table', NULL),
        ('contract',          ARRAY['module.suppliers.view'],     'contracts',          'id', 'table', NULL),
        -- AUDIT-TRAIL-1c-3
        ('finance_lock',      ARRAY['module.finance.view'],       'finance_settings',   'id', 'table', ARRAY['locked_before']),
        ('finance_gst',       ARRAY['module.finance.view'],       'finance_settings',   'id', 'table',
            ARRAY['gst_registered', 'gst_registration_no']),
        ('company_profile',   ARRAY['module.finance.view'],       'company_profile',    'id', 'table', NULL),
        ('year_close',        ARRAY['module.finance.view'],       'year_closes',        'id', 'table', NULL),
        ('journal_request',   ARRAY['module.finance.view'],       'journal_requests',   'id', 'table', NULL),
        ('expense_claim',     ARRAY['module.finance.view'],       'expense_claims',     'id', 'table', NULL),
        ('my_expense_claim',  ARRAY[]::text[],                    'expense_claims',     'id', 'table', NULL),
        ('bank_transfer',     ARRAY['module.finance.view'],       'bank_transfers',     'id', 'table', NULL),
        ('wht_remittance',    ARRAY['module.finance.view'],       'wht_remittances',    'id', 'table', NULL),
        ('cash_forecast',     ARRAY['module.finance.view'],       'cash_forecasts',     'id', 'table', NULL),
        ('cash_forecast_line', ARRAY['module.finance.view'],      'cash_forecast_lines', 'id', 'table', NULL),
        ('bank_import_profile', ARRAY['module.finance.view'],     'bank_import_profiles', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-1
        ('account',           ARRAY['action.manage_permissions'], 'auth.users',         'id', 'table', NULL),
        ('approval_policy',   ARRAY['action.manage_permissions'], 'finance_settings',   'id', 'table',
            ARRAY['approvals_enabled', 'approval_threshold_base', 'approval_level1_role_code', 'approval_level2_role_code']),
        ('employee',          ARRAY['module.hr.view'],            'employees',          'id', 'table', NULL),
        ('department',        ARRAY['module.hr.view'],            'departments',        'id', 'table', NULL),
        ('training_record',   ARRAY['module.hr.view'],            'training_records',   'id', 'table', NULL),
        ('import_batch',      ARRAY['action.bulk_import'],        'import_batches',     'id', 'table', NULL),
        ('dictionary_substances',          ARRAY['module.materials.view'], 'substances',             'code', 'collection', NULL),
        ('dictionary_battery_chemistries', ARRAY['module.materials.view'], 'battery_chemistries',    'code', 'collection', NULL),
        ('dictionary_material_kinds',      ARRAY['module.materials.view'], 'material_kinds',         'code', 'collection', NULL),
        ('dictionary_inbound_safety_states', ARRAY['module.materials.view'], 'inbound_safety_states', 'code', 'collection', NULL),
        ('dictionary_laboratories',        ARRAY['module.inbound.view'],   'laboratories',           'code', 'collection', NULL),
        ('dictionary_inbound_source_reasons', ARRAY['module.inbound.view'], 'inbound_source_reasons', 'code', 'collection', NULL),
        -- MES-3a(2026-10-06,MES-3a Step 0 Q4 · Q12):NEA 废物类别字典 —— 与其余六本同一个形状(清单块,/settings/dictionaries)
        ('dictionary_nea_waste_categories', ARRAY['module.materials.view'], 'nea_waste_categories', 'code', 'collection', NULL),
        -- MES-3b(2026-10-07):危险品 UN 编号字典(module.materials.view)· 标签模板字典(module.inventory.view)
        ('dictionary_dangerous_goods_codes', ARRAY['module.materials.view'], 'dangerous_goods_codes', 'code', 'collection', NULL),
        ('dictionary_label_templates',      ARRAY['module.inventory.view'], 'label_templates',       'code', 'collection', NULL),
        -- AUDIT-TRAIL-1d-2
        ('leave_request',     ARRAY['module.hr.view'],            'leave_requests',     'id', 'table', NULL),
        ('my_leave_request',  ARRAY[]::text[],                    'leave_requests',     'id', 'table', NULL),
        ('leave_grant',       ARRAY['module.hr.view'],            'leave_grants',       'id', 'table', NULL),
        ('leave_types',       ARRAY['module.hr.view'],            'leave_types',        'code', 'collection', NULL),
        ('public_holidays',   ARRAY['module.hr.view'],            'public_holidays',    'id', 'collection', NULL),
        ('medical_claim',     ARRAY['module.hr.view'],            'medical_claims',     'id', 'table', NULL),
        ('my_medical_claim',  ARRAY[]::text[],                    'medical_claims',     'id', 'table', NULL),
        ('overtime_batch',    ARRAY['module.hr.view', 'action.overtime_enter', 'action.overtime_approve'], 'overtime_batches', 'id', 'table', NULL),
        ('attendance_period', ARRAY['module.hr.view'],            'attendance_periods', 'id', 'table', NULL),
        -- AUDIT-TRAIL-1d-3
        ('payroll_period',      ARRAY['module.hr.view'],          'payroll_periods',     'id', 'table', NULL),
        ('performance_review',  ARRAY['module.hr.view'],          'performance_reviews', 'id', 'table', NULL),
        ('my_review',           ARRAY[]::text[],                  'performance_reviews', 'id', 'gate:reviewer', NULL),
        ('review_cycle',        ARRAY['module.hr.view'],          'review_cycles',       'id', 'table', NULL),
        ('review_rating_scale', ARRAY['module.hr.view'],          'review_rating_scale', 'code', 'collection', NULL),
        ('kpi_entry',           ARRAY['module.hr.view'],          'kpi_entries',         'id', 'table', NULL),
        -- MES-1
        ('device',              ARRAY['module.processing.view'],  'devices',             'id', 'table', NULL),
        ('ingest_settings',     ARRAY['module.processing.view'],  'ingest_settings',     'id', 'table', NULL),
        -- MES-2(2026-10-06,MES-2 Step 0 Q33):地磅单 —— 收货或物流查看码任一(与表的读策略逐字同一对,Q22)
        ('weighbridge_ticket',  ARRAY['module.inbound.view', 'module.logistics.view'], 'weighbridge_tickets', 'id', 'table', NULL)
    ) AS s(subject, view_codes, root_table, root_key, root_rule, root_columns);
$function$;

-- db/functions/trail_subject_members.sql
-- AUDIT-TRAIL-1a(Tim 的 Q3 · Q6):一个主语的审计记录【由哪些行组成】—— 根行之外的子行与相关行。
--   每一行说:这张表里 fk_column 等于 parent_table 某一行的 id 的那些行,属于这条记录;match 是额外的固定条件
--   (多态的 approval_log 靠 subject_type 认主)。parent_table 可以是另一张子表(孙行:付款保留金挂在明细行上)。
--   按 ord 依次展开,所以孙行排在它的父行之后。
-- 【子行是在读的时候找出来的】(Q6)—— 不在记录上写父键。找法见 record_trail:今天还在的行按外键查,
--   已经删掉或改过父键的行从 change_log 的影像里查(GIN 索引 idx_change_log_image / idx_change_log_update_old)。
-- 【每一行子行都要再过一次它自己那张表的读规则】(Q4)—— 由 record_trail 调 trail_row_visible 做,不在这里。
--
-- AUDIT-TRAIL-1b-1(Tim 2026-09-29,AT-1b Step 0 的 M4 与 Q4)多了三列:
--   hop    'down'(默认):table.fk_column = parent 那一行的 id(往下走)。
--          'up'(M4):table.id = parent 那一行的 fk_column(往上走一跳 —— 批次 → 消耗它的加工单、它收货的采购单)。
--   shown  true:这张表的行是这条记录的一部分,它们的每一次改动都进审计记录。
--          false:【垫脚石】—— 只用来够到它下面的行,它自己的改动不进来(Q4:"只限碰到这个批次的那些事")。
--          批次的审计记录经由加工单够到那张单的成本修改、分录与工单的审批,但加工单本身的编辑不在批次上。
--   home   true:这张表的行【住在】这个主语下 —— /settings/change-history 的"Record"一栏沿 home 的那一条往上走
--          (trail_row_record)。同一张表挂在两个主语下时(加工投入既属于加工单、也出现在批次上),只有一处是家。
--   原来旧批次审计记录那 20 支(db/views/batch_audit_trail_all.sql)的每一支都在下面有它的来处 ——
--   fixture 238 逐行对照两边,少一行就红。
CREATE OR REPLACE FUNCTION public.trail_subject_members()
 RETURNS TABLE(subject text, ord integer, table_name text, parent_table text, fk_column text, match jsonb, hop text, shown boolean, home boolean)
 LANGUAGE sql
 IMMUTABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT * FROM (VALUES
        -- 采购单:明细行 · 付款计划 · 保留金 · 条款承诺 · 签发 · 合同条款 · 审批 · 修改史(Tim 的 AT-1a 范围)
        ('purchase_order', 1, 'purchase_order_lines',           'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 2, 'purchase_order_payment_terms',   'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 3, 'purchase_order_line_retentions', 'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 4, 'pricing_term_commitments',       'purchase_order_lines', 'purchase_order_line_id', '{}'::jsonb, 'down', true, true),
        ('purchase_order', 5, 'po_issues',                      'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 6, 'contract_document_terms',        'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        ('purchase_order', 7, 'approval_log',                   'purchase_orders',      'subject_id',             '{"subject_type": "purchase_order"}'::jsonb, 'down', true, true),
        ('purchase_order', 8, 'purchase_order_history',         'purchase_orders',      'purchase_order_id',      '{}'::jsonb, 'down', true, true),
        -- 加工单:投入 · 产出 · 成本条目及其修改史 · 成本分摊 · 损耗;1b-1 加:回滚申请及其审批(Q12)
        ('processing_run', 1, 'processing_inputs',                 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 2, 'processing_outputs',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 3, 'processing_cost_entries',           'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 4, 'processing_cost_entry_history',     'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 5, 'batch_processing_cost_allocations', 'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 6, 'processing_run_losses',             'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, true),
        ('processing_run', 7, 'warehouse_requests',                'processing_runs',    'run_id',     '{}'::jsonb, 'down', true, false),
        ('processing_run', 8, 'approval_log',                      'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        -- 角色:授权(加上 / 拿掉);AUDIT-TRAIL-1d-1 加:授给了谁(Q22 —— 家在账号那一边:授出去的是那个账号)
        ('role', 1, 'role_permissions', 'roles', 'role_id', '{}'::jsonb, 'down', true, true),
        ('role', 2, 'user_roles',       'roles', 'role_id', '{}'::jsonb, 'down', true, false),

        -- ── 进料批次(1b-1)────────────────────────────────────────────────────────────────────────────
        -- 批次自己的:金属含量 · 化验与化验的金属 · 安全状态 · 价格 · 收货定价申请与它的审批 · 预付款核销 · 条款承诺 ·
        --   库存流水 · 盘点行与盘点的每一次清点 · 加工投入 · 成本分摊 · 销毁证书与签发 · 仓库申请(注销、证书作废)与它的审批 ·
        --   运费分摊 · 付款核销 · 财务附件
        ('inbound_batch',  1, 'inbound_batch_metals',              'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  2, 'assay_results',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  3, 'assay_result_metals',               'assay_results',               'assay_result_id',  '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  4, 'inbound_batch_safety_states',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  5, 'price_history',                     'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  6, 'receipt_price_requests',            'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  7, 'approval_log',                      'receipt_price_requests',      'subject_id',       '{"subject_type": "receipt_price_request"}'::jsonb, 'down', true, true),
        ('inbound_batch',  8, 'prepayment_applications',           'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch',  9, 'pricing_term_commitments',          'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 10, 'pricing_term_commitment_metals',    'pricing_term_commitments',    'commitment_id',    '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 11, 'inventory_movements',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 12, 'stocktake_lines',                   'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 13, 'stocktake_counts',                  'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 14, 'processing_inputs',                 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 15, 'batch_processing_cost_allocations', 'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 16, 'certificates_of_destruction',       'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 17, 'cod_issues',                        'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  true),
        ('inbound_batch', 18, 'warehouse_requests',                'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 19, 'warehouse_requests',                'certificates_of_destruction', 'cod_id',           '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 20, 'approval_log',                      'warehouse_requests',          'subject_id',       '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('inbound_batch', 21, 'freight_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 22, 'payment_allocations',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 23, 'finance_attachments',               'inbound_batches',             'inbound_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4),只取碰到这个批次的那些事:
        --   它收货的采购单 → 那张单的审批与修改史(旧 approval / po_change 两支)
        ('inbound_batch', 24, 'purchase_orders',                   'inbound_batches',             'purchase_order_id', '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 25, 'approval_log',                      'purchase_orders',             'subject_id',        '{"subject_type": "purchase_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 26, 'purchase_order_history',            'purchase_orders',             'purchase_order_id', '{}'::jsonb, 'down', true,  false),
        --   消耗它的加工单 → 那张单的成本修改史、成本条目(垫脚石)、工单(垫脚石)→ 工单的审批与修改史
        ('inbound_batch', 27, 'processing_runs',                   'processing_inputs',           'run_id',            '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 28, 'processing_cost_entry_history',     'processing_runs',             'run_id',            '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 29, 'processing_cost_entries',           'processing_runs',             'run_id',            '{}'::jsonb, 'down', false, false),
        ('inbound_batch', 30, 'work_orders',                       'processing_runs',             'work_order_id',     '{}'::jsonb, 'up',  false, false),
        ('inbound_batch', 31, 'approval_log',                      'work_orders',                 'subject_id',        '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('inbound_batch', 32, 'work_order_history',                'work_orders',                 'work_order_id',     '{}'::jsonb, 'down', true,  false),
        --   盘点过它的那一次盘点(垫脚石)→ 那次盘点过账的分录
        ('inbound_batch', 33, 'stocktakes',                        'stocktake_lines',             'stocktake_id',      '{}'::jsonb, 'up',  false, false),
        --   分录:直接挂在批次上的(计价、注销)· 预付款核销的 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('inbound_batch', 34, 'journal_entries',                   'inbound_batches',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 35, 'journal_entries',                   'prepayment_applications',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 36, 'journal_entries',                   'processing_cost_entries',     'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 37, 'journal_entries',                   'processing_runs',             'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 38, 'journal_entries',                   'stocktakes',                  'source_id',         '{}'::jsonb, 'down', true,  false),
        ('inbound_batch', 39, 'journal_entries',                   'journal_entries',             'reversed_by',       '{}'::jsonb, 'up',  true,  false),

        -- ── 产出批次(1b-1)────────────────────────────────────────────────────────────────────────────
        ('output_batch',  1, 'output_batch_metals',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  2, 'assay_results',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  3, 'assay_result_metals',               'assay_results',      'assay_result_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  4, 'output_batch_safety_states',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  5, 'inventory_movements',               'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch',  6, 'processing_outputs',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  7, 'processing_inputs',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  8, 'stocktake_lines',                   'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch',  9, 'stocktake_counts',                  'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 10, 'warehouse_requests',                'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 11, 'approval_log',                      'warehouse_requests', 'subject_id',      '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, false),
        ('output_batch', 12, 'sales_records',                     'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 13, 'sales_record_movements',            'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 14, 'sales_attribution_log',             'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 15, 'invoice_lines',                     'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 16, 'payment_allocations',               'sales_records',      'sales_record_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 17, 'sales_order_reservations',          'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 18, 'shipment_lines',                    'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        ('output_batch', 19, 'traceability_report_issues',        'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  true),
        ('output_batch', 20, 'sales_settlements',                 'output_batches',     'output_batch_id', '{}'::jsonb, 'down', true,  false),
        -- 往上一跳(M4 · Q4):产出它 / 消耗它的加工单 → 成本修改史、成本条目(垫脚石)、工单 → 审批与修改史;
        --   盘点过它的盘点(垫脚石);它的销售对应的订单行(垫脚石)→ 那一行的订单修改史(旧 so_change 一支)
        ('output_batch', 21, 'processing_runs',                   'processing_outputs', 'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 22, 'processing_runs',                   'processing_inputs',  'run_id',              '{}'::jsonb, 'up',  false, false),
        ('output_batch', 23, 'processing_cost_entry_history',     'processing_runs',    'run_id',              '{}'::jsonb, 'down', true,  false),
        ('output_batch', 24, 'processing_cost_entries',           'processing_runs',    'run_id',              '{}'::jsonb, 'down', false, false),
        ('output_batch', 25, 'work_orders',                       'processing_runs',    'work_order_id',       '{}'::jsonb, 'up',  false, false),
        ('output_batch', 26, 'approval_log',                      'work_orders',        'subject_id',          '{"subject_type": "work_order"}'::jsonb, 'down', true, false),
        ('output_batch', 27, 'work_order_history',                'work_orders',        'work_order_id',       '{}'::jsonb, 'down', true,  false),
        ('output_batch', 28, 'stocktakes',                        'stocktake_lines',    'stocktake_id',        '{}'::jsonb, 'up',  false, false),
        ('output_batch', 29, 'sales_order_lines',                 'sales_records',      'sales_order_line_id', '{}'::jsonb, 'up',  false, false),
        ('output_batch', 30, 'sales_order_history',               'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true,  false),
        --   分录:注销(直接挂在批次上)· 销售与发货的成本 · 加工成本条目的 · 加工单成本分摊的 · 盘点的 · 以及它们的冲销
        ('output_batch', 31, 'journal_entries',                   'output_batches',     'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 32, 'journal_entries',                   'sales_records',      'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 33, 'journal_entries',                   'processing_cost_entries', 'source_id',      '{}'::jsonb, 'down', true,  false),
        ('output_batch', 34, 'journal_entries',                   'processing_runs',    'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 35, 'journal_entries',                   'stocktakes',         'source_id',           '{}'::jsonb, 'down', true,  false),
        ('output_batch', 36, 'journal_entries',                   'journal_entries',    'reversed_by',         '{}'::jsonb, 'up',  true,  false),

        -- ── 工单(1b-1):明细 · 预期产出 · 修改史 · 放行审批 ─────────────────────────────────────────────
        ('work_order', 1, 'work_order_lines',            'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 2, 'work_order_expected_outputs', 'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 3, 'work_order_history',          'work_orders', 'work_order_id', '{}'::jsonb, 'down', true, true),
        ('work_order', 4, 'approval_log',                'work_orders', 'subject_id',    '{"subject_type": "work_order"}'::jsonb, 'down', true, true),

        -- ── 盘点(1b-1):盘点行 · 每一次清点 · 过账审批 · 过账分录(财务读)─────────────────────────────────
        ('stocktake', 1, 'stocktake_lines',  'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 2, 'stocktake_counts', 'stocktakes', 'stocktake_id', '{}'::jsonb, 'down', true, true),
        ('stocktake', 3, 'approval_log',     'stocktakes', 'subject_id',   '{"subject_type": "stocktake"}'::jsonb, 'down', true, true),
        ('stocktake', 4, 'journal_entries',  'stocktakes', 'source_id',    '{"source_type": "stocktake"}'::jsonb, 'down', true, false),

        -- ── 设备(1b-1,Q22):保养维修 · 停机 · 保养周期 · 交接班里提到的那次停机 ────────────────────────────
        ('equipment', 1, 'equipment_maintenance',         'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 2, 'equipment_downtime',            'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 3, 'equipment_service_intervals',   'fixed_assets',       'equipment_id', '{}'::jsonb, 'down', true, true),
        ('equipment', 4, 'shift_handover_equipment_refs', 'equipment_downtime', 'downtime_id',  '{}'::jsonb, 'down', true, false),

        -- ── 交接班(1b-1,Q23):交接事项 · 提到的停机 ───────────────────────────────────────────────────
        ('shift_handover', 1, 'shift_handover_items',          'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),
        ('shift_handover', 2, 'shift_handover_equipment_refs', 'shift_handovers', 'handover_id', '{}'::jsonb, 'down', true, true),

        -- ── 仓库申请(1b-1,Q12):/inventory 那一块 —— 申请本身与它的审批 ─────────────────────────────────
        ('warehouse_request', 1, 'approval_log', 'warehouse_requests', 'subject_id', '{"subject_type": "warehouse_request"}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1b-2(Tim 2026-09-29,AT-1b Step 0 §a)· 商务:报价、订单、发货、客户、佣金、供应商、物流 ══
        -- ── 报价:明细(硬删的行从影像里找)· 签发档 · 事件史 ─────────────────────────────────────────
        ('quote', 1, 'quote_lines',  'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 2, 'qt_issues',    'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        ('quote', 3, 'quote_history', 'quotes', 'quote_id', '{}'::jsonb, 'down', true, true),
        -- ── 销售订单:明细 · 明细的预留 · 发货放行与它的明细、审批 · 签发档 · 事件史 · 合同条款 ──────────────
        --   ★ 预留、发货单明细、订单事件史以前挂在产出批次下面(home = false);它们的【家】是这张订单 / 这张发货单,
        --     所以 /settings/change-history 的 Record 一栏从此指向订单 / 发货单(trail_row_record 只沿 home 走)。
        ('sales_order', 1, 'sales_order_lines',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 2, 'sales_order_reservations', 'sales_order_lines',  'sales_order_line_id', '{}'::jsonb, 'down', true, true),
        ('sales_order', 3, 'shipping_releases',        'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 4, 'shipping_release_lines',   'shipping_releases',  'release_id',          '{}'::jsonb, 'down', true, true),
        ('sales_order', 5, 'approval_log',             'shipping_releases',  'subject_id',          '{"subject_type": "shipping_release"}'::jsonb, 'down', true, true),
        ('sales_order', 6, 'so_issues',                'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 7, 'sales_order_history',      'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        ('sales_order', 8, 'contract_document_terms',  'sales_orders',       'sales_order_id',      '{}'::jsonb, 'down', true, true),
        -- ── 发货单(M1:销售或发货的人都读得到):明细 · 送货单签发档 ─────────────────────────────────────
        ('shipment', 1, 'shipment_lines',  'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        ('shipment', 2, 'shipment_issues', 'shipments', 'shipment_id', '{}'::jsonb, 'down', true, true),
        -- ── 客户:联系人 · 附件 · 信用史 · 对账单与它的签发档 · 催收与它挂的单据、承诺
        --   (后四张只给财务读 —— 读不了的人那几行是 Restricted,Q4)────────────────────────────────────
        ('customer', 1, 'counterparty_contacts',      'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 2, 'customer_attachments',       'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 3, 'customer_credit_history',    'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 4, 'customer_statements',        'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 5, 'statement_issues',           'customer_statements', 'statement_id', '{}'::jsonb, 'down', true, true),
        ('customer', 6, 'collection_chases',          'customers',           'customer_id',  '{}'::jsonb, 'down', true, true),
        ('customer', 7, 'collection_chase_documents', 'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        ('customer', 8, 'collection_promises',        'collection_chases',   'chase_id',     '{}'::jsonb, 'down', true, true),
        -- ── 供应商:合规证书 · 附件 · 联系人 · 状态变动史 · 审批(送审、批准、驳回)────────────────────────
        ('supplier', 1, 'supplier_compliance',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 2, 'supplier_attachments',    'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 3, 'counterparty_contacts',   'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 4, 'supplier_status_history', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('supplier', 5, 'approval_log',            'suppliers', 'subject_id',  '{"subject_type": "supplier"}'::jsonb, 'down', true, true),
        -- ── 集装箱:里程碑 · 单据清单 ────────────────────────────────────────────────────────────────
        ('container', 1, 'container_milestones', 'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        ('container', 2, 'container_documents',  'containers', 'container_id', '{}'::jsonb, 'down', true, true),
        -- ── 货代(M3):物流属性(一家一行,主键就是 supplier_id)· 按航段的报价 ──────────────────────────────
        ('forwarder', 1, 'forwarder_details',     'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        ('forwarder', 2, 'forwarder_rate_quotes', 'suppliers', 'supplier_id', '{}'::jsonb, 'down', true, true),
        -- ── 航段:它的单据清单;港口:从它出发、到它为止的航段(两个外键,两行)──────────────────────────────
        ('lane', 1, 'lane_document_requirements', 'lanes', 'lane_id',             '{}'::jsonb, 'down', true, true),
        ('port', 1, 'lanes',                      'ports', 'origin_port_id',      '{}'::jsonb, 'down', true, false),
        ('port', 2, 'lanes',                      'ports', 'destination_port_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1b-3(Tim 2026-09-29,AT-1b Step 0 §a)· 主数据与工具:物料、库位、金属价格、公式、任务 ══
        -- ── 物料:附件 · 必须化验的金属(复合主键,叶子)───────────────────────────────────────────────
        ('material', 1, 'material_attachments',     'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        ('material', 2, 'material_required_metals', 'materials', 'material_id', '{}'::jsonb, 'down', true, true),
        -- ── 库位:允许存放的废物分类(Q13:保存只改变动的那几条,一次调用 —— save_storage_location)──────────
        ('storage_location', 1, 'storage_location_allowed_classes', 'storage_locations', 'location_id', '{}'::jsonb, 'down', true, true),
        -- ── 公式:应付金属(叶子)· 修改史 · 条款申请(只给持价格码的人读,别人那一行是 Restricted,Q4)· 申请的审批 ────
        ('pricing_formula', 1, 'pricing_formula_metals',  'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 2, 'pricing_formula_history', 'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 3, 'terms_requests',          'pricing_formulas', 'formula_id', '{}'::jsonb, 'down', true, true),
        ('pricing_formula', 4, 'approval_log',            'terms_requests',   'subject_id', '{"subject_type": "terms_request"}'::jsonb, 'down', true, true),
        -- ── 任务(Q3:私人任务也是):步骤 · 参与者 · 修改史(三张表的人都是员工 id,M2)─────────────────────
        ('task', 1, 'task_nodes',        'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 2, 'task_participants', 'tasks', 'task_id', '{}'::jsonb, 'down', true, true),
        ('task', 3, 'task_history',      'tasks', 'task_id', '{}'::jsonb, 'down', true, true),

        -- ══ AUDIT-TRAIL-1c-1(Tim 2026-10-03,AT-1c Step 0 §a)· 账上的单据 ══════════════════════════════════
        -- 冲销分录的 source_id 指的是【原分录】(reverse_journal_entry_internal),不是原单据 —— 所以一张单据够到它的冲销,
        --   只走原分录的 reversed_by(往上一跳,M4;批次 ord 39 的同一个做法),绝不按 source_id = 单据 id 去找。
        -- 一张冲销分录的行【不】挂在原分录上(Q33):行(ord 1)排在冲销(ord 2)之前展开,所以只取到根分录自己的行。
        -- ── 分录:行 · 它的冲销(往上)· 它冲的那一张(往下,在冲销分录的页上)· 申请(人工分录 / 冲销)与申请的审批 ──
        ('journal_entry', 1, 'journal_lines',    'journal_entries',  'entry_id',                '{}'::jsonb, 'down', true, true),
        ('journal_entry', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('journal_entry', 3, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'down', true, false),
        ('journal_entry', 4, 'journal_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('journal_entry', 5, 'journal_requests', 'journal_entries',  'target_entry_id',         '{}'::jsonb, 'down', true, false),
        ('journal_entry', 6, 'approval_log',     'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, false),
        -- AUDIT-TRAIL-1c-3:一次折旧的分录带着它记到每一张资产卡上的那一行(/finance/assets 的折旧批次一块读这张分录;
        --   家仍是资产那一页 —— 每一张资产卡自己也有它那一行,Step 0 §a)
        ('journal_entry', 7, 'fixed_asset_depreciation', 'journal_entries', 'journal_entry_id', '{}'::jsonb, 'down', true, false),
        -- ── 发票:行 · 签发档 · 作废 / 贷项申请与它的审批 · 由它开出的贷项通知 · 核销它的收款 · 它的分录与冲销 ──────
        ('invoice', 1, 'invoice_lines',    'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 2, 'invoice_issues',   'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 3, 'invoice_requests', 'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, true),
        ('invoice', 4, 'approval_log',     'invoice_requests', 'subject_id',              '{"subject_type": "invoice_request"}'::jsonb, 'down', true, true),
        ('invoice', 5, 'credit_notes',     'invoices',         'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 6, 'payment_allocations', 'invoices',      'invoice_id',              '{}'::jsonb, 'down', true, false),
        ('invoice', 7, 'journal_entries',  'invoices',         'entry_id',                '{}'::jsonb, 'up',   true, false),
        ('invoice', 8, 'journal_entries',  'invoice_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        ('invoice', 9, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        -- ── 贷项通知:行 · 签发档 · 开出它的那张申请与审批 · 它的分录 ──────────────────────────────────────────
        ('credit_note', 1, 'credit_note_lines', 'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 2, 'cn_issues',         'credit_notes',     'credit_note_id',        '{}'::jsonb, 'down', true, true),
        ('credit_note', 3, 'invoice_requests',  'credit_notes',     'result_credit_note_id', '{}'::jsonb, 'down', true, false),
        ('credit_note', 4, 'approval_log',      'invoice_requests', 'subject_id',            '{"subject_type": "invoice_request"}'::jsonb, 'down', true, false),
        ('credit_note', 5, 'journal_entries',   'credit_notes',     'entry_id',              '{}'::jsonb, 'up',   true, false),
        -- ── 收付款:核销行 · 附件 · 冲销它的那一笔(往上)/ 它冲的那一笔(往下,在镜像单上)· 付出它的申请 · 冲它的申请 ·
        --    申请的审批 · 它的分录与冲销 ────────────────────────────────────────────────────────────────────────
        ('payment', 1, 'payment_allocations', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, true),
        ('payment', 2, 'finance_attachments', 'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 3, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'up',   true, false),
        ('payment', 4, 'payments',            'payments',         'reversed_by_payment', '{}'::jsonb, 'down', true, false),
        ('payment', 5, 'payment_requests',    'payments',         'result_payment_id',   '{}'::jsonb, 'down', true, false),
        ('payment', 6, 'payment_requests',    'payments',         'payment_id',          '{}'::jsonb, 'down', true, false),
        ('payment', 7, 'approval_log',        'payment_requests', 'subject_id',          '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        ('payment', 8, 'journal_entries',     'payments',         'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('payment', 9, 'journal_entries',     'journal_entries',  'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 付款申请(六种:付款 · 付款冲销 · 行内转账 · 转账冲销 · 代扣税缴纳 · 缴纳冲销):审批 · 付出的那一笔 ·
        --    被冲的那一笔(垫脚石:它自己的事不是这张申请的)· 转账 · 缴纳 · 过账的分录与冲销 ──────────────────
        --    ★ 一张"代扣税缴纳"申请没有指向它造出的那一笔缴纳的外键(形状检查让 wht_remittance_id 在这一种上恒为空)——
        --      唯一的路是 申请 → result_journal_entry_id → wht_remittances.journal_entry_id(ord 8)。
        ('payment_request',  1, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, true),
        ('payment_request',  2, 'payments',         'payment_requests', 'result_payment_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  3, 'payments',         'payment_requests', 'payment_id',              '{}'::jsonb, 'up',   false, false),
        ('payment_request',  4, 'bank_transfers',   'payment_requests', 'result_transfer_id',      '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  5, 'bank_transfers',   'payment_requests', 'transfer_id',             '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  6, 'wht_remittances',  'payment_requests', 'wht_remittance_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  7, 'journal_entries',  'payment_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true,  false),
        ('payment_request',  8, 'wht_remittances',  'journal_entries',  'journal_entry_id',        '{}'::jsonb, 'down', true,  false),
        ('payment_request',  9, 'journal_entries',  'bank_transfers',   'reversal_entry_id',       '{}'::jsonb, 'up',   true,  false),
        ('payment_request', 10, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true,  false),
        -- ── 费用 / 供应商账单:核销行 · 附件 · 定金冲抵 · 冲销它的那一张(往上)/ 它冲的那一张(往下)· 报销单与它的审批 ·
        --    资本化进资产的那一笔成本 · 它的分录 · 定金冲抵的分录 · 冲销 ────────────────────────────────────────
        ('expense',  1, 'payment_allocations',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  2, 'finance_attachments',      'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  3, 'prepayment_applications',  'expenses',                'expense_id',          '{}'::jsonb, 'down', true, true),
        ('expense',  4, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('expense',  5, 'expenses',                 'expenses',                'reversed_by_expense', '{}'::jsonb, 'down', true, false),
        ('expense',  6, 'expense_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  7, 'approval_log',             'expense_claims',          'subject_id',          '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('expense',  8, 'fixed_asset_cost_entries', 'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        ('expense',  9, 'journal_entries',          'expenses',                'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('expense', 10, 'journal_entries',          'prepayment_applications', 'source_id',           '{}'::jsonb, 'down', true, false),
        ('expense', 11, 'journal_entries',          'journal_entries',         'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- AUDIT-TRAIL-1d-2(Q37):医疗报销付款时建的那张费用单 —— 费用页够得到是哪一张报销单让它生出来的(家仍在报销单那一页)
        ('expense', 12, 'medical_claims',           'expenses',                'expense_id',          '{}'::jsonb, 'down', true, false),
        -- ── 应付(Q5,M3 · M6):只有钱的那几样 —— 核销 · 运费分摊 · 定金冲抵 · 财务附件 · 价格 · 计价 / 注销 / 定金的分录与冲销 ──
        ('payable', 1, 'payment_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 2, 'freight_allocations',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 3, 'prepayment_applications', 'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 4, 'finance_attachments',     'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 5, 'price_history',           'inbound_batches',         'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('payable', 6, 'journal_entries',         'inbound_batches',         'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 7, 'journal_entries',         'prepayment_applications', 'source_id',        '{}'::jsonb, 'down', true, false),
        ('payable', 8, 'journal_entries',         'journal_entries',         'reversed_by',      '{}'::jsonb, 'up',   true, false),

        -- ══ AUDIT-TRAIL-1c-2(Tim 2026-10-03,AT-1c Step 0 §a)· 其余的单据与合同 ══════════════════════════════════
        -- ── 销售(Q14):出库 · 归属客户 · 开票的那一行 · 收款核销 · 附件 · 收入 / 成本分录与它们的冲销 ─────────────────
        --    ★ 销售自己是一个主语的根了 —— /settings/change-history 的 Record 一栏把销售那一行与它的子行归到【这一笔销售】
        --      (以前归到产出批次:产出批次 ord 12 的 home 改成 false,于是从子行往上走到销售就停下)
        ('sale', 1, 'sales_record_movements', 'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 2, 'sales_attribution_log',  'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 3, 'invoice_lines',          'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 4, 'payment_allocations',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, false),
        ('sale', 5, 'finance_attachments',    'sales_records',   'sales_record_id', '{}'::jsonb, 'down', true, true),
        ('sale', 6, 'journal_entries',        'sales_records',   'source_id',       '{"source_type": "sale"}'::jsonb, 'down', true, false),
        ('sale', 7, 'journal_entries',        'sales_records',   'cogs_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('sale', 8, 'journal_entries',        'journal_entries', 'reversed_by',     '{}'::jsonb, 'up',   true, false),
        -- ── 运费单:分摊到的批次(家在这里 —— 它是这张单分出去的)· 付它的核销 · 过账分录 · 冲销分录 ───────────────────
        ('freight', 1, 'freight_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, true),
        ('freight', 2, 'payment_allocations', 'freight_documents', 'freight_document_id', '{}'::jsonb, 'down', true, false),
        ('freight', 3, 'journal_entries',     'freight_documents', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('freight', 4, 'journal_entries',     'freight_documents', 'reversal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('freight', 5, 'journal_entries',     'journal_entries',   'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 资产(财务那一页,Q10):资产卡的修改史 · 成本 · 折旧与折旧基点 · 处置申请与它的审批 · 处置 / 折旧的分录 ·
        --    保养维修、停机、保养间隔(家仍是 equipment —— 加工那一页)─────────────────────────────────────────────
        ('fixed_asset',  1, 'fixed_asset_history',              'fixed_assets',             'fixed_asset_id',      '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  2, 'fixed_asset_cost_entries',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  3, 'fixed_asset_depreciation',         'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  4, 'fixed_asset_depreciation_anchors', 'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  5, 'asset_disposal_requests',          'fixed_assets',             'asset_id',            '{}'::jsonb, 'down', true, true),
        ('fixed_asset',  6, 'approval_log',                     'asset_disposal_requests',  'subject_id',          '{"subject_type": "asset_disposal_request"}'::jsonb, 'down', true, true),
        ('fixed_asset',  7, 'equipment_maintenance',            'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  8, 'equipment_downtime',               'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset',  9, 'equipment_service_intervals',      'fixed_assets',             'equipment_id',        '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 10, 'shift_handover_equipment_refs',    'equipment_downtime',       'downtime_id',         '{}'::jsonb, 'down', true, false),
        ('fixed_asset', 11, 'journal_entries',                  'fixed_assets',             'disposal_journal_id', '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 12, 'journal_entries',                  'fixed_asset_depreciation', 'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('fixed_asset', 13, 'journal_entries',                  'journal_entries',          'reversed_by',         '{}'::jsonb, 'up',   true, false),
        -- ── 对账单:行与每一行的匹配 · 对账记录与它写明的差额 ────────────────────────────────────────────────────
        ('bank_statement', 1, 'bank_statement_lines',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 2, 'bank_line_matches',                  'bank_statement_lines', 'statement_line_id', '{}'::jsonb, 'down', true, true),
        ('bank_statement', 3, 'bank_reconciliations',               'bank_statements',      'statement_id',      '{}'::jsonb, 'down', true, true),
        ('bank_statement', 4, 'bank_reconciliation_variance_items', 'bank_reconciliations', 'reconciliation_id', '{}'::jsonb, 'down', true, true),
        -- ── GST 期间:申报那一刻抄下来的每一格 · 申报申请与它的审批。★ Q22:更正期间【不】挂在原期间上(那样更正件之后的
        --    每一次改动都会出现在原件上);更正件自己的记录以"为 GST-… 开的更正"开头,原件页上那一条链接照旧 ──────────────
        ('gst_period', 1, 'gst_return_boxes',    'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 2, 'gst_filing_requests', 'gst_periods',         'period_id',  '{}'::jsonb, 'down', true, true),
        ('gst_period', 3, 'approval_log',        'gst_filing_requests', 'subject_id', '{"subject_type": "gst_filing_request"}'::jsonb, 'down', true, true),
        -- ── 汇率:它的修改史(录入 · 更正 · 撤回 —— 一件事两行:记录开始之后变更记录那一行说,之前修改史那一行说)──────
        ('fx_rate', 1, 'fx_rate_history', 'fx_rates', 'fx_rate_id', '{}'::jsonb, 'down', true, true),
        -- ── 管理包:没有成员(一份新包取代旧包时,旧包自己那几列说"被谁取代";不经 superseded_by 自连 —— 那会把前一份的
        --    整段历史拉到这一份上)
        -- ── 合同:七张条款表 · 它的申请(生效)与申请的审批(没有 pricing.view 的读者那几行是 Restricted,Q21)·
        --    把它挂到采购单 / 销售订单上的那一份快照(家仍在那张订单上)────────────────────────────────────────────
        ('contract',  1, 'contract_grade_specs',           'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  2, 'contract_insurance_obligations', 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  3, 'contract_volume_commitments',    'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  4, 'contract_pricing_terms',         'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  5, 'contract_settlement_terms',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  6, 'contract_refining_charges',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  7, 'contract_penalty_elements',      'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  8, 'terms_requests',                 'contracts',      'contract_id', '{}'::jsonb, 'down', true, true),
        ('contract',  9, 'approval_log',                   'terms_requests', 'subject_id',  '{"subject_type": "terms_request"}'::jsonb, 'down', true, false),
        ('contract', 10, 'contract_document_terms',        'contracts',      'contract_id', '{}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1c-3(Tim 2026-10-03,AT-1c Step 0 §a)· 期末、设置与清单页上的记录 ══════════════════════════
        -- ── 锁期(Q25 · Q3 · M7):月结 / 反结的 period_closes 与 finance_settings 之间一个键都没有 —— 整张表属于那一行。
        --    关账在同一笔里写 period_closes 一行、把锁往后挪;反结在同一笔里给那一行盖反结的戳、把锁往回挪 —— 各是一条
        ('finance_lock', 1, 'period_closes', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 年结:结转分录(往上)· 反结的冲销分录(往上)──────────────────────────────────────────────────
        ('year_close', 1, 'journal_entries', 'year_closes', 'closing_journal_id',  '{}'::jsonb, 'up', true, false),
        ('year_close', 2, 'journal_entries', 'year_closes', 'reversal_journal_id', '{}'::jsonb, 'up', true, false),
        -- ── 人工分录 / 冲销申请(Q17):它的审批(家在这里 —— 一张还没批的申请没有分录,它唯一的家是它自己)· 过账的那一张 ──
        ('journal_request', 1, 'approval_log',    'journal_requests', 'subject_id',              '{"subject_type": "journal_request"}'::jsonb, 'down', true, true),
        ('journal_request', 2, 'journal_entries', 'journal_requests', 'result_journal_entry_id', '{}'::jsonb, 'up',   true, false),
        -- ── 报销单(Q20):审批 · 收据(附件)· 批准时记下的那张费用单(往上)。/me 上报销人自己读同样的几张(M8)──────
        ('expense_claim',    1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, true),
        ('expense_claim',    2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, true),
        ('expense_claim',    3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        ('my_expense_claim', 1, 'approval_log',        'expense_claims', 'subject_id', '{"subject_type": "expense_claim"}'::jsonb, 'down', true, false),
        ('my_expense_claim', 2, 'finance_attachments', 'expense_claims', 'claim_id',   '{}'::jsonb, 'down', true, false),
        ('my_expense_claim', 3, 'expenses',            'expense_claims', 'expense_id', '{}'::jsonb, 'up',   true, false),
        -- ── 行内转账:过账分录 · 冲销分录(往上)· 付出它 / 冲它的申请(往下,两把外键 —— 港口的先例)与申请的审批 ──
        ('bank_transfer', 1, 'journal_entries',  'bank_transfers',   'journal_entry_id',   '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 2, 'journal_entries',  'bank_transfers',   'reversal_entry_id',  '{}'::jsonb, 'up',   true, false),
        ('bank_transfer', 3, 'payment_requests', 'bank_transfers',   'result_transfer_id', '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 4, 'payment_requests', 'bank_transfers',   'transfer_id',        '{}'::jsonb, 'down', true, false),
        ('bank_transfer', 5, 'approval_log',     'payment_requests', 'subject_id',         '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),
        -- ── 代扣税缴纳(Q30):它的分录 · 冲销那一张(经原分录的 reversed_by,往上)· 冲它的申请(wht_remittance_id)·
        --    付出它的申请(那种申请没有指向缴纳的外键 —— 只能经分录:payment_requests.result_journal_entry_id,往下)· 审批 ──
        ('wht_remittance', 1, 'journal_entries',  'wht_remittances',  'journal_entry_id',        '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 2, 'journal_entries',  'journal_entries',  'reversed_by',             '{}'::jsonb, 'up',   true, false),
        ('wht_remittance', 3, 'payment_requests', 'wht_remittances',  'wht_remittance_id',       '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 4, 'payment_requests', 'journal_entries',  'result_journal_entry_id', '{}'::jsonb, 'down', true, false),
        ('wht_remittance', 5, 'approval_log',     'payment_requests', 'subject_id',              '{"subject_type": "payment_request"}'::jsonb, 'down', true, false),

        -- ══ AUDIT-TRAIL-1d-1(Tim 2026-10-04,AT-1d Step 0 §a · §d · §e)· 机制、设置与员工 ══════════════════════════════
        -- ── 账号(M9,Q24):授给它的角色(家在这里,Q22)· 它作为附加账号挂在谁身上 · 那张挂接史 · 它是谁的主账号
        --    (employees.user_id —— M10 只取那一列:那名员工别的每一次编辑不是账号的事)──────────────────────────────
        ('account', 1, 'user_roles',               'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 2, 'employee_accounts',        'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 3, 'employee_account_history', 'auth.users', 'user_id', '{}'::jsonb, 'down', true, true),
        ('account', 4, 'employees',                'auth.users', 'user_id', '{}'::jsonb, 'down', true, false),
        -- ── 审批方针(M7 · Q25):修改史整张属于那一行设置(两张表之间没有键 —— 锁期 / period_closes 的同一个做法)──────────
        ('approval_policy', 1, 'finance_settings_history', 'finance_settings', NULL, '{}'::jsonb, 'all', true, true),
        -- ── 员工(Q28):任职履历 · 调薪申请与它的审批(只给 view_pay 的人读,别人那几行是 Restricted)· 培训(家在培训那一页,Q29)·
        --    附加账号与它的挂接史 · 账号的镜像(Q24 · Q21):主账号与附加账号(往上一跳到 auth.users,M9)与授给它们的角色 ——
        --    每一行照它自己的读规则:授权人人读得到,账号事件与挂接史只给 manage_permissions,别人是 Restricted ────────────────
        ('employee', 1, 'employment_history',       'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 2, 'salary_change_requests',   'employees',              'employee_id', '{}'::jsonb, 'down', true, true),
        ('employee', 3, 'approval_log',             'salary_change_requests', 'subject_id',  '{"subject_type": "salary_change_request"}'::jsonb, 'down', true, true),
        ('employee', 4, 'training_records',         'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 5, 'employee_accounts',        'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 6, 'employee_account_history', 'employees',              'employee_id', '{}'::jsonb, 'down', true, false),
        ('employee', 7, 'auth.users',               'employees',              'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 8, 'auth.users',               'employee_accounts',      'user_id',     '{}'::jsonb, 'up',   true, false),
        ('employee', 9, 'user_roles',               'auth.users',             'user_id',     '{}'::jsonb, 'down', true, false),
        -- ── 部门 · 培训记录 · 导入批次:没有成员。六本字典:M11 集合,没有成员 ──────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-2(Tim 2026-10-04,AT-1d Step 0 §a)· 请假与考勤 ══════════════════════════════════════════
        -- ── 请假:消耗账(批准时扣、取消时还 —— 家在这里)· 审批 ─────────────────────────────────────────────
        --    /me 上本人读同样的两张(M8);两张的读规则都只给 hr.view,所以本人看到的是 Restricted(Q4 · Q14)
        ('leave_request',    1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, true),
        ('leave_request',    2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, true),
        ('my_leave_request', 1, 'leave_consumption', 'leave_requests', 'leave_request_id', '{}'::jsonb, 'down', true, false),
        ('my_leave_request', 2, 'approval_log',      'leave_requests', 'subject_id',       '{"subject_type": "leave_request"}'::jsonb, 'down', true, false),
        -- ── 医疗报销:审批 · 付它的那张费用单(往上,M4)· 费用的分录 · 核销 · 冲销它的费用单与分录(只给财务,别人 Restricted)──
        ('medical_claim',    1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, true),
        ('medical_claim',    2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('medical_claim',    5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('medical_claim',    6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 1, 'approval_log',        'medical_claims', 'subject_id',          '{"subject_type": "medical_claim"}'::jsonb, 'down', true, false),
        ('my_medical_claim', 2, 'expenses',            'medical_claims', 'expense_id',          '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 3, 'journal_entries',     'expenses',       'journal_entry_id',    '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 4, 'payment_allocations', 'expenses',       'expense_id',          '{}'::jsonb, 'down', true, false),
        ('my_medical_claim', 5, 'expenses',            'expenses',       'reversed_by_expense', '{}'::jsonb, 'up',   true, false),
        ('my_medical_claim', 6, 'journal_entries',     'journal_entries', 'reversed_by',        '{}'::jsonb, 'up',   true, false),
        -- ── 加班:行(删掉的行从 DELETE 的影像里找)· 审批(送审 · 批准 · 退回)──────────────────────────────────
        ('overtime_batch',   1, 'overtime_lines',      'overtime_batches', 'batch_id',          '{}'::jsonb, 'down', true, true),
        ('overtime_batch',   2, 'approval_log',        'overtime_batches', 'subject_id',        '{"subject_type": "overtime_batch"}'::jsonb, 'down', true, true),
        -- ── 考勤:每人一行(开月 · 补新人 · 记录 · 完成时冻住的那几列 —— 完成那一下的整批改动在界面上是一句)──────────
        ('attendance_period', 1, 'attendance_lines',   'attendance_periods', 'period_id',       '{}'::jsonb, 'down', true, true),
        -- ── 假期发放(清单块)· 假别 · 公共假期(M11 集合):没有成员 ──────────────────────────────────────────

        -- ══ AUDIT-TRAIL-1d-3(Tim 2026-10-04,AT-1d Step 0 §a)· 工资与评审 ══════════════════════════════════════════
        -- ── 工资期:工资行(每次保存删了重插 —— 一次操作里按员工配对,Q11;家在这里)· 过账 / 撤销的申请与它们的审批 ·
        --    这一期的分录(过账 · 发薪 · CPF · 代扣款)按 source_id + source_type = 'payroll' 找 —— 【不】经 journal_entry_id
        --    往上走:撤销过账会把那一列置空(unpost_payroll_period_internal),往上一跳读的是今天的样子,过账与它的冲销会一起丢掉;
        --    source_id 撤不掉。冲销分录自己的 source_id 是原分录(1c-1),所以它经 reversed_by 往上一跳。分录只给财务(别人 Restricted)
        ('payroll_period',     1, 'payroll_lines',    'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     2, 'payroll_requests', 'payroll_periods',     'payroll_period_id', '{}'::jsonb, 'down', true, true),
        ('payroll_period',     3, 'approval_log',     'payroll_requests',    'subject_id',        '{"subject_type": "payroll_request"}'::jsonb, 'down', true, true),
        ('payroll_period',     4, 'journal_entries',  'payroll_periods',     'source_id',         '{"source_type": "payroll"}'::jsonb, 'down', true, false),
        ('payroll_period',     5, 'journal_entries',  'journal_entries',     'reversed_by',       '{}'::jsonb, 'up',   true, false),
        -- ── 评审:目标(删掉的目标从 DELETE 的影像里找)· 审批(送审 · 批准 · 本人确认;作废不写审批)──────────────────
        --    批准时改的员工那一行与任职履历【不】挂进来(Q7):它们没有指回评审的键,评审那一段按评审自己的几列说出结论
        --    /my-reviews 上审核人读同样的两张(M12);审批那几行的读规则是 hr.view,不持它的审核人看到的是 Restricted(Q5 · Q4)
        ('performance_review', 1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, true),
        ('performance_review', 2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, true),
        ('my_review',          1, 'review_goals',     'performance_reviews', 'review_id',         '{}'::jsonb, 'down', true, false),
        ('my_review',          2, 'approval_log',     'performance_reviews', 'subject_id',        '{"subject_type": "performance_review"}'::jsonb, 'down', true, false),
        -- ── MES-1:设备 —— 网关钥匙(发放与撤销;哈希被 never 规则遮住)。收件箱 · 传输日志 · 中断不进变更记录(MES-0 Q14),不在这里 ──
        ('device',             1, 'gateway_keys',     'devices',             'gateway_id',        '{}'::jsonb, 'down', true, true),
        -- ── MES-2:设备 —— 校准记录(记 · 作废;Q33)。地磅单 —— 它的称重(毛重 · 皮重 · 更正)、分出去的份、照片(传 · 撤)。
        --    草稿与确认时改过的值不挂进来:它们的读码是加工(查看),不是地磅单的门;确认队列与地磅单页上直接列它们 ──
        ('device',             2, 'instrument_calibrations', 'devices',      'device_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 1, 'weighings',        'weighbridge_tickets', 'ticket_id',         '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 2, 'weighbridge_ticket_shares', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        ('weighbridge_ticket', 3, 'weighbridge_ticket_photos', 'weighbridge_tickets', 'ticket_id', '{}'::jsonb, 'down', true, true),
        -- ── MES-3a(2026-10-06,MES-3a Step 0 Q12 · Q10):执照 —— 它每一类 NEA 废物的库存上限(给 · 改 · 拿掉)。
        --    进料批 / 产出批 —— 它进厂那一刻库存上限的判法(一批一行,只追加)。──
        ('company_licence',    1, 'licence_storage_limits', 'company_compliance', 'licence_id',  '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     40, 'receipt_ceiling_checks', 'inbound_batches',    'inbound_batch_id', '{}'::jsonb, 'down', true, true),
        ('output_batch',      37, 'receipt_ceiling_checks', 'output_batches',     'output_batch_id',  '{}'::jsonb, 'down', true, false),
        -- ── MES-3b(2026-10-07,MES-3b Step 0 Q7 · Q27):每一次印标签(印 · 补印与理由)—— 挂在它印的那样东西下面。
        --    一张表挂三个主语,只有一处是家(trail_row_record 沿 home 往上走):进料批那一支,与 receipt_ceiling_checks 同一个选法 ──
        ('inbound_batch',     41, 'label_prints',           'inbound_batches',    'inbound_batch_id',    '{}'::jsonb, 'down', true, true),
        ('output_batch',      38, 'label_prints',           'output_batches',     'output_batch_id',     '{}'::jsonb, 'down', true, false),
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 7 · 返回类型变了的一支:DROP 旧的、CREATE 新的(末尾三列)────────────────────────

DROP FUNCTION public.shipping_queue_rows();

-- db/functions/shipping_queue_rows.sql
-- APR-5b(2026-09-25,APR-5 grilling Q7 · 5b grilling Q6):仓库的发货队列 —— 放行过的、还没发完的订单行,
-- 连同能发的预留。【一个价格都没有】。
--
-- 【列,逐列就是 Tim 的裁定】订单编号与日期 · 客户的法定名称(常设决定 3:展示标签随单据走)·
--   ★ 送货地址(Tim 2026-09-25,5b Q6:仓库要它才发得了货 —— 常设决定 3 之下的一条【点名的例外】,
--   除此之外【不带任何别的客户属性】)· 放行时刻 · 行号、物料、单位 · 放行数量、已发、剩余 ·
--   活预留:批次、库位、数量。
--   ★ 没有:单价、币种、汇率、金额、毛利、发票编号、余额、信用额度或冻结(冻结由 ship_order 在发货时
--   按名拒 SO_SHIP_CUSTOMER_ON_HOLD —— 那是一次拒绝,不是一个读得到的属性)。
--   fixture 224 逐字钉住本函数的返回列清单。
--
-- 【哪些行】订单 confirmed / partially_shipped、未删除;这一行坐在一条被 approved 放行点名的在册发票行上
--   (覆盖,与 ship_order 同一句);剩余 = sales_order_line_releasable_all.releasable_qty − 已发 > 0。
--   一行没有活预留时照样出现(预留那几列为 NULL):仓库看得见"放行了但还没备货"。
--
-- 【门】action.ship_goods(warehouse · admin)。仓库不持 module.sales.view(Q7):属主权限读订单、客户与
--   放行,在函数体里先按调用者的码把关 —— 零行永远是"没有要发的",不会是"你看不见"。
-- ★ MES-3b(2026-10-07,MES-3b Step 0 Q13 · Q15 · Q16,Tim):末尾三列 —— dg_code(那一行物料选的 UN 编号)· dg_missing(电池料没选,
--   只提示)· quarantine_states(预留的那一批身上开着的要隔离的状态,batch_quarantine_states;标出来,不拒)。
--   这三样是【物料与批次】的属性,不是客户的 —— 上面那条"不带任何别的客户属性"一字未动。fixture 224 照新清单重钉。
-- NOTE: introduced by db/migrations/2026-09-25-apr5b-the-cfo-releases-and-the-warehouse-ships.sql.

CREATE OR REPLACE FUNCTION public.shipping_queue_rows()
 RETURNS TABLE(sales_order_id uuid, order_code text, order_date date, customer_name text, delivery_address text, released_at timestamp with time zone, sales_order_line_id uuid, line_no integer, material_code text, material_name text, unit text, released_qty numeric, shipped_qty numeric, remaining_qty numeric, reservation_id uuid, output_batch_code text, location_code text, location_name text, reserved_qty numeric, dg_code text, dg_missing boolean, quarantine_states text)
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
#variable_conflict use_column
BEGIN
    PERFORM require_permission('action.ship_goods');

    RETURN QUERY
    WITH lines AS (
        SELECT so.id AS so_id, so.code AS so_code, so.order_date AS so_date,
               c.legal_name AS cust_name, c.address AS cust_address,
               (SELECT max(r.decided_at) FROM shipping_release_lines rl
                  JOIN shipping_releases r ON r.id = rl.release_id
                 WHERE rl.sales_order_line_id = sol.id AND r.status = 'approved') AS rel_at,
               sol.id AS sol_id, sol.line_no AS sol_no, m.code AS m_code, m.name AS m_name, m.unit AS m_unit,
               m.dg_code AS m_dg, COALESCE(mk.has_condition_axes, false) AND m.dg_code IS NULL AS m_dg_missing,
               (SELECT ra.releasable_qty FROM sales_order_line_releasable_all ra
                 WHERE ra.sales_order_line_id = sol.id LIMIT 1) AS rel_qty,
               COALESCE((SELECT sum(sl.qty) FROM shipment_lines sl WHERE sl.sales_order_line_id = sol.id), 0) AS shp_qty
          FROM sales_order_lines sol
          JOIN sales_orders so ON so.id = sol.sales_order_id
          JOIN customers c ON c.id = so.customer_id
          JOIN materials m ON m.id = sol.material_id
          LEFT JOIN material_kinds mk ON mk.code = m.kind_code
         WHERE so.deleted_at IS NULL
           AND so.status IN ('confirmed', 'partially_shipped')
           AND EXISTS (SELECT 1 FROM shipping_release_lines rl
                         JOIN shipping_releases r ON r.id = rl.release_id
                         JOIN invoice_lines il ON il.id = rl.invoice_line_id
                         JOIN invoices i ON i.id = il.invoice_id
                        WHERE rl.sales_order_line_id = sol.id AND r.status = 'approved'
                          AND NOT il.invoice_voided AND i.kind = 'order' AND i.status = 'issued')
    )
    SELECT l.so_id, l.so_code, l.so_date, l.cust_name, l.cust_address, l.rel_at,
           l.sol_id, l.sol_no, l.m_code, l.m_name, l.m_unit,
           l.rel_qty, l.shp_qty, l.rel_qty - l.shp_qty,
           res.id, ob.code, loc.code, loc.name, res.qty,
           l.m_dg, l.m_dg_missing, CASE WHEN ob.id IS NOT NULL THEN batch_quarantine_states(ob.id) END
      FROM lines l
      LEFT JOIN sales_order_reservations res
             ON res.sales_order_line_id = l.sol_id AND res.released_at IS NULL AND res.consumed_at IS NULL
      LEFT JOIN output_batches ob ON ob.id = res.output_batch_id
      LEFT JOIN storage_locations loc ON loc.id = res.location_id
     WHERE l.rel_qty - l.shp_qty > 0
     ORDER BY l.rel_at, l.so_code, l.sol_no, ob.code;
END;
$function$
;

-- ── 8 · 改过的视图(镜像原样,CREATE OR REPLACE —— 列契约一字未动)──────────────────────

-- db/views/pending_values.sql
-- MES-1(2026-10-06,MES-0 §5 · Q92 · Q93;MES-1 Step 0 Q1 · Q2,Tim):【还没给的标准值】—— /settings/pending-values 读它。
--   一支一个值(像 operations_now 那样),每一支带着它自己的权限码;读者只看得到他持码的那几支(末尾的 WHERE)。
--   每一行是一件具体还空着的事:哪一个值(value_code,对应 docs/mes-pending-values.md 里那一行)、空在哪一条记录上、去哪儿填。
--   给了值,那一行就自己消失(这张视图不存任何东西)。
-- 【MES-1 播两支】
--   V5  网关的心跳间隔 —— 每一台没停用、间隔为空的网关一行。由集成商在网关调试时给(MES-0 §5.1 V5)。
--   V6  传输异常的工作时间 —— 读班次的起止时刻(shifts.starts_at / ends_at,为空是设计如此:没人说过几点到几点)。
--       每一个启用、而起止为空的班次一行。由 Tim 给(V6)。
-- 【MES-2 加两支】(2026-10-06,MES-2 Step 0 Q12 · Q30,Tim)
--   V8   校准到期前多少天开始提醒 —— 一个值,ingest_settings.calibration_lead_days 为空时一行(去处:/operation/calibration)。
--        由校准机构 / 仪器厂商给,仪器安装时(MES-0 §5.1)。没给:到期前的提醒不上牌,过期照样上牌。
--   V33  每一台【在用的】仪器(秤 · 地磅 · 电表 · 在线仪表,interface_status 不是 reserved,没停用)的量程 —— 量程为空的每台一行
--        (去处:它的设备页)。由仪器厂商给(规格 §8.2)。没给:确认读数时不判量程(WEIGHING_ABOVE_CAPACITY 只在给了时拒)。
-- 【MES-3a 加五支】(2026-10-06,MES-0 §5.1 V2 · V3 · V4 · V29;MES-3a Step 0 Q21 · Q31,Tim)
--   V2   一张执照对一类 NEA 废物的库存上限 —— 今天在效的那张执照 × 每一个启用的类别,没有 licence_storage_limits 行的一行
--        (去处:/purchasing/licences;门 module.suppliers.view)。由 NEA 执照条件给。类别列表是空的时它也是空的(V29 先来)。
--   V29  NEA 废物类别 —— 类别列表里一个启用的都没有时一行;有了之后,每一种没删、种类吃得下状态轴(电池料)而没有类别的物料一行
--        (去处:/settings/dictionaries 或那个物料;门 module.materials.view)。由 NEA 执照给。
--   V3   每一个启用的安全状态的滞留提醒天数 —— dwell_warning_days 为空的每个一行(去处:/settings/dictionaries;门 module.materials.view)。
--        由 Tim 与 WSH 负责人给,或执照的贮存条件。
--   V4   每一个启用的安全状态要不要隔离 —— requires_quarantine 为空的每个一行(同上)。引导只定了两个(鼓包或漏液 = 要,已放电 = 不要)。
--   V34  隔离库位 —— 有任何一个状态要隔离,而一个在用的隔离库位都没有时一行(去处:/inventory/locations;门 module.inventory.view)。
--        没有它,鼓包或漏液的料收不进来(QUARANTINE_LOCATION_REQUIRED)。由 Tim / 仓库在第一批这样的料到之前给。
-- 【MES-3b 加三支】(2026-10-07,MES-0 §5.1 V30 · V31;MES-3b Step 0 Q29 · V35,Tim)
--   V30  每一个启用的危险品 UN 编号的包装标记文字、包装说明、标签尺寸 —— 三样里有任何一样为空的每个编号一行
--        (去处:/settings/dictionaries;门 module.materials.view)。由有 DG 资质的货代在第一次出口之前给。
--   V31  每一种没删的电池料(种类吃得下状态轴)的 HS 编码 —— 为空的每种一行(去处:那个物料;门 module.materials.view)。
--        由报关行在第一次出口之前给。
--   V35  每一种没删的电池料的危险品 UN 编号 —— 没选的每种一行(同上)。由货代与 Tim 在第一次出口或第一次危险品发货之前给。
--        没给:标签与发货单上提示"没给",不拒(Q15)。
-- 【规矩】之后每一刀加它自己的那几支,并在【同一个提交里】往 docs/mes-pending-values.md 加它们的行(Tim,Q2)。
-- 【属主视图】读 devices / shifts 不过 RLS,所以每一支的码在末尾的 WHERE 里问一次。

CREATE OR REPLACE VIEW public.pending_values WITH (security_invoker = off) AS
 SELECT p.value_code,
    p.permission,
    p.item_id,
    p.item_code,
    p.item_label,
    p.href
   FROM ( SELECT 'V5'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = 'gateway'::text AND d.retired_at IS NULL AND d.heartbeat_interval_s IS NULL
        UNION ALL
         SELECT 'V6'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            sh.code AS item_code,
            sh.name_en AS item_label,
            '/operation/handovers'::text AS href
           FROM shifts sh
          WHERE sh.is_active AND sh.starts_at IS NULL AND sh.ends_at IS NULL
        UNION ALL
         SELECT 'V8'::text AS value_code,
            'module.processing.view'::text AS permission,
            NULL::uuid AS item_id,
            'calibration_lead_days'::text AS item_code,
            'Calibration reminder lead days'::text AS item_label,
            '/operation/calibration'::text AS href
           FROM ingest_settings st
          WHERE st.id AND st.calibration_lead_days IS NULL
        UNION ALL
         SELECT 'V33'::text AS value_code,
            'module.processing.view'::text AS permission,
            d.id AS item_id,
            d.code AS item_code,
            d.name AS item_label,
            '/operation/devices/'::text || d.id::text AS href
           FROM devices d
          WHERE d.kind = ANY (ARRAY['scale'::text, 'weighbridge'::text, 'meter'::text, 'inline_instrument'::text])
            AND d.retired_at IS NULL AND d.interface_status <> 'reserved'::text AND d.capacity IS NULL
        UNION ALL
         SELECT 'V2'::text AS value_code,
            'module.suppliers.view'::text AS permission,
            cc.id AS item_id,
            c.code AS item_code,
            (cc.cert_no || ' · '::text) || c.name_en AS item_label,
            '/purchasing/licences'::text AS href
           FROM company_compliance cc
             CROSS JOIN nea_waste_categories c
          WHERE cc.id = storage_licence_in_force((now() AT TIME ZONE 'Asia/Singapore'::text)::date) AND c.is_active
            AND NOT (EXISTS ( SELECT 1
                   FROM licence_storage_limits l
                  WHERE l.licence_id = cc.id AND l.category_code = c.code))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            'nea_waste_categories'::text AS item_code,
            'NEA waste categories'::text AS item_label,
            '/settings/dictionaries'::text AS href
          WHERE NOT (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V29'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.nea_waste_category_code IS NULL
            AND (EXISTS ( SELECT 1
                   FROM nea_waste_categories c
                  WHERE c.is_active))
        UNION ALL
         SELECT 'V3'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.dwell_warning_days IS NULL
        UNION ALL
         SELECT 'V4'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            st.code AS item_code,
            st.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM inbound_safety_states st
          WHERE st.is_active AND st.requires_quarantine IS NULL
        UNION ALL
         SELECT 'V34'::text AS value_code,
            'module.inventory.view'::text AS permission,
            NULL::uuid AS item_id,
            'quarantine_location'::text AS item_code,
            'Quarantine location'::text AS item_label,
            '/inventory/locations'::text AS href
          WHERE (EXISTS ( SELECT 1
                   FROM inbound_safety_states st
                  WHERE st.is_active AND st.requires_quarantine IS TRUE))
            AND NOT (EXISTS ( SELECT 1
                   FROM storage_locations l
                  WHERE l.is_active AND l.is_quarantine))
        UNION ALL
         SELECT 'V30'::text AS value_code,
            'module.materials.view'::text AS permission,
            NULL::uuid AS item_id,
            g.code AS item_code,
            g.name_en AS item_label,
            '/settings/dictionaries'::text AS href
           FROM dangerous_goods_codes g
          WHERE g.is_active AND (g.marking_text IS NULL OR g.packing_instruction IS NULL OR g.label_size IS NULL)
        UNION ALL
         SELECT 'V31'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.hs_code IS NULL
        UNION ALL
         SELECT 'V35'::text AS value_code,
            'module.materials.view'::text AS permission,
            m.id AS item_id,
            m.code AS item_code,
            m.name AS item_label,
            '/materials/'::text || m.id::text || '/edit'::text AS href
           FROM materials m
             JOIN material_kinds mk ON mk.code = m.kind_code
          WHERE m.deleted_at IS NULL AND mk.has_condition_axes AND m.dg_code IS NULL) p
  WHERE has_permission(p.permission);

COMMENT ON VIEW public.pending_values IS
    'MES-1:还没给的标准值(/settings/pending-values)。一支一个值,每一支带自己的权限码;MES-1 播 V5(网关心跳间隔)与 V6(班次的起止时刻 —— 传输异常的工作时间);MES-2 加 V8(校准到期提醒的提前天数)与 V33(在用仪器的量程);MES-3a 加 V2(执照 × 类别的库存上限)、V29(NEA 类别与物料的类别)、V3(每个安全状态的滞留提醒天数)、V4(每个安全状态要不要隔离)与 V34(隔离库位);MES-3b 加 V30(危险品编号的标记 · 包装说明 · 标签尺寸)、V31(电池料的 HS 编码)与 V35(电池料的危险品编号)。之后每一刀加它自己的支,并在同一个提交里往 docs/mes-pending-values.md 加行。';

GRANT SELECT ON public.pending_values TO authenticated;
REVOKE ALL ON public.pending_values FROM anon;

-- ── 9 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份;scan_events 豁免)────────────
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.dangerous_goods_codes
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.dangerous_goods_codes
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.label_templates
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('code');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.label_templates
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.label_prints
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.label_prints
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.label_print_preview(text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.label_print_preview(text, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.record_label_print(text, uuid, text, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_label_print(text, uuid, text, integer, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.resolve_scan_code(text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.resolve_scan_code(text, text, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.shipping_queue_rows() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.shipping_queue_rows() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.label_object_data(text, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.label_object_data(text, uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.label_print_context(text, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.label_print_context(text, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.batch_quarantine_states(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.batch_quarantine_states(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_append_only_log() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_append_only_log() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.label_object_data(text, uuid) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.label_print_context(text, uuid, text) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.batch_quarantine_states(uuid) FROM authenticated;

-- ── 11 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes3b_pending_decider_check(p_after boolean DEFAULT true)
 RETURNS TABLE(k text, doc text, raiser text, subject text, deciders int, decider_names text)
 LANGUAGE sql STABLE
AS $f$
WITH fs AS (SELECT approval_level1_role_code AS l1, approval_level2_role_code AS l2 FROM public.finance_settings),
real_perm AS (
    SELECT DISTINCT rp.permission_code, rg.user_id
      FROM public.role_permissions rp JOIN public.roles r ON r.id = rp.role_id
     CROSS JOIN LATERAL public.real_role_grants(r.code) rg),
people AS (SELECT DISTINCT user_id FROM real_perm),
holds AS (SELECT user_id, array_agg(permission_code) AS codes FROM real_perm GROUP BY user_id),
items AS (
    -- 报销单:分档链,直接问 approval_deciders
    SELECT 'expense_claim'::text AS k, c.code::text AS doc, c.created_by AS raiser, c.employee_id AS subj,
           d.user_id AS u
      FROM public.expense_claims c CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('expense_claim', 'decide_expense_claim',
                 public.approval_level_for((SELECT b.amount_base FROM public.expense_claim_amount_base(c.id) b)),
                 c.created_by, c.employee_id, fs.l1, fs.l2) d ON true
     WHERE c.status = 'submitted'
    UNION ALL
    -- 采购单:分档链;金额档位按更严的二级问(一级的资格 ⊇ 二级,R1)
    SELECT 'purchase_order', p.code, p.created_by, NULL,
           d.user_id
      FROM public.purchase_orders p CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders('purchase_order', 'approve_purchase_order', 2::smallint,
                 p.created_by, NULL, fs.l1, fs.l2) d ON true
     WHERE p.approval_status = 'pending' AND p.deleted_at IS NULL
    UNION ALL
    -- 请假:decide_leave_request 的门(之前 module.hr.edit,之后 action.decide_hr_requests)
    --       + 余额函数要 module.hr.view(或本人)+ 四眼(R2 之后覆盖请假)
    SELECT 'leave_request', l.code, l.created_by, l.employee_id, h.user_id
      FROM public.leave_requests l CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = l.employee_id)
                       AND (public.self_leg(l.created_by, l.employee_id, h.user_id) = 'none'
                            OR (p_after AND public.self_approval_exception('leave_request', l.employee_id, h.user_id, fs.l2)))
     WHERE l.status = 'pending' AND l.deleted_at IS NULL
    UNION ALL
    SELECT 'medical_claim_submitted', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m CROSS JOIN fs
      LEFT JOIN holds h ON (CASE WHEN p_after THEN 'action.decide_hr_requests' ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND ('module.hr.view' = ANY (h.codes) OR public.account_person(h.user_id) = m.employee_id)
                       AND (public.self_leg(m.created_by, m.employee_id, h.user_id) = 'none'
                            OR public.self_approval_exception('medical_claim', m.employee_id, h.user_id, fs.l2))
     WHERE m.status = 'submitted' AND m.deleted_at IS NULL
    UNION ALL
    -- 已批未付的医疗申报:pay_medical_claim 只要 module.finance.edit,没有自付检查(量过,Tim 的矩阵允许)
    SELECT 'medical_claim_approved (pay)', m.code, m.created_by, m.employee_id, h.user_id
      FROM public.medical_claims m
      LEFT JOIN holds h ON 'module.finance.edit' = ANY (h.codes)
     WHERE m.status = 'approved' AND m.deleted_at IS NULL
    UNION ALL
    SELECT 'performance_review', r.id::text, r.submitted_by, r.employee_id, h.user_id
      FROM public.performance_reviews r
      LEFT JOIN holds h ON (CASE WHEN p_after THEN public.review_approval_code(r.submitted_by, r.employee_id)
                                 ELSE 'module.hr.edit' END) = ANY (h.codes)
                       AND public.self_leg(r.submitted_by, r.employee_id, h.user_id) = 'none'
     WHERE r.status = 'submitted'
    UNION ALL
    SELECT 'work_order', w.code, w.created_by, NULL, h.user_id
      FROM public.work_orders w
      -- ROLE-1 Batch 3b:下达归 action.wo_release;建单人不算(按人认)
      LEFT JOIN holds h ON 'action.wo_release' = ANY (h.codes)
                       AND public.self_leg(w.created_by, NULL, h.user_id) = 'none'
     WHERE w.status = 'draft'
    UNION ALL
    SELECT 'stocktake', s.code, s.created_by, NULL, h.user_id
      FROM public.stocktakes s
      -- ROLE-1 Batch 3a:过账归 action.stocktake_post;开单人与录过数的每一个人都不算(按人认)
      LEFT JOIN holds h ON 'action.stocktake_post' = ANY (h.codes)
                       AND public.self_leg(s.created_by, NULL, h.user_id) = 'none'
                       AND NOT EXISTS (SELECT 1 FROM public.stocktake_counts c
                                        WHERE c.stocktake_id = s.id
                                          AND public.self_leg(c.counted_by, NULL, h.user_id) <> 'none')
     WHERE s.status = 'open' AND s.deleted_at IS NULL
    UNION ALL
    -- ★ APR-7(grilling Q9):每一条申请链 —— 付款、工资、收货定价、贷项 / 作废、发货放行、手工凭证、仓库申请。
    --   它们在 approval_pending_documents 里带 fixed_level;决定人按 approval_deciders 问(与提交时的
    --   assert_other_decider 同一份判据),门取 approval_chain_gates 里那一行。APR-5b / APR-6 的自证只问了
    --   "这条链此刻有没有人",没有逐张问 —— 这一支补上。
    SELECT pd.subject_type, pd.code, pd.raiser_user_id, pd.subject_employee_id, d.user_id
      FROM public.approval_pending_documents() pd
      JOIN public.approval_chain_gates() g ON g.subject_type = pd.subject_type AND g.level = pd.fixed_level
     CROSS JOIN fs
      LEFT JOIN LATERAL public.approval_deciders(pd.subject_type, g.action_function, pd.fixed_level,
                 pd.raiser_user_id, pd.subject_employee_id, fs.l1, fs.l2) d ON true
     WHERE pd.fixed_level IS NOT NULL AND pd.subject_type NOT IN ('expense_claim', 'purchase_order')
    UNION ALL
    -- ★ APR-9:调薪申请按人路由(pay_decision_code),不在 approval_chain_gates 里 —— 问 salary_change_deciders,
    --   与 submit_salary_change_request 的"别人批得动吗"同一份判据。
    SELECT 'salary_change_request', q.label, q.created_by, q.employee_id, d.user_id
      FROM public.salary_change_requests q
      LEFT JOIN LATERAL public.salary_change_deciders(q.created_by, q.employee_id) d ON true
     WHERE q.status = 'submitted'
)
SELECT i.k, i.doc,
       (SELECT email::text FROM auth.users WHERE id = i.raiser),
       (SELECT legal_name FROM public.employees WHERE id = i.subj),
       count(DISTINCT COALESCE(public.account_person(i.u)::text, i.u::text))::int,
       string_agg(DISTINCT (SELECT email::text FROM auth.users WHERE id = i.u), ' ')
  FROM items i
 GROUP BY i.k, i.doc, i.raiser, i.subj
 ORDER BY 1, 2
$f$;

CREATE TEMP TABLE mes3b_pending_after ON COMMIT DROP AS
SELECT 'expense_claim'::text AS k, id FROM expense_claims WHERE status = 'submitted'
UNION ALL SELECT 'leave_request', id FROM leave_requests WHERE status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_submitted', id FROM medical_claims WHERE status = 'submitted' AND deleted_at IS NULL
UNION ALL SELECT 'medical_claim_approved', id FROM medical_claims WHERE status = 'approved' AND deleted_at IS NULL
UNION ALL SELECT 'performance_review', id FROM performance_reviews WHERE status = 'submitted'
UNION ALL SELECT 'work_order', id FROM work_orders WHERE status = 'draft'
UNION ALL SELECT 'stocktake', id FROM stocktakes WHERE status = 'open' AND deleted_at IS NULL
UNION ALL SELECT 'purchase_order', id FROM purchase_orders WHERE approval_status = 'pending' AND deleted_at IS NULL
UNION ALL SELECT 'payment_request', id FROM payment_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'payroll_request', id FROM payroll_requests WHERE status IN ('submitted', 'approved')
UNION ALL SELECT 'receipt_price_request', id FROM receipt_price_requests WHERE status = 'submitted'
UNION ALL SELECT 'invoice_request', id FROM invoice_requests WHERE status = 'submitted'
UNION ALL SELECT 'shipping_release', id FROM shipping_releases WHERE status = 'submitted'
UNION ALL SELECT 'journal_request', id FROM journal_requests WHERE status = 'submitted'
UNION ALL SELECT 'warehouse_request', id FROM warehouse_requests WHERE status = 'submitted'
UNION ALL SELECT 'terms_request', id FROM terms_requests WHERE status = 'submitted'
UNION ALL SELECT 'salary_change_request', id FROM salary_change_requests WHERE status = 'submitted'
UNION ALL SELECT 'asset_disposal_request', id FROM asset_disposal_requests WHERE status = 'submitted'
UNION ALL SELECT 'gst_filing_request', id FROM gst_filing_requests WHERE status = 'submitted';

DO $proof$
DECLARE
    v_bad   text;
    v_n     int;
    v_j     jsonb;
    k       text;
BEGIN
    -- ① 授权一行都没动(本刀不加码、不改授权)
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes3b_grants_before)
        UNION ALL
        (SELECT role_code || ':' || permission_code FROM mes3b_grants_before
         EXCEPT SELECT r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3B_PROOF|unexpected grant change: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES3B_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes3b_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes3b_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES3B_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;变更记录只在两本新字典的引导与例外表的两行上动了
    IF EXISTS ((SELECT b.k, b.id FROM mes3b_pending_before b EXCEPT SELECT a.k, a.id FROM mes3b_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes3b_pending_after a EXCEPT SELECT b.k, b.id FROM mes3b_pending_before b)) THEN
        RAISE EXCEPTION 'MES3B_PROOF|a pending document changed state';
    END IF;
    SELECT string_agg(DISTINCT c.table_name, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > (SELECT mx FROM mes3b_log_before)
       AND c.table_name NOT IN ('dangerous_goods_codes', 'label_templates', 'document_type_exceptions');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3B_PROOF|change_log moved on %', v_bad; END IF;
    -- 两本字典的引导行在它们的绑定之前插入(第 2 段 → 第 9 段),所以只有例外表那两行进了变更记录
    IF (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes3b_log_before)) <> 2 THEN
        RAISE EXCEPTION 'MES3B_PROOF|expected 2 change-log rows (the two document_type_exceptions rows), got %',
            (SELECT count(*) FROM change_log c WHERE c.seq > (SELECT mx FROM mes3b_log_before));
    END IF;

    -- ④ 两本字典恰好是引导;两张日志表是空的;没有一种物料有编号;MES-3a 的东西一样都没设;开关是空的
    IF (SELECT string_agg(code || ':' || dg_class, ',' ORDER BY code) FROM dangerous_goods_codes)
       IS DISTINCT FROM 'UN3090:9,UN3091:9,UN3480:9,UN3481:9'
       OR EXISTS (SELECT 1 FROM dangerous_goods_codes WHERE marking_text IS NOT NULL OR packing_instruction IS NOT NULL OR label_size IS NOT NULL) THEN
        RAISE EXCEPTION 'MES3B_PROOF|the DG dictionary is not exactly its bootstrap';
    END IF;
    IF (SELECT string_agg(code || ':' || object_kind || ':' || page_size, ',' ORDER BY sort_order) FROM label_templates)
       IS DISTINCT FROM 'inbound_a6:inbound_batch:A6,inbound_a5:inbound_batch:A5,output_a6:output_batch:A6,output_a5:output_batch:A5,location_a6:storage_location:A6,location_a5:storage_location:A5' THEN
        RAISE EXCEPTION 'MES3B_PROOF|the label templates are not exactly their bootstrap';
    END IF;
    IF EXISTS (SELECT 1 FROM label_prints) OR EXISTS (SELECT 1 FROM scan_events) THEN
        RAISE EXCEPTION 'MES3B_PROOF|a log table is not empty';
    END IF;
    IF EXISTS (SELECT 1 FROM materials WHERE dg_code IS NOT NULL OR hs_code IS NOT NULL) THEN
        RAISE EXCEPTION 'MES3B_PROOF|a material got a DG or HS code';
    END IF;
    IF EXISTS (SELECT 1 FROM nea_waste_categories) OR EXISTS (SELECT 1 FROM licence_storage_limits)
       OR EXISTS (SELECT 1 FROM storage_locations WHERE is_quarantine)
       OR EXISTS (SELECT 1 FROM inbound_safety_states WHERE dwell_warning_days IS NOT NULL)
       OR (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES3B_PROOF|a category, ceiling, quarantine location, dwell period or the calibration switch was set';
    END IF;

    -- ⑤ 匿名面:anon 能执行的【恰好】两支;员工那几支是 DEFINER、authenticated 调得到、anon 调不到;内层谁都调不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES3B_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.label_print_preview(text, uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.label_print_preview(text, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.label_print_preview(text, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3B_PROOF|public.label_print_preview(text, uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.record_label_print(text, uuid, text, integer, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.record_label_print(text, uuid, text, integer, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.record_label_print(text, uuid, text, integer, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3B_PROOF|public.record_label_print(text, uuid, text, integer, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.resolve_scan_code(text, text, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.resolve_scan_code(text, text, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.resolve_scan_code(text, text, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3B_PROOF|public.resolve_scan_code(text, text, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.shipping_queue_rows()'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.shipping_queue_rows()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.shipping_queue_rows()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES3B_PROOF|public.shipping_queue_rows(): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.label_object_data(text, uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.label_object_data(text, uuid)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.label_object_data(text, uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'MES3B_PROOF|public.label_object_data(text, uuid) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.label_print_context(text, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.label_print_context(text, uuid, text)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.label_print_context(text, uuid, text)'::regprocedure) THEN
        RAISE EXCEPTION 'MES3B_PROOF|public.label_print_context(text, uuid, text) must be an internal function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.batch_quarantine_states(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.batch_quarantine_states(uuid)'::regprocedure, 'EXECUTE')
       OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.batch_quarantine_states(uuid)'::regprocedure) THEN
        RAISE EXCEPTION 'MES3B_PROOF|public.batch_quarantine_states(uuid) must be an internal function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('dangerous_goods_codes', 'label_templates', 'label_prints', 'scan_events')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3B_PROOF|anon can read %', v_bad; END IF;

    -- ⑥ 那 44 条开着的读策略还是 44 条;两张日志表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES3B_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public' AND tablename IN ('label_prints', 'scan_events')
                 AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES3B_PROOF|a write policy exists on a log table';
    END IF;

    -- ⑦ 变更记录:覆盖零缺口(三张新表都记,scan_events 豁免 —— 7 → 8);遮蔽零缺口(仍是 105 条)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES3B_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 105 THEN
        RAISE EXCEPTION 'MES3B_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    -- ⑦b 每一张被记录的表,绑定的键就是它的主键(nea_waste_categories 那一处之后,一处都不许再错)
    SELECT string_agg(t.relname, ', ') INTO v_bad
      FROM (SELECT c.relname, substring(pg_get_triggerdef(tg.oid) FROM 'change_log_capture\((.*)\)') AS args
              FROM pg_trigger tg JOIN pg_class c ON c.oid = tg.tgrelid JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = 'public' AND tg.tgname = 'zzz_change_log') t
      LEFT JOIN (SELECT c.relname, string_agg(quote_literal(a.attname), ', ' ORDER BY array_position(i.indkey::int2[], a.attnum)) AS cols
                   FROM pg_index i JOIN pg_class c ON c.oid = i.indrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                   JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum = ANY (i.indkey)
                  WHERE n.nspname = 'public' AND i.indisprimary GROUP BY c.relname) pk ON pk.relname = t.relname
     WHERE t.args IS DISTINCT FROM pk.cols;
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES3B_PROOF|change-log key is not the primary key on %', v_bad; END IF;

    -- ⑧ 提醒臂 55 支(本刀一支不加);待补的值 10 → 13 支
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 55 THEN
        RAISE EXCEPTION 'MES3B_PROOF|operations_now should still have 55 arms';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 13 THEN
        RAISE EXCEPTION 'MES3B_PROOF|pending_values should have 13 arms';
    END IF;

    -- ⑨ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes3b_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES3B pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes3b_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES3B_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes3b_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
