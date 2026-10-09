-- db/tables/blending_plan_targets.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q20,Tim):【一份配料计划的目标品位 —— 每一种金属一行,下界与上界】。
--   界,不是目标 ± 公差(CONTRACT-1 U8 的同一条裁定:真实合同多半是单边的「Ni ≥ 18%」「Cu ≤ 0.5%」)。至少一个界;下界不高于上界。
--   来源两种(Q17):
--     contract —— 从计划那一份合同的一条品位规格(contract_grade_specs)抄来,抄的是那一刻的两个界(快照:合同以后改了不回头改计划);
--                 source_grade_spec_id 指着那一条(那一条以后被删,指针置空,抄下来的界照旧);
--     manual   —— 人敲的。
--   预测出界【只标出来,不拒】(Q20,CONTRACT-1 那条"报告,不是闸")。只经 create_blending_plan / amend_blending_plan 写(草稿态)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.blending_plan_targets (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    plan_id              uuid NOT NULL REFERENCES public.blending_plans (id) ON DELETE CASCADE,
    metal                text NOT NULL REFERENCES public.substances (code),
    min_pct              numeric CHECK (min_pct IS NULL OR (min_pct >= 0 AND min_pct <= 100)),
    max_pct              numeric CHECK (max_pct IS NULL OR (max_pct >= 0 AND max_pct <= 100)),
    source               text NOT NULL CHECK (source IN ('contract', 'manual')),
    source_grade_spec_id uuid REFERENCES public.contract_grade_specs (id) ON DELETE SET NULL,
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    CONSTRAINT blending_plan_targets_one_per_metal UNIQUE (plan_id, metal),
    CONSTRAINT blending_plan_targets_needs_a_bound CHECK (min_pct IS NOT NULL OR max_pct IS NOT NULL),
    CONSTRAINT blending_plan_targets_bounds_ordered CHECK (min_pct IS NULL OR max_pct IS NULL OR min_pct <= max_pct),
    CONSTRAINT blending_plan_targets_manual_has_no_spec CHECK (source = 'contract' OR source_grade_spec_id IS NULL)
);

CREATE INDEX blending_plan_targets_source_grade_spec_id_rel ON public.blending_plan_targets (source_grade_spec_id);

COMMENT ON TABLE public.blending_plan_targets IS
    'MES-5b-3:一份配料计划的目标品位,每种金属一行:下界 / 上界(至少一个)。来源 contract(从合同的品位规格抄来的快照)或 manual(人敲的)。预测出界只标出来,不拒(Q20)。';

ALTER TABLE public.blending_plan_targets ENABLE ROW LEVEL SECURITY;
CREATE POLICY "blending_plan_targets select by permission" ON public.blending_plan_targets
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.blending_plan_targets TO authenticated;
REVOKE ALL ON public.blending_plan_targets FROM anon;
