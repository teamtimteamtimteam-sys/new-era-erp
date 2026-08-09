-- db/tables/inbound_batches.sql
-- 进料批次 —— 库存与应付两条账的源头单据。
--   * remaining_qty 由库存台账触发器体系维护,quantity 一经写入禁改
--     (trg_inbound_batches_quantity_guard),数量恒等式由 DEFERRABLE 约束触发器
--     check_ledger_invariant 在提交时校验 —— 这四个触发器的【函数】都定义在
--     db/functions/inventory_ledger_triggers.sql,触发器挂载在本文件;
--   * unit_price 是【应付之锚】(应付 = quantity × unit_price,改价即改欠款),
--     只能经 set_inbound_unit_price() 修改 —— 价格守卫触发器
--     trg_inbound_batches_price_guard 挂载在 db/tables/price_history.sql(守卫函数
--     与价格史同住,因为它正是"改价必须留痕"这条规则的执行者);
--   * code 'IN-YYYY-NNNN' 由 BEFORE INSERT 触发器从序列取号(非无缝,单据连号
--     要求只在财务凭证侧);
--   * 无 updated_at 触发器(建表早期漏挂)—— 镜像忠实于线上。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- purchase_order_id / purchase_order_line_id 及 trg_inbound_batches_po_line_match
-- 为 db/migrations/2026-07-31-phase4-cut4a-purchase-orders.sql 追加(守卫函数在
-- db/functions/guard_inbound_po_line_match.sql;两列可空 —— 没有 PO 的现场收货
-- 照常工作;列序按线上 attnum,追加列在末尾)。
-- cut 4c(db/migrations/2026-07-31-phase4-cut4c-po-receiving.sql)再追加两个触发器:
--   * trg_inbound_batches_po_receivable —— 已取消/已结束的单拒收(PO_NOT_RECEIVABLE);
--   * trg_inbound_batches_advance_po —— 首次收货把 'confirmed' 推到 'receiving'
--     (机械且无歧义;关单是判断,永远手动走 close_purchase_order)。
-- cut 5a(db/migrations/2026-07-31-phase4-cut5a-assay-repricing.sql)追加
-- pricing_formula_id / pricing_status 两列(见列注释;列序按线上 attnum,追加在末尾)。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.inbound_code_seq;

CREATE TABLE public.inbound_batches (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,  -- 'IN-YYYY-NNNN',触发器取号
    material_id            uuid NOT NULL REFERENCES public.materials (id),
    supplier_id            uuid NOT NULL REFERENCES public.suppliers (id),
    quantity               numeric NOT NULL,
    unit                   text NOT NULL DEFAULT 'kg',
    remaining_qty          numeric NOT NULL,
    CONSTRAINT inbound_batches_remaining_qty_nonneg CHECK (remaining_qty >= 0),
    arrival_date           date,
    stage                  text NOT NULL DEFAULT '待加工'
                           CHECK (stage IN ('待加工','加工中','已加工完')),
    unit_price             numeric,
    notes                  text,
    status                 text NOT NULL DEFAULT 'draft',
    deleted_at             timestamptz,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid,
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid,
    purchase_order_id      uuid REFERENCES public.purchase_orders (id),
    purchase_order_line_id uuid REFERENCES public.purchase_order_lines (id),
    -- cut 5a:管这批货价格的公式(手工计价的临时采购可空)与定价状态 ——
    -- 'provisional' = 按估计/申报含量暂定,'final' = 已按正式化验重算
    -- (只有 is_final 化验被 apply 后才升 final;手工定价永远只是 provisional)
    pricing_formula_id     uuid REFERENCES public.pricing_formulas (id),
    pricing_status         text NOT NULL DEFAULT 'provisional'
                           CHECK (pricing_status IN ('unpriced','provisional','final'))
);

CREATE INDEX idx_inbound_batches_po ON public.inbound_batches (purchase_order_id);

CREATE OR REPLACE FUNCTION public.generate_inbound_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'IN-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('inbound_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_inbound_code
    BEFORE INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION generate_inbound_code();

-- 库存台账体系(函数见 db/functions/inventory_ledger_triggers.sql)
CREATE TRIGGER trg_inbound_batches_emit_receipt
    AFTER INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION emit_batch_receipt_movement();

CREATE TRIGGER trg_inbound_batches_writeoff
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW
    WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION emit_batch_writeoff_movement();

CREATE TRIGGER trg_inbound_batches_quantity_guard
    BEFORE UPDATE ON public.inbound_batches
    FOR EACH ROW
    WHEN (NEW.quantity IS DISTINCT FROM OLD.quantity)
    EXECUTE FUNCTION reject_quantity_change();

CREATE CONSTRAINT TRIGGER trg_inbound_batches_invariant
    AFTER INSERT OR UPDATE ON public.inbound_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_ledger_invariant();

-- PO 关联守卫(cut 4a;函数见 db/functions/guard_inbound_po_line_match.sql)
CREATE TRIGGER trg_inbound_batches_po_line_match
    BEFORE INSERT OR UPDATE OF purchase_order_id, purchase_order_line_id
    ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION guard_inbound_po_line_match();

-- 收货与采购单状态的联动(cut 4c)
CREATE OR REPLACE FUNCTION public.guard_inbound_po_receivable()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_po record;
    v_cert record;
BEGIN
    -- CMP-1:【block 类型的证书过期 → 本供应商不能收货】,不论这单挂没挂采购单 ——
    -- Doc 1 问的是"有害废物【进场】",进场是物理事件,与单据无关。只在 INSERT 时查
    -- (换采购单的 UPDATE 不重复查:货已在场,换单不是又进了一次场)。
    -- 【disposition 从类型表现读】—— 改一行数据就改行为,这正是类型作为表的全部意义。
    -- 【缺证不挡】:挡的是"过期",不是"没有"—— A3 的答复只到这里。
    IF TG_OP = 'INSERT' AND NEW.supplier_id IS NOT NULL THEN
        SELECT ct.code, ct.name_en, sc.valid_until, s.code AS supplier_code
        INTO v_cert
        FROM supplier_compliance sc
        JOIN certificate_types ct ON ct.code = sc.cert_type_code
        JOIN suppliers s ON s.id = sc.supplier_id
        WHERE sc.supplier_id = NEW.supplier_id
          AND sc.deleted_at IS NULL
          AND ct.disposition = 'block'
          AND sc.valid_until IS NOT NULL
          AND sc.valid_until < CURRENT_DATE
        ORDER BY sc.valid_until
        LIMIT 1;
        IF FOUND THEN
            RAISE EXCEPTION 'SUPPLIER_QUALIFICATION_EXPIRED|%|%|%',
                v_cert.supplier_code, v_cert.code, v_cert.valid_until;
        END IF;
    END IF;

    IF NEW.purchase_order_id IS NULL THEN
        RETURN NEW;
    END IF;
    -- UPDATE 时只在换单时把关(同单上改行号之类不重复检查)
    IF TG_OP = 'UPDATE' AND NEW.purchase_order_id IS NOT DISTINCT FROM OLD.purchase_order_id THEN
        RETURN NEW;
    END IF;
    SELECT code, status, approval_status INTO v_po FROM purchase_orders WHERE id = NEW.purchase_order_id;
    IF FOUND AND v_po.status IN ('cancelled', 'closed') THEN
        RAISE EXCEPTION 'PO_NOT_RECEIVABLE|%|%', v_po.code, v_po.status;
    END IF;
    -- APR-2:【未获批的采购单不能收货】。这是审批从"状态列"变成"管控"的那一步:
    -- 收货走的是裸 INSERT,没有 RPC,所以这个触发器就是唯一的咽喉。
    IF FOUND AND v_po.approval_status <> 'approved' THEN
        RAISE EXCEPTION 'PO_NOT_APPROVED|%|%', v_po.code, v_po.approval_status;
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_inbound_batches_po_receivable
    BEFORE INSERT OR UPDATE OF purchase_order_id ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_po_receivable();

CREATE OR REPLACE FUNCTION public.advance_po_on_receipt()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.purchase_order_id IS NOT NULL THEN
        UPDATE purchase_orders
        SET status = 'receiving', updated_by = auth.uid()
        WHERE id = NEW.purchase_order_id AND status = 'confirmed';
    END IF;
    RETURN NULL;
END;
$function$;

CREATE TRIGGER trg_inbound_batches_advance_po
    AFTER INSERT ON public.inbound_batches
    FOR EACH ROW EXECUTE FUNCTION public.advance_po_on_receipt();

ALTER TABLE public.inbound_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inbound_batches select by permission"
    ON public.inbound_batches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));

CREATE POLICY "inbound_batches insert by permission"
    ON public.inbound_batches
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "inbound_batches update by permission"
    ON public.inbound_batches
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.inbound.edit'::text)) WITH CHECK (has_permission('module.inbound.edit'::text));

CREATE POLICY "inbound_batches delete by permission"
    ON public.inbound_batches
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'::text));

-- cut 2b 字段级遮蔽:收回原始敏感列。表级 SELECT 授权【蕴含所有列】,
-- 所以必须先整表收回,再把非敏感列逐列授回。敏感列只能经 inbound_batches_masked 读取。
-- (check_mirrors 不比对 GRANT;这一段是为了让镜像仍能重建出权限状态。)
REVOKE SELECT ON public.inbound_batches FROM authenticated, anon;
GRANT SELECT (id, code, material_id, supplier_id, quantity, unit, remaining_qty, arrival_date, stage, notes, status, deleted_at, created_at, created_by, updated_at, updated_by, purchase_order_id, purchase_order_line_id, pricing_formula_id, pricing_status)
    ON public.inbound_batches TO authenticated;
