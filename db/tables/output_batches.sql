-- db/tables/output_batches.sql
-- 产出批次(加工产物,可售库存)。与 inbound_batches 同一套库存台账体系:
-- remaining_qty 由触发器维护、quantity 禁改、恒等式由 DEFERRABLE 约束触发器
-- 提交时校验(函数都在 db/functions/inventory_ledger_triggers.sql,挂载在本文件)。
-- state 是【销售状态】(库存中/部分售出/已售罄,中文取值),status 才是单据状态。
-- customer_id 可空:预售指定客户时才填。code 'OUT-YYYY-NNNN' 触发器取号(非无缝)。
-- 无 updated_at 触发器(建表早期漏挂)—— 镜像忠实于线上。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE SEQUENCE public.output_code_seq;

CREATE TABLE public.output_batches (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code          text NOT NULL UNIQUE,  -- 'OUT-YYYY-NNNN',触发器取号
    material_id   uuid NOT NULL REFERENCES public.materials (id),
    quantity      numeric NOT NULL,
    unit          text NOT NULL DEFAULT 'kg',
    remaining_qty numeric NOT NULL,
    CONSTRAINT output_batches_remaining_qty_nonneg CHECK (remaining_qty >= 0),
    output_date   date,
    state         text NOT NULL DEFAULT '库存中'
                  CHECK (state IN ('库存中','部分售出','已售罄')),
    customer_id   uuid REFERENCES public.customers (id),
    purity        text,
    notes         text,
    status        text NOT NULL DEFAULT 'draft',
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid
);

CREATE OR REPLACE FUNCTION public.generate_output_code()
RETURNS trigger LANGUAGE plpgsql AS $function$
BEGIN
    IF NEW.code IS NULL OR NEW.code = '' THEN
        NEW.code := 'OUT-' || EXTRACT(YEAR FROM NOW())::TEXT || '-' ||
                    LPAD(nextval('output_code_seq')::TEXT, 4, '0');
    END IF;
    RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_generate_output_code
    BEFORE INSERT ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION generate_output_code();

-- 库存台账体系(函数见 db/functions/inventory_ledger_triggers.sql)
CREATE TRIGGER trg_output_batches_emit_receipt
    AFTER INSERT ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION emit_batch_receipt_movement();

CREATE TRIGGER trg_output_batches_writeoff
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW
    WHEN (OLD.deleted_at IS NULL AND NEW.deleted_at IS NOT NULL)
    EXECUTE FUNCTION emit_batch_writeoff_movement();

CREATE TRIGGER trg_output_batches_quantity_guard
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW
    WHEN (NEW.quantity IS DISTINCT FROM OLD.quantity)
    EXECUTE FUNCTION reject_quantity_change();

CREATE CONSTRAINT TRIGGER trg_output_batches_invariant
    AFTER INSERT OR UPDATE ON public.output_batches
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION check_ledger_invariant();

ALTER TABLE public.output_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "output_batches select by permission"
    ON public.output_batches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));

-- 【没有面向客户端的 INSERT 策略,这是刻意的】(IOD-1b,2026-08-13)
-- 建批次只有一扇门:create_inbound_batch / receive_inbound_batch_against_po
-- (产出侧是 create_output_batch)。它们是 SECURITY DEFINER,以属主身份写入,
-- 所以不需要这条策略;而撤掉它,直接 POST /rest/v1/<表> 会被 RLS 拒。
-- 【为什么】IOD-2 要在"货落进哪个库位"上设闸,而一个留着侧门的卡口不是卡口 ——
-- 先把门收成一扇,IOD-2 只需在这一扇门上加判断,不必追第二条路径。
-- 【IOD-2 已经落闸(2026-08-13)】判断就加在这一扇门上:check_location_class,
-- 见 storage_location_allowed_classes 表头。这条策略因此是【它的前提】,不是
-- 一次顺手收紧 —— 撤掉它,闸就又有了一条绕过去的路。
-- commit_processing_run 同为 DEFINER,不受影响(fixture 58 D 臂钉住)。

CREATE POLICY "output_batches update by permission"
    ON public.output_batches
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.output.edit'::text)) WITH CHECK (has_permission('module.output.edit'::text));

CREATE POLICY "output_batches delete by permission"
    ON public.output_batches
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.output.edit'::text));
