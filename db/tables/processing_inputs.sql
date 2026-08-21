-- db/tables/processing_inputs.sql
-- 加工投料腿:一行 = 某次加工从某个进料批次消耗了多少。remaining_qty 的扣减由
-- commit_processing_run() 完成(本表无触发器)。ON DELETE RESTRICT:加工只能整体
-- 冲销,不允许顺手硬删投料史。
--
-- NOTE: 本表早于"迁移 + 镜像"约定(建库初期直接在 Supabase SQL Editor 建的),
-- 一直没有镜像文件;2026-07-31 镜像漂移审计后【按线上目录重建】了本文件。
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.processing_inputs (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id            uuid NOT NULL REFERENCES public.processing_runs (id) ON DELETE RESTRICT,
    inbound_batch_id  uuid REFERENCES public.inbound_batches (id),
    quantity_consumed numeric NOT NULL,
    created_at        timestamptz NOT NULL DEFAULT now(),
    -- ── FIN-25 追加(ALTER 加的列排在末尾)──────────────────────────────────
    -- 再加工投料:消耗的上游产出批。与 inbound_batch_id 恰一非空(XOR)。
    -- 估值用上游 processing_outputs.unit_cost_base,解除 1220 而非 1200。
    output_batch_id   uuid REFERENCES public.output_batches (id),
    CONSTRAINT processing_inputs_one_parent
        CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1)
);

CREATE INDEX idx_processing_inputs_output ON public.processing_inputs (output_batch_id);

COMMENT ON COLUMN public.processing_inputs.output_batch_id IS
    '再加工投料:消耗的上游产出批(FIN-25)。与 inbound_batch_id 恰一非空。估值用上游 processing_outputs.unit_cost_base,解除的是 1220 而非 1200。';

-- 自吞守卫(FIN-25):一张单不能消耗自己的产出;且【两种边】的直插一律拒 ——
-- 裸 INSERT 不扣 remaining_qty,账实即分道(进料边的这个洞早已存在)。
-- 【别因为"只有再加工用它"而删】:它守的是两侧。
CREATE OR REPLACE FUNCTION public.guard_processing_input()
RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
    v_material_id uuid;
    v_may  boolean;
    v_code text;
BEGIN
    IF current_setting('evoltrya.movement_ctx', true) NOT LIKE 'processing:%'
       AND current_setting('evoltrya.movement_ctx', true) NOT LIKE 'reversal:%' THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_DIRECT_INSERT';
    END IF;
    IF NEW.output_batch_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM processing_outputs po
        WHERE po.output_batch_id = NEW.output_batch_id AND po.run_id = NEW.run_id
    ) THEN
        RAISE EXCEPTION 'PROCESSING_INPUT_SELF_CONSUME|%', NEW.run_id;
    END IF;
    -- ── PROC-1:只有【说了可以投料】的物料进得来 ────────────────────────────
    -- 【NULL 不放行】八行历史物料的 may_be_processed 是空的,而空的意思是
    -- "没有人决定过" —— 把它读成"可以"正是本仓库反复付账的那一个错
    -- (METAL-1 的 no_reference、SS-1 的阈值为 NULL)。所以判据写成
    -- `IS NOT TRUE`:空与 false 一样被拦,而拒绝的话说得出是哪一种。
    SELECT COALESCE(ib.material_id, ob.material_id) INTO v_material_id
      FROM (SELECT 1) x
      LEFT JOIN inbound_batches ib ON ib.id = NEW.inbound_batch_id
      LEFT JOIN output_batches  ob ON ob.id = NEW.output_batch_id;
    IF v_material_id IS NOT NULL THEN
        SELECT m.may_be_processed, m.code INTO v_may, v_code
          FROM materials m WHERE m.id = v_material_id;
        IF v_may IS NOT TRUE THEN
            RAISE EXCEPTION 'MATERIAL_NOT_PROCESSABLE|%|%', v_code,
                CASE WHEN v_may IS NULL THEN 'undecided' ELSE 'false' END
              USING HINT = '这一种物料没有被声明为可投料;第二个参数说的是【没人决定过】还是【决定了不投】。';
        END IF;
    END IF;
    RETURN NEW;
END;
$fn$;
REVOKE EXECUTE ON FUNCTION public.guard_processing_input() FROM PUBLIC, anon;

CREATE TRIGGER trg_processing_inputs_guard
    BEFORE INSERT ON public.processing_inputs
    FOR EACH ROW EXECUTE FUNCTION public.guard_processing_input();

ALTER TABLE public.processing_inputs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "processing_inputs select by permission"
    ON public.processing_inputs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

CREATE POLICY "processing_inputs insert by permission"
    ON public.processing_inputs
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_inputs update by permission"
    ON public.processing_inputs
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text)) WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "processing_inputs delete by permission"
    ON public.processing_inputs
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'::text));
