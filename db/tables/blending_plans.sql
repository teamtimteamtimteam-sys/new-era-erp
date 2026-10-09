-- db/tables/blending_plans.sql
-- MES-5b-3(2026-10-09,MES-0 功能 12 · Q58;MES-5b Step 0 Q16–Q20,Tim):【一份配料计划】—— 把几批可售的粉料(黑粉、正极粉、负极粉)
--   按计划的公斤数混成一批,好对上一份销售合同的品位。Tim Q16:今天这条线不配料,将来那条线会 —— 照 Step 0 的推荐先建好。
--   四态,每一态都是【有人做了一个动作】(工单的同一个形状):
--     draft    —— 建出来就是这一态(create_blending_plan,action.wo_create);只有这一态改得动(amend_blending_plan,同一个码)。
--     released —— 有人放行(release_blending_plan,action.wo_release);【建单人永远不能放行】(forbid_self_approval,按人认)。
--     executed —— 从计划页上执行(execute_blending_plan,action.processing_commit):经 commit_processing_run 记一炉 blending,
--                 run_id 指着那一炉。执行之后计划冻住;那一炉照常可以经回滚申请回滚(计划页照直说那一炉的状态)。
--     cancelled —— draft 或 released 都可以取消,理由必填(action.wo_create)。
--   【产出物料必须是可售的形态】(Q20,R5):material_forms.may_be_sold 为假的按名拒(BLEND_OUTPUT_NOT_SALEABLE),
--     并且它必须是配料这道工序声明的产出形态(BLEND_OUTPUT_FORM_NOT_BLENDABLE)。
--   【没有金额】这里只有公斤与金属百分比,所以没有遮蔽的列(Q32)。
--   【编号】BLD-YYYY-NNNN,按年、无洞(next_blending_plan_code;document_types 里的 'blending_plan')。
--   写只经上面那五支 SECURITY DEFINER 函数 —— 表上一条写策略都没有。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.blending_plans (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code               text NOT NULL UNIQUE,
    status             text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft', 'released', 'executed', 'cancelled')),
    output_material_id uuid NOT NULL REFERENCES public.materials (id),
    -- 可选:目标品位从哪一份合同抄来(Q17)。抄的是那一刻的规格(blending_plan_targets 是快照),合同以后改了不回头改计划。
    source_contract_id uuid REFERENCES public.contracts (id),
    notes              text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid DEFAULT auth.uid(),
    updated_at         timestamptz NOT NULL DEFAULT now(),
    updated_by         uuid,
    released_at        timestamptz,
    released_by        uuid,
    executed_at        timestamptz,
    executed_by        uuid,
    run_id             uuid UNIQUE REFERENCES public.processing_runs (id),
    cancelled_at       timestamptz,
    cancelled_by       uuid,
    cancel_reason      text,
    -- 【状态与它的证据必须同时成立】(工单那两条 CHECK 的同一个理由:约束对任何写入者都成立,函数自觉只对今天的写入者成立)
    CONSTRAINT blending_plans_released_consistent CHECK (
        (released_at IS NULL) = (released_by IS NULL)
        AND (status NOT IN ('released', 'executed') OR released_at IS NOT NULL)
        AND (status <> 'draft' OR released_at IS NULL)
    ),
    CONSTRAINT blending_plans_executed_consistent CHECK (
        (status = 'executed') = (executed_at IS NOT NULL AND run_id IS NOT NULL)
    ),
    CONSTRAINT blending_plans_cancelled_consistent CHECK (
        (status = 'cancelled') = (cancelled_at IS NOT NULL)
        AND (cancelled_at IS NULL OR btrim(COALESCE(cancel_reason, '')) <> '')
    )
);

CREATE INDEX blending_plans_output_material_id_rel ON public.blending_plans (output_material_id);
CREATE INDEX blending_plans_source_contract_id_rel ON public.blending_plans (source_contract_id);
-- 搜索(与 work_orders 同两条):code 的后缀匹配 · "最近编辑过"
CREATE INDEX blending_plans_code_trgm ON public.blending_plans USING gin (code extensions.gin_trgm_ops);
CREATE INDEX blending_plans_recents ON public.blending_plans (updated_by, updated_at DESC);

COMMENT ON TABLE public.blending_plans IS
    'MES-5b-3:一份配料计划(BLD-YYYY-NNNN)—— 把几批可售的粉料按计划的公斤数混成一批,好对上一份合同的品位。四态 draft → released → executed,draft / released 可 cancelled(理由必填)。建与改 action.wo_create;放行 action.wo_release,建单人永远不能放行;执行 action.processing_commit,只从计划页上经 execute_blending_plan(它记一炉 blending,run_id 指着它)。预测的含量不存,读 blending_plan_prediction。产出批的含量只来自化验。';
COMMENT ON COLUMN public.blending_plans.output_material_id IS
    '混出来的那一批是什么物料。它的形态必须可售(material_forms.may_be_sold,R5),并且是配料这道工序声明的产出形态(operation_type_output_forms)。';
COMMENT ON COLUMN public.blending_plans.run_id IS
    '执行时记下的那一炉(operation_type_code = blending)。那一炉以后被回滚,计划仍是 executed —— 页面照直说那一炉已回滚;本刀不提供"再执行一次"。';

ALTER TABLE public.blending_plans ENABLE ROW LEVEL SECURITY;
-- 读:module.processing.view(工单的同一个码,Q19)。写:一条策略都不给 —— 只经五支 DEFINER 函数。
CREATE POLICY "blending_plans select by permission" ON public.blending_plans
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
GRANT SELECT ON public.blending_plans TO authenticated;
REVOKE ALL ON public.blending_plans FROM anon;
