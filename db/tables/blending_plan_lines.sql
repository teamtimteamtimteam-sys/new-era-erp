-- db/tables/blending_plan_lines.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q18,Tim):【一份配料计划的候选批次 —— 一批一行,计划的公斤数】。
--   一行指一批进料或一批产出(恰好一个);它的物料形态必须是配料这道工序收的形态(operation_type_input_forms,BLEND_LINE_FORM_NOT_BLENDABLE)。
--   【实际用了多少不存在这里】执行时每一行实际投了多少,记在那一炉的投料腿上(processing_inputs.quantity_consumed)——
--     计划页把两者并排,差多少照直印出来(Q18)。存第二份会让两份在第一次有人回滚那一炉时各说各话。
--   【含量不存在这里】预测读每一批【此刻】的金属含量(inbound_batch_metals / output_batch_metals),连同它的出处(化验 / 人填 / 不知道),
--     算在 blending_plan_prediction_all 里,不落盘(Q17)。
--   只经 create_blending_plan / amend_blending_plan 写(草稿态)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.blending_plan_lines (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id          uuid NOT NULL REFERENCES public.blending_plans (id) ON DELETE CASCADE,
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
    output_batch_id  uuid REFERENCES public.output_batches (id),
    planned_kg       numeric NOT NULL CHECK (planned_kg > 0),
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid(),
    CONSTRAINT blending_plan_lines_one_batch CHECK ((inbound_batch_id IS NULL) <> (output_batch_id IS NULL))
);

CREATE UNIQUE INDEX blending_plan_lines_one_inbound ON public.blending_plan_lines (plan_id, inbound_batch_id) WHERE inbound_batch_id IS NOT NULL;
CREATE UNIQUE INDEX blending_plan_lines_one_output ON public.blending_plan_lines (plan_id, output_batch_id) WHERE output_batch_id IS NOT NULL;
CREATE INDEX blending_plan_lines_inbound_batch_id_rel ON public.blending_plan_lines (inbound_batch_id);
CREATE INDEX blending_plan_lines_output_batch_id_rel ON public.blending_plan_lines (output_batch_id);

COMMENT ON TABLE public.blending_plan_lines IS
    'MES-5b-3:一份配料计划的候选批次,一批一行(进料批或产出批,恰好一个)与计划的公斤数。实际投了多少记在执行那一炉的投料腿上,不在这里;含量也不在这里 —— 预测读每一批此刻的含量与出处。';

ALTER TABLE public.blending_plan_lines ENABLE ROW LEVEL SECURITY;
CREATE POLICY "blending_plan_lines select by permission" ON public.blending_plan_lines
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.blending_plan_lines TO authenticated;
REVOKE ALL ON public.blending_plan_lines FROM anon;
