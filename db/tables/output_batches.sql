-- db/tables/output_batches.sql
-- 产出批次(加工产物,可售库存)。与 inbound_batches 同一套库存台账体系:
-- remaining_qty 由触发器维护、quantity 禁改、恒等式由 DEFERRABLE 约束触发器
-- 提交时校验(函数都在 db/functions/inventory_ledger_triggers.sql,挂载在本文件)。
-- state 是【销售状态】(库存中/部分售出/已售罄,中文取值),status 才是单据状态。
-- PROC-WIRE-1A:state 的取值改由字典表 output_batch_states 定义(CHECK → 外键),
-- **取值集合一个字没变**;并新增 purpose_code —— 【另一条轴】,答"这批是干什么用的"。
-- 两条轴不许合并:一批被工序吃光的投料 remaining_qty 归零而【不是】已售罄。
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
                  REFERENCES public.output_batch_states (code),
    customer_id   uuid REFERENCES public.customers (id),
    purity        text,
    notes         text,
    status        text NOT NULL DEFAULT 'draft',
    deleted_at    timestamptz,
    created_at    timestamptz NOT NULL DEFAULT now(),
    created_by    uuid,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    updated_by    uuid,
    -- ── AUDEL-1b 追加的列(ALTER 加的列排在末尾,与 attnum 顺序一致)──────
    deleted_by    uuid,
    delete_reason text,
    -- ── PROC-WIRE-1A 追加的列 ────────────────────────────────────────────
    -- 这一批是干什么用的。**与 state 是两条轴**:state 答"卖掉了多少"。
    -- 【给默认值,而 PROC-BUILD-1 的 may_be_sold 不给】—— 两者的空意思不同:
    -- may_be_sold 不给默认是因为"加一个形态"是一次裁定时刻(法律许不许卖,
    -- 给了默认就等于替法律作答);而这一列的默认是【现状】—— 线上每一批今天
    -- 都是可售库存,既有的两条建批次路建的也都是可售库存。
    purpose_code  text NOT NULL DEFAULT 'saleable_stock'
                  REFERENCES public.output_batch_purposes (code),
    -- ── PROC-WIRE-1B-ii 追加的列 ─────────────────────────────────────────
    -- 【在制品:这一批在等哪一道工序】可空。**不建 WIP 表** —— 在制品那一行
    -- 就是本表这一行(PROC-WIRE-1A 立的),再存一份就会把同一批料数两遍。
    awaiting_operation_type_code text
                  REFERENCES public.operation_types (code)
);

COMMENT ON COLUMN public.output_batches.awaiting_operation_type_code IS
'PROC-WIRE-1B-ii(R3):这一批在等【哪一道】工序。**可空。**

【空是什么意思:"还没决定等哪道",【不是】"不适用"】—— 一批已被指定为工序投料
(purpose_code 那条轴)但还没排到具体工序的料,仍然是在制品。
**是不是在制品由 purpose_code 回答,等哪一道由本列回答 —— 两个问题,不许合并。**

【它【不是】第三条轴,只是第二条轴的一个细节】purpose_code 说"这批是干什么用的",
本列说"那件事具体是哪一道"。所以守卫把话说死:**可售库存的批次上本列必须为空**
(guard_output_batch_awaiting_operation)—— 否则会长出一个"既是可售库存、
又在等粉料线"的自相矛盾行,而那正是 material_sources.implies_never_charged
那条列注说的"迟早会跟它的孪生兄弟打架的那一列"。';

COMMENT ON COLUMN public.output_batches.purpose_code IS
'PROC-WIRE-1A:这一批是干什么用的 —— 可售库存,还是下游工序的投料。
**与 state 是两条轴**:state 答"卖掉了多少",本列答"这批是干什么的"。
**线上既有行全部落在 saleable_stock**,那不是一次数据迁移,那就是它们今天的样子
(Tim 裁定线上 20 批产出全是测试残留,本刀不动它们中的任何一批)。
"这批投料用完了没有"【不需要】本轴表示 —— remaining_qty = 0 已经把它说清楚了,
而且消耗路(commit_processing_run)本来就只扣 remaining_qty。';


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

-- AUDEL-1a:硬删按名拒(BATCH_NO_HARD_DELETE|批号),理由与 inbound_batches 逐字相同
-- (output_batch_metals 同样是 CASCADE)。守卫只挡 DELETE,软删照常。
CREATE TRIGGER trg_output_batches_no_hard_delete
    BEFORE DELETE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_batch_no_hard_delete();

-- PROC-WIRE-1B-ii:让"在等哪一道"这一列的空与非空各自只有一个意思。
CREATE TRIGGER trg_output_batches_awaiting_operation
    BEFORE INSERT OR UPDATE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_output_batch_awaiting_operation();

-- AUDEL-1b:置 deleted_at 必须走【门】(函数),且 deleted_by / delete_reason 必须填好。
-- 光加两列挡不住任何事 —— 软删本来就是一次直连 UPDATE。
CREATE TRIGGER trg_output_batches_soft_delete_provenance
    BEFORE UPDATE ON public.output_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_soft_delete_provenance();
