-- db/migrations/2026-10-09-mes5b3-blending.sql
-- MES-5b-3 —— 配料(将来那条线):一份配料计划从可售的粉料批次里排出来,对着每种金属的上下界,混之前先看预测的成分,
--   建单人之外的人放行,从计划页上执行成一炉,混出来那一批化验之后对着目标比一遍;admin 也持 module.tasks.view_all
--   (MES 组的第十一刀,v1.4.47;发布那一行在 docs/handbacks/MES-5b-3.md 的抬头)。
-- 由 db/scripts/build_mes5b3_migration.py 从镜像拼出;改镜像,再重拼,不要手改本文件。
--
-- 【本刀做什么】(Tim 2026-10-09:MES-5b Step 0 的配料那一部分 —— Q16–Q20 与 Q1 · Q32 · Q34–Q36 的配料部分 —— 全部照推荐裁定;
--   Q16:今天这条线不配料,将来那条线会;并入:admin 持 module.tasks.view_all,关掉 MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED)
--   ① 三张表(Q17):blending_plans(BLD- 按年 · 产出物料 · 合同可空 · draft / released / executed / cancelled)·
--      blending_plan_targets(每种金属的下界 / 上界,从合同的品位规格抄来或人敲的)· blending_plan_lines(候选批次与计划的公斤数)。
--   ② 预测(Q17):按计划公斤数加权的平均,出处照直给,任何一行没量过就是"没量过";不落盘(blending_plan_prediction)。出界只标,不拒(Q20)。
--   ③ 一道新工序 blending(Q18):只从计划页上起(started_from_run_page,新建加工单的选单不列它;直接记按名拒 BLEND_RUN_FROM_PLAN_ONLY),
--      execute_blending_plan 是 commit_processing_run 的外壳(拆去隔离的先例 —— 引擎签名不动);实际公斤数可以与计划不同,差多少照直印出来;
--      混出来那一批的含量只来自化验(BLEND_CONTENT_FROM_ASSAY_ONLY)。
--   ④ 码(Q19):没有新码 —— 建与改 action.wo_create,放行 action.wo_release(建单人永远不能放行),执行 action.processing_commit,
--      读 module.processing.view;批次的含量只给看得见那一批的人(其余「受限」)。
--   ⑤ 可售(Q20):产出物料必须是可售的形态,否则按名拒(BLEND_OUTPUT_NOT_SALEABLE)。计划页把之后的化验对着目标比(blending_plan_outcome)。
--   ⑥ Q32 · Q34–Q36:没有新审批;三张新表都进变更记录(豁免仍是 8);新的审计主语 blending_plan;没有遮蔽的列;没有新的 Not yet set;一支迁移;
--      单据登记多一行 BLD(document_types)。
--   ⑦ 并入:线上的 admin 角色补一行 module.tasks.view_all(本刀唯一的一处授权改动);引导的 admin 同步(镜像)。
--
-- 【不做什么】不建、不停、不删任何账号;不碰审批开关与策略;除了 admin 那一行,不加任何码、不改任何授权;不写、不改、不冲任何一张既有单据、
--   批次、加工单、化验、费用单、付款、分录;不建任何计划、目标、批次行、化验或品位规格;不给配料这道工序任何容差、字段、机器或配方
--   (它的平衡容差为空 —— V1 那一支从此也列它,那是 V1 本来的意思,不是一个新的待补值);require_calibrated_since 保持空。
--
-- 【破窗】见 docs/surveys/MES-5b/STEP0-HANDBACK.md §11:配料是 started_from_run_page,旧应用的新建加工单表单本来就不列它;旧应用没有配料的页;
--   新的两支触发器只拒两条旧应用不发的路(记一炉 blending、给一批混出来的料敲含量 —— 线上一批都没有)。窗口 ≈ 部署时长。
--
-- 【审批是开着的】文末的自证在同一笔事务里断言:开关仍开;授权恰好多了 admin:module.tasks.view_all 一行、别的一行没动,admin 持目录里每一个码;
--   在途单据一张不少、一张不多,每一张仍有一个不是它当事人的决定人;七个账号一个都没被停;既有的加工单与腿、批次与含量、化验、流水、分录、
--   费用单、付款、工单、设备、物料、合同与品位规格逐字未变;变更记录只多了本刀种的那几行(插入,七张配置表与那一行授权);三张新表是空的;
--   两支触发器在;配料是 started_from_run_page;引擎的签名逐字未变;anon 能执行的【恰好】两支;五支员工函数是 DEFINER、调得到,内层调不到;
--   那 44 条开着的读策略还是 44 条;变更记录覆盖与遮蔽零缺口(豁免 8、规则 114);提醒臂 59、待补的值 20 不变;每一个角色仍满足"动作码蕴含查看码"。
--   断言失败 = 整笔回滚。

BEGIN;

-- ── 0 · 前提:线上是我们以为的那个样子 ──────────────────────────────────────
DO $pre$
BEGIN
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN
        RAISE EXCEPTION 'MES5B3_PRE|approvals are expected ON';
    END IF;
    IF to_regclass('public.blending_plans') IS NOT NULL OR to_regprocedure('public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text)') IS NOT NULL
       OR EXISTS (SELECT 1 FROM operation_types WHERE code = 'blending') OR EXISTS (SELECT 1 FROM document_types WHERE key = 'blending_plan' OR prefix = 'BLD') THEN
        RAISE EXCEPTION 'MES5B3_PRE|MES-5b-3 objects already exist';
    END IF;
    IF (SELECT count(*) FROM auth.users WHERE email NOT LIKE '%@test.local') <> 7 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected 7 accounts';
    END IF;
    IF EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id WHERE r.code = 'admin' AND rp.permission_code = 'module.tasks.view_all')
       OR (SELECT count(*) FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                               WHERE r.code = 'admin' AND rp.permission_code = p.code)) <> 1 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected admin to hold every code but module.tasks.view_all';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 55 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected 55 document types';
    END IF;
    IF pg_get_function_arguments('public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)'::regprocedure)
         <> 'p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text, p_started_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ended_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_shift_code text DEFAULT NULL::text, p_recipe_version_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb, p_corrects_run_id uuid DEFAULT NULL::uuid' THEN
        RAISE EXCEPTION 'MES5B3_PRE|the run engine signature is not the one this migration was written against';
    END IF;
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected 44 open read policies for authenticated';
    END IF;
    IF (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES5B3_PRE|expected 114 mask rules, got %', (SELECT count(*) FROM change_log_mask_rules());
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59 THEN
        RAISE EXCEPTION 'MES5B3_PRE|operations_now should have 59 arms before';
    END IF;
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B3_PRE|pending_values should have 20 arms before';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B3_PRE|require_calibrated_since must be empty';
    END IF;
END;
$pre$;

-- "之前"的读数,供文末比对(临时表随事务消失)
CREATE TEMP TABLE mes5b3_pending_before ON COMMIT DROP AS
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
CREATE TEMP TABLE mes5b3_grants_before ON COMMIT DROP AS
SELECT r.code AS role_code, rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id;
CREATE TEMP TABLE mes5b3_log_before ON COMMIT DROP AS
SELECT count(*) AS n, max(seq) AS mx FROM change_log;
CREATE TEMP TABLE mes5b3_accounts_before ON COMMIT DROP AS
SELECT id, email, banned_until FROM auth.users;
CREATE TEMP TABLE mes5b3_rows_before ON COMMIT DROP AS
SELECT (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_runs t) AS processing_runs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_inputs t) AS processing_inputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_outputs t) AS processing_outputs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inbound_batches t) AS inbound_batches,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM output_batches t) AS output_batches,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inbound_batch_metals t) AS inbound_batch_metals,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM output_batch_metals t) AS output_batch_metals,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM assay_results t) AS assay_results,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM assay_result_metals t) AS assay_result_metals,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inventory_movements t) AS inventory_movements,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_entries t) AS journal_entries,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_lines t) AS journal_lines,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM expenses t) AS expenses,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payments t) AS payments,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payment_allocations t) AS payment_allocations,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM work_orders t) AS work_orders,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM devices t) AS devices,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM materials t) AS materials,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM contracts t) AS contracts,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM contract_grade_specs t) AS contract_grade_specs,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM material_forms t) AS material_forms,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_run_closures t) AS processing_run_closures,
       (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_run_losses t) AS processing_run_losses;

-- ── 1 · 新表(镜像原样):配料计划 · 目标品位 · 候选批次 ─────────────────────────────────────────────

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

-- ── 2 · 新函数(镜像原样):取号 · 判据 · 建 / 改 / 放行 / 取消 / 执行 · 两支守卫(表先在,%ROWTYPE 才解析得了)────────

-- db/functions/next_blending_plan_code.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17):配料计划的编号 BLD-YYYY-NNNN —— 按年、无洞,与 next_work_order_code 逐行同形
--   (自己的一把 advisory lock;MAX(split_part)+1 带 LIKE 过滤;前缀从 document_types 读)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.next_blending_plan_code(p_date date DEFAULT CURRENT_DATE)
 RETURNS text
 LANGUAGE plpgsql
AS $function$
DECLARE
    v_year integer := EXTRACT(YEAR FROM p_date)::integer;
    v_seq  integer;
BEGIN
    -- 【自己的一把锁】BLD 与 WO / SO / QT 各自连号 —— 共用一把会让一种单据烧掉另一种的号。
    PERFORM pg_advisory_xact_lock(hashtext('blending_plan_code_' || v_year::text)::bigint);
    SELECT COALESCE(MAX(split_part(code, '-', 3)::integer), 0) + 1
    INTO v_seq
    FROM blending_plans
    WHERE code LIKE document_type_prefix('blending_plan') || '-' || v_year::text || '-%';
    RETURN document_type_prefix('blending_plan') || '-' || v_year::text || '-' || LPAD(v_seq::text, 4, '0');
END;
$function$;

-- db/functions/blending_plan_write_children.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q20,Tim):【一份配料计划的判据与落库 —— 产出物料、目标品位、候选批次】
--   create_blending_plan 与 amend_blending_plan 共用这一段(一份判据,两个调用者 —— AGENTS.md 的预览规则同一条)。
--   ★ 内层:它【不查码】,也【不是】DEFINER(reverse_expense_internal 的同一个形状)—— 它只在两支查过 action.wo_create 的 DEFINER 函数里
--     以属主身份跑;EXECUTE 从 authenticated 收回(zzz_function_grants.sql)。
--   判的顺序就是人下一步该改什么的顺序:先产出物料,再合同,再目标,再批次。
--     ① 产出物料:存在、没删;形态【可售】(material_forms.may_be_sold,R5)—— 否则 BLEND_OUTPUT_NOT_SALEABLE|<物料>|<形态>|<中文>|<英文>;
--        形态是配料这道工序声明的产出形态 —— 否则 BLEND_OUTPUT_FORM_NOT_BLENDABLE|<物料>|<形态或空>。
--     ② 合同(可空):存在 —— 否则 BLEND_CONTRACT_NOT_FOUND。
--     ③ 目标:p_targets 为 NULL 且有合同 → 抄那份合同里【适用于这种物料】的每一条品位规格(物料为空的,或就是这种物料的;同一种金属
--        两条都有时取指名物料的那一条)。否则逐条:{grade_spec_id} → 抄那一条(必须属于这份合同 BLEND_TARGET_SPEC_NOT_FROM_CONTRACT、
--        适用于这种物料 BLEND_TARGET_SPEC_OTHER_MATERIAL),来源 contract;{metal, min_pct, max_pct} → 人敲的,来源 manual:
--        金属在字典里(METAL_INVALID)· 至少一个界(BLEND_TARGET_NEEDS_A_BOUND)· 0–100(BLEND_TARGET_PCT_INVALID)·
--        下界不高于上界(BLEND_TARGET_BOUNDS_ORDER)· 一种金属一行(BLEND_TARGET_DUPLICATE_METAL)。
--     ④ 批次:至少一行(BLEND_NO_LINES);每一行恰好一批(BLEND_LINE_ONE_BATCH)、存在且没删(INBOUND_NOT_FOUND / OUTPUT_NOT_FOUND)、
--        单位是 kg(BLEND_LINE_UNIT_NOT_KG)、物料形态是配料收的(BLEND_LINE_FORM_NOT_BLENDABLE|<批号>|<形态或空>)、
--        计划公斤数 > 0(BLEND_LINE_KG_INVALID|<批号>)、一批一行(BLEND_LINE_DUPLICATE_BATCH|<批号>)。
--        【不】拒计划的公斤数超过这一批此刻的余量 —— 计划可以是为将来排的;真投的时候引擎照旧按余量拒。
--   然后整份替换:删掉这份计划原有的目标与批次,写入新的(变更记录逐行记下删与插)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.blending_plan_write_children(p_plan_id uuid, p_output_material_id uuid, p_source_contract_id uuid, p_targets jsonb, p_lines jsonb)
 RETURNS void
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_mat      record;
    v_el       jsonb;
    v_spec     contract_grade_specs%ROWTYPE;
    v_metal    text;
    v_min      numeric;
    v_max      numeric;
    v_metals   text[] := ARRAY[]::text[];
    v_ib       uuid;
    v_ob       uuid;
    v_kg       numeric;
    v_bcode    text;
    v_bunit    text;
    v_bform    text;
    v_batches  text[] := ARRAY[]::text[];
BEGIN
    -- ① 产出物料
    SELECT m.code, m.form_code, f.may_be_sold, f.name_zh, f.name_en INTO v_mat
      FROM materials m LEFT JOIN material_forms f ON f.code = m.form_code
     WHERE m.id = p_output_material_id AND m.deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATERIAL_NOT_FOUND|%', COALESCE(p_output_material_id::text, '?');
    END IF;
    IF v_mat.form_code IS NOT NULL AND v_mat.may_be_sold IS FALSE THEN
        RAISE EXCEPTION 'BLEND_OUTPUT_NOT_SALEABLE|%|%|%|%', v_mat.code, v_mat.form_code, v_mat.name_zh, v_mat.name_en
          USING HINT = '配料混出来的那一批必须是可以卖的形态(R5)。这一种物料的形态在法律上不许出售,所以不能是一份配料计划的产出。';
    END IF;
    IF v_mat.form_code IS NULL OR NOT EXISTS (SELECT 1 FROM operation_type_output_forms o
                                               WHERE o.operation_type_code = 'blending' AND o.form_code = v_mat.form_code) THEN
        RAISE EXCEPTION 'BLEND_OUTPUT_FORM_NOT_BLENDABLE|%|%', v_mat.code, COALESCE(v_mat.form_code, '')
          USING HINT = '配料只混出可售的粉料(黑粉、正极粉、负极粉 —— 配料这道工序声明的产出形态)。先给这种物料选对形态,或换一种物料。';
    END IF;

    -- ② 合同
    IF p_source_contract_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM contracts c WHERE c.id = p_source_contract_id) THEN
        RAISE EXCEPTION 'BLEND_CONTRACT_NOT_FOUND|%', p_source_contract_id;
    END IF;

    DELETE FROM blending_plan_targets WHERE plan_id = p_plan_id;
    DELETE FROM blending_plan_lines WHERE plan_id = p_plan_id;

    -- ③ 目标
    IF p_targets IS NULL AND p_source_contract_id IS NOT NULL THEN
        INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
        SELECT DISTINCT ON (s.metal) p_plan_id, s.metal, s.min_pct, s.max_pct, 'contract', s.id
          FROM contract_grade_specs s
         WHERE s.contract_id = p_source_contract_id
           AND (s.material_id IS NULL OR s.material_id = p_output_material_id)
         ORDER BY s.metal, s.material_id NULLS LAST;
    ELSIF p_targets IS NOT NULL THEN
        IF jsonb_typeof(p_targets) <> 'array' THEN
            RAISE EXCEPTION 'BLEND_TARGETS_INVALID';
        END IF;
        FOR v_el IN SELECT * FROM jsonb_array_elements(p_targets) LOOP
            IF NULLIF(v_el ->> 'grade_spec_id', '') IS NOT NULL THEN
                SELECT * INTO v_spec FROM contract_grade_specs s WHERE s.id = (v_el ->> 'grade_spec_id')::uuid;
                IF NOT FOUND OR p_source_contract_id IS NULL OR v_spec.contract_id <> p_source_contract_id THEN
                    RAISE EXCEPTION 'BLEND_TARGET_SPEC_NOT_FROM_CONTRACT|%', v_el ->> 'grade_spec_id'
                      USING HINT = '从合同抄的目标品位必须来自这份计划选的那一份合同。';
                END IF;
                IF v_spec.material_id IS NOT NULL AND v_spec.material_id <> p_output_material_id THEN
                    RAISE EXCEPTION 'BLEND_TARGET_SPEC_OTHER_MATERIAL|%|%', v_spec.metal,
                        (SELECT m.code FROM materials m WHERE m.id = v_spec.material_id)
                      USING HINT = '这一条品位规格是给另一种物料的,不适用于这份计划混出来的那一种。';
                END IF;
                v_metal := v_spec.metal;
                IF v_metal = ANY (v_metals) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_DUPLICATE_METAL|%', v_metal;
                END IF;
                INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
                VALUES (p_plan_id, v_spec.metal, v_spec.min_pct, v_spec.max_pct, 'contract', v_spec.id);
            ELSE
                v_metal := NULLIF(btrim(COALESCE(v_el ->> 'metal', '')), '');
                IF v_metal IS NULL OR NOT EXISTS (SELECT 1 FROM substances s WHERE s.code = v_metal) THEN
                    RAISE EXCEPTION 'METAL_INVALID|%', COALESCE(v_metal, '?');
                END IF;
                IF v_metal = ANY (v_metals) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_DUPLICATE_METAL|%', v_metal;
                END IF;
                v_min := NULLIF(v_el ->> 'min_pct', '')::numeric;
                v_max := NULLIF(v_el ->> 'max_pct', '')::numeric;
                IF v_min IS NULL AND v_max IS NULL THEN
                    RAISE EXCEPTION 'BLEND_TARGET_NEEDS_A_BOUND|%', v_metal
                      USING HINT = '一条两边都不设限的目标什么也没规定。至少填下界或上界。';
                END IF;
                IF (v_min IS NOT NULL AND (v_min < 0 OR v_min > 100)) OR (v_max IS NOT NULL AND (v_max < 0 OR v_max > 100)) THEN
                    RAISE EXCEPTION 'BLEND_TARGET_PCT_INVALID|%', v_metal;
                END IF;
                IF v_min IS NOT NULL AND v_max IS NOT NULL AND v_min > v_max THEN
                    RAISE EXCEPTION 'BLEND_TARGET_BOUNDS_ORDER|%|%|%', v_metal, v_min, v_max;
                END IF;
                INSERT INTO blending_plan_targets (plan_id, metal, min_pct, max_pct, source, source_grade_spec_id)
                VALUES (p_plan_id, v_metal, v_min, v_max, 'manual', NULL);
            END IF;
            v_metals := v_metals || v_metal;
        END LOOP;
    END IF;

    -- ④ 批次
    IF p_lines IS NULL OR jsonb_typeof(p_lines) <> 'array' OR jsonb_array_length(p_lines) = 0 THEN
        RAISE EXCEPTION 'BLEND_NO_LINES';
    END IF;
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_lines) LOOP
        v_ib := NULLIF(v_el ->> 'inbound_batch_id', '')::uuid;
        v_ob := NULLIF(v_el ->> 'output_batch_id', '')::uuid;
        IF (v_ib IS NULL) = (v_ob IS NULL) THEN
            RAISE EXCEPTION 'BLEND_LINE_ONE_BATCH';
        END IF;
        IF v_ib IS NOT NULL THEN
            SELECT b.code, b.unit, m.form_code INTO v_bcode, v_bunit, v_bform
              FROM inbound_batches b JOIN materials m ON m.id = b.material_id WHERE b.id = v_ib AND b.deleted_at IS NULL;
            IF NOT FOUND THEN RAISE EXCEPTION 'INBOUND_NOT_FOUND|%', v_ib; END IF;
        ELSE
            SELECT b.code, b.unit, m.form_code INTO v_bcode, v_bunit, v_bform
              FROM output_batches b JOIN materials m ON m.id = b.material_id WHERE b.id = v_ob AND b.deleted_at IS NULL;
            IF NOT FOUND THEN RAISE EXCEPTION 'OUTPUT_NOT_FOUND|%', v_ob; END IF;
        END IF;
        IF v_bunit IS DISTINCT FROM 'kg' THEN
            RAISE EXCEPTION 'BLEND_LINE_UNIT_NOT_KG|%|%', v_bcode, COALESCE(v_bunit, '?');
        END IF;
        IF v_bform IS NULL OR NOT EXISTS (SELECT 1 FROM operation_type_input_forms i
                                           WHERE i.operation_type_code = 'blending' AND i.form_code = v_bform) THEN
            RAISE EXCEPTION 'BLEND_LINE_FORM_NOT_BLENDABLE|%|%', v_bcode, COALESCE(v_bform, '')
              USING HINT = '配料只收可售的粉料(黑粉、正极粉、负极粉 —— 配料这道工序声明的投料形态)。';
        END IF;
        v_kg := NULLIF(v_el ->> 'planned_kg', '')::numeric;
        IF v_kg IS NULL OR v_kg <= 0 THEN
            RAISE EXCEPTION 'BLEND_LINE_KG_INVALID|%', v_bcode;
        END IF;
        IF v_bcode = ANY (v_batches) THEN
            RAISE EXCEPTION 'BLEND_LINE_DUPLICATE_BATCH|%', v_bcode;
        END IF;
        v_batches := v_batches || v_bcode;
        INSERT INTO blending_plan_lines (plan_id, inbound_batch_id, output_batch_id, planned_kg)
        VALUES (p_plan_id, v_ib, v_ob, v_kg);
    END LOOP;
END;
$function$;

-- db/functions/create_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19 · Q20,Tim):【建一份配料计划】—— action.wo_create(建工单的同一个码,Q19)。
--   生下来是 draft,编号 BLD-<建单那一年>-NNNN(next_blending_plan_code)。产出物料、合同、目标与批次的判据全在
--   blending_plan_write_children(与 amend_blending_plan 同一份)。
--   ★ 建单人之外没有一个真持有人持 action.wo_release,就不让它生下来(BLEND_NO_OTHER_RELEASER)—— 否则它是一张永远的草稿;
--     与 create_work_order 的 WO_NO_OTHER_RELEASER 同一句判据(real_role_grants · self_leg 按人认,跨账号;不看审批开关)。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.create_blending_plan(p_output_material_id uuid, p_lines jsonb, p_targets jsonb DEFAULT NULL::jsonb, p_source_contract_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_id   uuid;
    v_code text;
BEGIN
    PERFORM require_permission('action.wo_create');
    IF NOT EXISTS (SELECT 1
                     FROM role_permissions rp
                     JOIN roles r ON r.id = rp.role_id
                    CROSS JOIN LATERAL real_role_grants(r.code) g
                    WHERE rp.permission_code = 'action.wo_release'
                      AND self_leg(v_user, NULL::uuid, g.user_id) = 'none') THEN
        RAISE EXCEPTION 'BLEND_NO_OTHER_RELEASER'
          USING HINT = '建单人永远不能放行自己的配料计划,而此刻除你之外没有人持放行的码(action.wo_release)。请管理员先把这个码给另一个人。';
    END IF;

    v_code := next_blending_plan_code(CURRENT_DATE);
    INSERT INTO blending_plans (code, status, output_material_id, source_contract_id, notes, created_by, updated_by)
    VALUES (v_code, 'draft', p_output_material_id, p_source_contract_id, NULLIF(btrim(COALESCE(p_notes, '')), ''), v_user, v_user)
    RETURNING id INTO v_id;

    PERFORM blending_plan_write_children(v_id, p_output_material_id, p_source_contract_id, p_targets, p_lines);

    RETURN jsonb_build_object('plan_id', v_id, 'code', v_code, 'status', 'draft');
END;
$function$;

-- db/functions/amend_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19,Tim):【改一份草稿态的配料计划】—— action.wo_create(Q19:建与改同一个码)。
--   只有 draft 改得动(BLEND_PLAN_NOT_DRAFT|<编号>|<状态>)—— 放行过的计划冻住,要改就取消、重建。
--   表头(产出物料、合同、备注)就地改;目标与批次整份替换,判据与建单同一份(blending_plan_write_children)。
--   建单人不变:放行那一侧的四眼认的仍是建单人(created_by)。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.amend_blending_plan(p_plan_id uuid, p_output_material_id uuid, p_lines jsonb, p_targets jsonb DEFAULT NULL::jsonb, p_source_contract_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_plan blending_plans%ROWTYPE;
BEGIN
    PERFORM require_permission('action.wo_create');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status <> 'draft' THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_DRAFT|%|%', v_plan.code, v_plan.status
          USING HINT = '只有草稿改得动。放行过的计划冻住 —— 要改就取消它、重建一份。';
    END IF;

    UPDATE blending_plans
       SET output_material_id = p_output_material_id, source_contract_id = p_source_contract_id,
           notes = NULLIF(btrim(COALESCE(p_notes, '')), ''), updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    PERFORM blending_plan_write_children(p_plan_id, p_output_material_id, p_source_contract_id, p_targets, p_lines);

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'status', 'draft');
END;
$function$;

-- db/functions/release_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q19,Tim):【放行一份配料计划】—— action.wo_release(下达工单的同一个码);
--   【建单人永远不能放行】(forbid_self_approval,按人认 —— 与 release_work_order 同一句;只有 raiser 那一条腿,计划没有"说的是谁")。
--   只放行草稿(BLEND_PLAN_NOT_DRAFT);至少一条目标(BLEND_PLAN_NO_TARGETS)与一行批次(BLEND_NO_LINES)。
--   预测出界【不挡】放行(Q20:标出来,不拒)。不是一张审批单据(Q32:没有新审批)—— 四眼是工单那一种,不进审批引擎。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.release_blending_plan(p_plan_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_plan blending_plans%ROWTYPE;
BEGIN
    PERFORM require_permission('action.wo_release');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status <> 'draft' THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_DRAFT|%|%', v_plan.code, v_plan.status;
    END IF;
    PERFORM forbid_self_approval(v_plan.created_by, NULL::uuid, 'blending_plan');
    IF NOT EXISTS (SELECT 1 FROM blending_plan_targets t WHERE t.plan_id = p_plan_id) THEN
        RAISE EXCEPTION 'BLEND_PLAN_NO_TARGETS|%', v_plan.code
          USING HINT = '一份没有目标品位的配料计划没有东西可对 —— 先给至少一种金属一个界。';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM blending_plan_lines l WHERE l.plan_id = p_plan_id) THEN
        RAISE EXCEPTION 'BLEND_NO_LINES';
    END IF;

    UPDATE blending_plans
       SET status = 'released', released_at = now(), released_by = v_user, updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'status', 'released');
END;
$function$;

-- db/functions/cancel_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19,Tim):【取消一份配料计划】—— action.wo_create(建与改的码;取消一份计划是改它)。
--   草稿或已放行的都可以取消(BLEND_PLAN_NOT_CANCELLABLE|<编号>|<状态>:已执行的不行 —— 那一炉要走回滚申请);理由必填(BLEND_CANCEL_REASON_REQUIRED)。
--   返回 {plan_id, code, status}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.cancel_blending_plan(p_plan_id uuid, p_reason text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user uuid := auth.uid();
    v_plan blending_plans%ROWTYPE;
BEGIN
    PERFORM require_permission('action.wo_create');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status NOT IN ('draft', 'released') THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_CANCELLABLE|%|%', v_plan.code, v_plan.status
          USING HINT = '已执行的计划取消不了 —— 混出来的那一炉要撤,走回滚申请。';
    END IF;
    IF p_reason IS NULL OR btrim(p_reason) = '' THEN
        RAISE EXCEPTION 'BLEND_CANCEL_REASON_REQUIRED';
    END IF;

    UPDATE blending_plans
       SET status = 'cancelled', cancelled_at = now(), cancelled_by = v_user, cancel_reason = btrim(p_reason),
           updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'status', 'cancelled');
END;
$function$;

-- db/functions/execute_blending_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18 · Q19,Tim):【执行一份已放行的配料计划 —— 从计划页上,记一炉 blending】
--   码:action.processing_commit(Q19;提交一炉本来就要它,引擎自己再判一次)。只执行 released(BLEND_PLAN_NOT_RELEASED|<编号>|<状态>)。
--   ★ 这是 commit_processing_run 的一层外壳 —— MES-5a-1 拆去隔离的先例:引擎的签名【一个字不改】。
--     ① 每一行实际投了多少(p_actual = [{line_id, actual_kg}]):这份计划的每一行恰好一次(BLEND_ACTUAL_LINES_MISMATCH),
--        ≥ 0(BLEND_ACTUAL_KG_INVALID|<批号>);0 = 这一批这次没用上(不进投料腿);至少一行 > 0(BLEND_ACTUAL_NOTHING_FED)。
--        实际与计划可以不同(Q18)—— 差多少由 blending_plan_execution 照直印出来,不拒。
--     ② 混出来的那一批:产出物料 = 计划的产出物料,重量敲一个(p_weight_kg)或挑一条称重(p_weighing_id)—— 引擎照旧判称重、
--        开始 / 结束 / 班次、余量、安全状态(配料只收"已放电并核验")与"产出不多于投入"。
--     ③ 设事务级标记 evoltrya.blend_ctx = 这份计划,调引擎,用毕即清 —— processing_runs 上的守卫(guard_blending_run_from_plan)
--        因此只放行从这里记的 blending,别的任何路(新建加工单的表单、直接调引擎)按名拒 BLEND_RUN_FROM_PLAN_ONLY。
--     ④ 计划改成 executed,记下那一炉。
--   【含量不从预测写】(Q18):混出来那一批一行金属含量都不写 —— 它的含量只来自之后的化验(guard_blended_batch_metals_from_assay)。
--   返回 {plan_id, code, run_id, run_code, batch_id, batch_code, input_kg, output_kg}。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.execute_blending_plan(p_plan_id uuid, p_process_date date, p_started_at timestamp with time zone, p_ended_at timestamp with time zone, p_shift_code text, p_actual jsonb, p_weight_kg numeric DEFAULT NULL::numeric, p_weighing_id uuid DEFAULT NULL::uuid, p_notes text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user    uuid := auth.uid();
    v_plan    blending_plans%ROWTYPE;
    v_line    record;
    v_el      jsonb;
    v_kg      numeric;
    v_inputs  jsonb := '[]'::jsonb;
    v_seen    uuid[] := ARRAY[]::uuid[];
    v_n       integer;
    v_run     uuid;
    v_batch   uuid;
    v_bcode   text;
BEGIN
    PERFORM require_permission('action.processing_commit');
    SELECT * INTO v_plan FROM blending_plans WHERE id = p_plan_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_FOUND|%', COALESCE(p_plan_id::text, '?');
    END IF;
    IF v_plan.status <> 'released' THEN
        RAISE EXCEPTION 'BLEND_PLAN_NOT_RELEASED|%|%', v_plan.code, v_plan.status
          USING HINT = '只有放行过的计划执行得了:草稿先请另一个人放行;已执行或已取消的不能再执行。';
    END IF;

    -- ① 实际投料:这份计划的每一行恰好一次
    IF p_actual IS NULL OR jsonb_typeof(p_actual) <> 'array' THEN
        RAISE EXCEPTION 'BLEND_ACTUAL_LINES_MISMATCH|%', v_plan.code;
    END IF;
    FOR v_el IN SELECT * FROM jsonb_array_elements(p_actual) LOOP
        SELECT l.*, COALESCE(ib.code, ob.code) AS batch_code INTO v_line
          FROM blending_plan_lines l
          LEFT JOIN inbound_batches ib ON ib.id = l.inbound_batch_id
          LEFT JOIN output_batches ob ON ob.id = l.output_batch_id
         WHERE l.plan_id = p_plan_id AND l.id = NULLIF(v_el ->> 'line_id', '')::uuid;
        IF NOT FOUND OR v_line.id = ANY (v_seen) THEN
            RAISE EXCEPTION 'BLEND_ACTUAL_LINES_MISMATCH|%', v_plan.code
              USING HINT = '每一行计划都要说出这次实际投了多少(没用上就写 0),一行一次。';
        END IF;
        v_seen := v_seen || v_line.id;
        v_kg := NULLIF(v_el ->> 'actual_kg', '')::numeric;
        IF v_kg IS NULL OR v_kg < 0 THEN
            RAISE EXCEPTION 'BLEND_ACTUAL_KG_INVALID|%', v_line.batch_code;
        END IF;
        IF v_kg > 0 THEN
            v_inputs := v_inputs || jsonb_build_array(CASE WHEN v_line.inbound_batch_id IS NOT NULL
                THEN jsonb_build_object('inbound_batch_id', v_line.inbound_batch_id, 'quantity_consumed', v_kg)
                ELSE jsonb_build_object('output_batch_id', v_line.output_batch_id, 'quantity_consumed', v_kg) END);
        END IF;
    END LOOP;
    SELECT count(*) INTO v_n FROM blending_plan_lines l WHERE l.plan_id = p_plan_id;
    IF cardinality(v_seen) <> v_n THEN
        RAISE EXCEPTION 'BLEND_ACTUAL_LINES_MISMATCH|%', v_plan.code;
    END IF;
    IF jsonb_array_length(v_inputs) = 0 THEN
        RAISE EXCEPTION 'BLEND_ACTUAL_NOTHING_FED|%', v_plan.code;
    END IF;

    -- ②③ 经引擎记一炉 blending(标记只在这一句的前后存在)
    PERFORM set_config('evoltrya.blend_ctx', p_plan_id::text, true);
    v_run := commit_processing_run(
        p_process_date,
        COALESCE(NULLIF(btrim(COALESCE(p_notes, '')), ''), 'Blending plan ' || v_plan.code),
        NULL,
        v_inputs,
        jsonb_build_array(CASE WHEN p_weighing_id IS NOT NULL
                               THEN jsonb_build_object('material_id', v_plan.output_material_id, 'weighing_id', p_weighing_id)
                               ELSE jsonb_build_object('material_id', v_plan.output_material_id, 'weight_kg', p_weight_kg) END),
        'weight', NULL, NULL, 'blending', p_started_at, p_ended_at, p_shift_code, NULL, NULL, NULL);
    PERFORM set_config('evoltrya.blend_ctx', '', true);

    SELECT po.output_batch_id, ob.code INTO v_batch, v_bcode
      FROM processing_outputs po JOIN output_batches ob ON ob.id = po.output_batch_id WHERE po.run_id = v_run;

    -- ④ 计划记下那一炉
    UPDATE blending_plans
       SET status = 'executed', executed_at = now(), executed_by = v_user, run_id = v_run, updated_at = now(), updated_by = v_user
     WHERE id = p_plan_id;

    RETURN jsonb_build_object('plan_id', p_plan_id, 'code', v_plan.code, 'run_id', v_run,
                              'run_code', (SELECT r.code FROM processing_runs r WHERE r.id = v_run),
                              'batch_id', v_batch, 'batch_code', v_bcode,
                              'input_kg', (SELECT r.total_input FROM processing_runs r WHERE r.id = v_run),
                              'output_kg', (SELECT r.total_output FROM processing_runs r WHERE r.id = v_run));
END;
$function$;

-- db/functions/guard_blending_run_from_plan.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18,Tim):【配料那一炉只从配料计划上记】—— processing_runs 上的 BEFORE INSERT 守卫。
--   一炉的工序是 blending,而事务级标记 evoltrya.blend_ctx 不在(只有 execute_blending_plan 在调引擎的前后设它、用毕即清)→
--   按名拒 BLEND_RUN_FROM_PLAN_ONLY。新建加工单的表单本来就不列它(operation_types.started_from_run_page),这一道管的是不经表单的路:
--   直接调 commit_processing_run。连属主也一样。引擎的签名与函数体都没动。一炉的工序事后改不了(correct_run_header 不收这一栏,
--   直连改由 guard_processing_direct_write 拒),所以只守插入。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.guard_blending_run_from_plan()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.operation_type_code = 'blending'
       AND COALESCE(current_setting('evoltrya.blend_ctx', true), '') = '' THEN
        RAISE EXCEPTION 'BLEND_RUN_FROM_PLAN_ONLY'
          USING HINT = '配料那一炉只从一份已放行的配料计划的页面上执行(/operation/blending)。';
    END IF;
    RETURN NEW;
END;
$function$;

-- db/functions/guard_blended_batch_metals_from_assay.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18,Tim):【混出来那一批的含量只来自化验,绝不来自预测】—— output_batch_metals 上的 BEFORE INSERT / UPDATE 守卫。
--   这一批是一炉 blending 的产出,而写进来的一行不是 content_source = 'assay'(只有 apply_output_assay 写那一种,guard_batch_metals_assay_source
--   管着它的门)→ 按名拒 BLEND_CONTENT_FROM_ASSAY_ONLY|<批号>。人填的一个数、或从计划页抄过去的预测,都过不去。
--   ★ SECURITY DEFINER:它要读 processing_outputs / processing_runs 才认得出"这是混出来的那一批";以写入者的身份读,一个看不见加工的
--     产出编辑者会读到零行,而零行在这里就是"放行" —— 一支 void 守卫的沉默与通过是同一个字节(AGENTS.md 那一族)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.
CREATE OR REPLACE FUNCTION public.guard_blended_batch_metals_from_assay()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
    IF NEW.content_source IS DISTINCT FROM 'assay'
       AND EXISTS (SELECT 1 FROM processing_outputs po JOIN processing_runs r ON r.id = po.run_id
                    WHERE po.output_batch_id = NEW.output_batch_id AND r.operation_type_code = 'blending') THEN
        RAISE EXCEPTION 'BLEND_CONTENT_FROM_ASSAY_ONLY|%', (SELECT ob.code FROM output_batches ob WHERE ob.id = NEW.output_batch_id)
          USING HINT = '混出来的那一批的金属含量只来自化验:记一份化验,再应用它。计划页上的预测不是含量。';
    END IF;
    RETURN NEW;
END;
$function$;

-- ── 3 · 两支守卫上表(与 db/tables/processing_runs.sql · output_batch_metals.sql 逐字同一份)──────────────
CREATE TRIGGER trg_processing_runs_blending_from_plan
    BEFORE INSERT ON public.processing_runs
    FOR EACH ROW EXECUTE FUNCTION public.guard_blending_run_from_plan();

CREATE TRIGGER trg_output_batch_metals_blended_from_assay
    BEFORE INSERT OR UPDATE ON public.output_batch_metals
    FOR EACH ROW EXECUTE FUNCTION public.guard_blended_batch_metals_from_assay();

-- ── 4 · 一道新工序 blending 与它的形态、安全状态(与 db/tables/operation_type*.sql 的种子逐字同一份)──────────
INSERT INTO public.operation_types (code, name_en, name_zh, kind_code, resulting_safety_state_code, sort_order, notes, started_from_run_page) VALUES
    ('blending', 'Blending', '配料', 'transforming', NULL, 9,
     '【MES-5b-3 · MES-0 Q58】几批可售的粉料(黑粉 · 正极粉 · 负极粉)按一份配料计划混成一批,好对上一份合同的品位。只从配料计划的页面上起(execute_blending_plan,经 commit_processing_run 记这一炉),不在新建加工单的选单里;直接拿它记一炉按名拒(BLEND_RUN_FROM_PLAN_ONLY)。混出来那一批的含量只来自化验,不来自预测。', true);
INSERT INTO public.operation_type_input_forms (operation_type_code, form_code, notes) VALUES
    ('blending', 'black_mass', '【MES-5b-3】'),
    ('blending', 'cathode_powder', '【MES-5b-3】'),
    ('blending', 'anode_powder', '【MES-5b-3】');
INSERT INTO public.operation_type_output_forms (operation_type_code, form_code, notes) VALUES
    ('blending', 'black_mass', '【MES-5b-3】'),
    ('blending', 'cathode_powder', '【MES-5b-3】'),
    ('blending', 'anode_powder', '【MES-5b-3】');
INSERT INTO public.operation_type_safety_states (operation_type_code, safety_state_code, resolves, notes) VALUES
    ('blending', 'discharged_verified', false,
     '【MES-5b-3】受理、不解决。粉料混合不改变安全状态;混出来那一批的状态照产出批的规矩另记。');

-- ── 5 · 单据登记:BLD(与 db/tables/document_types.sql 那一行逐字同一份)──────────────────────────────
INSERT INTO public.document_types (key, prefix, table_name, numbering, sequence_name, route, link_mode, label_column, match_columns, view_permission) VALUES
    ('blending_plan', 'BLD', 'blending_plans', 'gapless', NULL, '/operation/blending', 'detail', 'notes', ARRAY['notes']::text[], ARRAY['module.processing.view']::text[]);

-- ── 6 · 换掉的函数(镜像原样,同签名):审计主语登记 —— blending_plan 与它的两张子表 ─────────────────────

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
--   operation_type → /operation/operation-types/[code] requireModule(MOD.processing) = module.processing.view(MES-4a)
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
-- MES-5a-2(2026-10-08,MES-5a Step 0 Q31,Tim):
--   electricity_allocation → /finance/electricity/[id]   requireModule(MOD.finance) = module.finance.view
--                     成员 electricity_allocation_lines(一炉一行;它在加工单上也出现,但家在这里)。金额由 change_log_mask_rules 遮(data.view_prices)。
--                     MES-5b-2:成员加 electricity_allocation_reversals(一张单最多一行;它在它覆盖过的每一炉上也出现,家在这里)。
-- MES-5b-3(2026-10-09):
--   blending_plan   → /operation/blending/[id]         requireModule(MOD.processing)  = module.processing.view
--                     成员 blending_plan_targets(目标品位)与 blending_plan_lines(候选批次),都住在这里。没有金额,不遮。
--                     (MES-5b-2 也把 operation_type_output_forms 挂到 operation_type 下 —— V37 的改动从此在工序页自己的审计记录上。)
--   electricity_settings   → /finance/electricity 上的 V25 那一块  module.finance.view;单行设置作根(M5)
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
        -- MES-4a(2026-10-07,MES-4a Step 0 Q33):一道工序 —— 它的参数与指标、挂着的机器、配方与每一版、容差(根行自己那几列);
        --   页面 /operation/operation-types/[code],门 module.processing.view;根键 code(成员按 operation_type_code 挂在它下面)。
        --   异常事件种类字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('operation_type',    ARRAY['module.processing.view'],    'operation_types',    'code', 'table', NULL),
        ('dictionary_processing_event_types', ARRAY['module.processing.view'], 'processing_event_types', 'code', 'collection', NULL),
        --   班次字典 —— MES-4a 把它放进 /settings/dictionaries(新的"时刻"字段:V6 · V7 的去处),于是它也有一段清单块的记录。
        ('dictionary_shifts', ARRAY['module.processing.view'], 'shifts', 'code', 'collection', NULL),
        -- MES-4b(2026-10-07,MES-4b Step 0 Q3 · Q21):电芯结构字典与交叉污染流字典 —— 与别的字典同一个形状(清单块,/settings/dictionaries)。
        ('dictionary_cell_constructions', ARRAY['module.processing.view'], 'cell_constructions', 'code', 'collection', NULL),
        ('dictionary_contamination_streams', ARRAY['module.processing.view'], 'contamination_streams', 'code', 'collection', NULL),
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
        ('weighbridge_ticket',  ARRAY['module.inbound.view', 'module.logistics.view'], 'weighbridge_tickets', 'id', 'table', NULL),
        -- MES-5a-2(2026-10-08,MES-5a Step 0 Q31):一张电费单的分摊(/finance/electricity/[id],财务查看码)· 分摊的设定(V25,单行设置作根)
        ('electricity_allocation', ARRAY['module.finance.view'],  'electricity_allocations', 'id', 'table', NULL),
        ('electricity_settings',   ARRAY['module.finance.view'],  'electricity_settings',    'id', 'table', NULL),
        -- MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划(/operation/blending/[id],加工查看码 —— 与表的读策略同一个)
        ('blending_plan',          ARRAY['module.processing.view'], 'blending_plans',        'id', 'table', NULL)
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
        ('storage_location',   2, 'label_prints',           'storage_locations',  'storage_location_id', '{}'::jsonb, 'down', true, false),
        -- ── MES-4a(2026-10-07,MES-4a Step 0 Q33):加工单 —— 记下的值、异常事件、结平、表头更正(都只追加,都按 run_id 挂)。
        --    一道工序 —— 它的字段、挂着的机器、配方(按 operation_type_code 挂在根行的 code 下)与配方的每一版(挂在配方下)。──
        ('processing_run',     9, 'processing_run_values',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    10, 'processing_run_events',      'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    11, 'processing_run_closures',    'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('processing_run',    12, 'processing_run_corrections', 'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('operation_type',     1, 'operation_type_fields',      'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     2, 'operation_type_equipment',   'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     3, 'process_recipes',            'operation_types',  'operation_type_code', '{}'::jsonb, 'down', true, true),
        ('operation_type',     4, 'process_recipe_versions',    'process_recipes',  'recipe_id',           '{}'::jsonb, 'down', true, true),
        -- ── MES-4b(2026-10-07,MES-4b Step 0 Q28):交叉污染抽检 —— 挂在它那一炉(家)与它抽的那一批极片下面(receipt_ceiling_checks 的先例:
        --    一张表挂两个主语,只有一处是家)。没抽的那一种没有批次,只出现在加工单上。──
        ('processing_run',    13, 'contamination_checks',       'processing_runs',  'run_id',              '{}'::jsonb, 'down', true, true),
        ('output_batch',      39, 'contamination_checks',       'output_batches',   'output_batch_id',     '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-1(2026-10-08,MES-5a Step 0 Q31):放电 —— 逐模组结果、通道分配、拆去隔离的模组。家在那一炉(结果与分配挂在放电那一炉,
        --    拆分挂在拆分那一炉);也出现在它们说的那一批上,结果还出现在记下它的放电柜上(device_id;今天手工录入不填它)。──
        ('processing_run',    14, 'discharge_module_results',      'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    15, 'discharge_channel_assignments', 'processing_runs', 'run_id',           '{}'::jsonb, 'down', true, true),
        ('processing_run',    16, 'discharge_module_splits',       'processing_runs', 'split_run_id',     '{}'::jsonb, 'down', true, true),
        ('inbound_batch',     42, 'discharge_module_results',      'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('inbound_batch',     43, 'discharge_module_splits',       'inbound_batches', 'inbound_batch_id', '{}'::jsonb, 'down', true, false),
        ('output_batch',      40, 'discharge_module_results',      'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('output_batch',      41, 'discharge_module_splits',       'output_batches',  'output_batch_id',  '{}'::jsonb, 'down', true, false),
        ('device',             3, 'discharge_module_results',      'devices',         'device_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5a-2(2026-10-08,MES-5a Step 0 Q31):电表读数住在那台电表下;一张电费单分给一炉的那一份住在那张单下,也出现在那一炉上。──
        ('device',             4, 'meter_readings',                'devices',                 'device_id',     '{}'::jsonb, 'down', true, true),
        ('electricity_allocation', 1, 'electricity_allocation_lines', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    17, 'electricity_allocation_lines',  'processing_runs',         'run_id',        '{}'::jsonb, 'down', true, false),
        -- ── MES-5b-2(2026-10-09,MES-5b Step 0 Q32 · Q34;MES5B1-V37-NOT-ON-OPERATION-TRAIL,Tim):一张电费单的撤回住在那张单下,
        --    也出现在它覆盖过的每一炉上(经那一炉的那一行往上一跳到那张分摊 —— 垫脚石,自己的改动不进来 —— 再往下到撤回)。
        --    一道工序每一种产出形态的预期得率(V37)住在那道工序下(按 operation_type_code 挂在根行的 code 下,与它的字段同形)。──
        ('electricity_allocation', 2, 'electricity_allocation_reversals', 'electricity_allocations', 'allocation_id', '{}'::jsonb, 'down', true, true),
        ('processing_run',    18, 'electricity_allocations',          'electricity_allocation_lines', 'allocation_id', '{}'::jsonb, 'up',   false, false),
        ('processing_run',    19, 'electricity_allocation_reversals', 'electricity_allocations',      'allocation_id', '{}'::jsonb, 'down', true, false),
        ('operation_type',     5, 'operation_type_output_forms',      'operation_types',              'operation_type_code', '{}'::jsonb, 'down', true, true),
        -- ── MES-5b-3(2026-10-09,MES-5b Step 0 Q32 · Q35):一份配料计划的目标品位与候选批次都住在那份计划下。──
        ('blending_plan',      1, 'blending_plan_targets',            'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true),
        ('blending_plan',      2, 'blending_plan_lines',              'blending_plans',               'plan_id',             '{}'::jsonb, 'down', true, true)
        -- ── 评审轮次(清单块,Q6:开轮铺下的评审不挂进来)· 评分刻度(M11 集合)· KPI 条目(清单块):没有成员 ──────────────
        -- ── 公司资料 · 现金预测 · 预测的常设行 · 银行导入模板:没有成员(预测作废时被谁取代,是旧那一张自己那几列说的;
        --    不经 superseded_by 自连 —— 管理包的同一个理由)
    ) AS m(subject, ord, table_name, parent_table, fk_column, match, hop, shown, home);
$function$;

-- ── 7 · 新视图(镜像原样):含量底表 · 逐行含量 · 预测 · 计划与实际 · 之后的化验 ───────────────────────

-- db/views/blending_plan_line_metals_all.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19,Tim):【一份配料计划的每一行 × 那一批此刻的每一种金属含量,连同出处】—— 属主权限,SELECT 已收回。
--   出处照它自己那张表记的说:assay(实验室,source_assay_id 指着那份化验)· manual(人填的)· unknown(PROC-1 之前的进料行,出处没记 ——
--   不猜成任何一种)。一行一种金属都没有的批次照样出一行(metal 为空),好让预测数得出"这一行没量过"。
--   门在两个读者里:blending_plan_line_metals(逐行,含量按那一批自己的查看码遮)与 blending_plan_prediction(加权平均)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_line_metals_all WITH (security_invoker = off) AS
 SELECT l.id AS line_id,
    l.plan_id,
        CASE
            WHEN l.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(l.inbound_batch_id, l.output_batch_id) AS batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    l.planned_kg,
    m.metal,
    m.content_pct,
        CASE
            WHEN m.metal IS NULL THEN NULL::text
            ELSE COALESCE(m.content_source, 'unknown'::text)
        END AS content_source,
    m.source_assay_id
   FROM blending_plan_lines l
     LEFT JOIN inbound_batches ib ON ib.id = l.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = l.output_batch_id
     LEFT JOIN LATERAL ( SELECT x.metal,
            x.content_pct,
            x.content_source,
            x.source_assay_id
           FROM inbound_batch_metals x
          WHERE x.inbound_batch_id = l.inbound_batch_id
        UNION ALL
         SELECT y.metal,
            y.content_pct,
            y.content_source,
            y.source_assay_id
           FROM output_batch_metals y
          WHERE y.output_batch_id = l.output_batch_id) m ON true;

COMMENT ON VIEW public.blending_plan_line_metals_all IS
    'MES-5b-3:配料计划每一行 × 那一批此刻的每一种金属含量与出处(assay / manual / unknown)。属主权限,authenticated 读不到 —— 经 blending_plan_line_metals 与 blending_plan_prediction 读。';

REVOKE ALL ON public.blending_plan_line_metals_all FROM authenticated, anon;

-- db/views/blending_plan_line_metals.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q19,Tim):【配料计划的每一行与那一批的金属含量 —— 带门的外壳】。计划页的"候选批次"一段读它。
--   门:module.processing.view(计划的读码)。★ 含量与出处只给【看得见那一批】的读者(Q19):进料批要 module.inbound.view,产出批要
--   module.output.view;看不见的读到 NULL 而 content_restricted 为真 —— 屏幕上是「受限」,不是空,也不是 0(AGENTS.md 决定 3 的边界:
--   标签跟着单据走,含量不跟)。批号与计划的公斤数不遮(那是计划自己的事实)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_line_metals WITH (security_invoker = off) AS
 SELECT line_id,
    plan_id,
    batch_kind,
    batch_id,
    batch_code,
    planned_kg,
    metal,
        CASE
            WHEN v.visible THEN content_pct
            ELSE NULL::numeric
        END AS content_pct,
        CASE
            WHEN v.visible THEN content_source
            ELSE NULL::text
        END AS content_source,
        CASE
            WHEN v.visible THEN source_assay_id
            ELSE NULL::uuid
        END AS source_assay_id,
    NOT v.visible AS content_restricted
   FROM blending_plan_line_metals_all a
     CROSS JOIN LATERAL ( SELECT
                CASE a.batch_kind
                    WHEN 'inbound'::text THEN has_permission('module.inbound.view'::text)
                    ELSE has_permission('module.output.view'::text)
                END AS visible) v
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.blending_plan_line_metals IS
    'MES-5b-3:配料计划的每一行与那一批的金属含量,带门(module.processing.view)。含量与出处只给持那一批查看码的读者(进料 module.inbound.view / 产出 module.output.view),否则 NULL 且 content_restricted。';

GRANT SELECT ON public.blending_plan_line_metals TO authenticated;
REVOKE ALL ON public.blending_plan_line_metals FROM anon;

-- db/views/blending_plan_prediction.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q17 · Q19 · Q20,Tim):【一份配料计划的预测成分 —— 每一种金属一行,算出来的,不落盘】。
--   金属 = 这份计划的目标金属 ∪ 任何一行批次此刻量过的金属。
--   预测 = 按计划公斤数加权的平均:Σ(planned_kg × content_pct) ÷ Σ planned_kg,【只在每一行都量过这种金属时】才算;
--   任何一行没有这种金属 → predicted_pct 为 NULL、not_measured 为真(屏幕上"没量过",不是 0 —— 少一行就把平均算歪,而且算歪的方向
--   恰好是看起来更合格的那一边)。出处数出来:几行来自化验、几行人填、几行出处不明。
--   出界只标出来,不拒(Q20):flag = below_min / above_max / within;没有目标的金属、或预测算不出 → NULL。比的是未取整的值(屏幕取两位)。
--   ★ 门:module.processing.view。★ 预测本身由各行的含量算出 —— 一行的计划,预测【就是】那一批的含量。所以读者只要看不见其中任何一批
--     (进料批 module.inbound.view / 产出批 module.output.view),预测、出处计数与旗都是 NULL,content_restricted 为真(「受限」)。
--     目标的两个界不遮(那是计划自己的事实)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_prediction WITH (security_invoker = off) AS
 WITH plan_lines AS (
         SELECT l.plan_id,
            count(*) AS line_count,
            sum(l.planned_kg) AS planned_kg,
            bool_or(l.inbound_batch_id IS NOT NULL) AS any_inbound,
            bool_or(l.output_batch_id IS NOT NULL) AS any_output
           FROM blending_plan_lines l
          GROUP BY l.plan_id
        ), plan_metals AS (
         SELECT t.plan_id,
            t.metal
           FROM blending_plan_targets t
        UNION
         SELECT a.plan_id,
            a.metal
           FROM blending_plan_line_metals_all a
          WHERE a.metal IS NOT NULL
        ), calc AS (
         SELECT pm.plan_id,
            pm.metal,
            pl.line_count,
            pl.planned_kg,
            pl.any_inbound,
            pl.any_output,
            count(a.line_id) AS lines_measured,
            count(a.line_id) FILTER (WHERE a.content_source = 'assay'::text) AS lines_from_assay,
            count(a.line_id) FILTER (WHERE a.content_source = 'manual'::text) AS lines_manual,
            count(a.line_id) FILTER (WHERE a.content_source = 'unknown'::text) AS lines_source_unknown,
            sum(a.planned_kg * a.content_pct) AS weighted_sum
           FROM plan_metals pm
             LEFT JOIN plan_lines pl ON pl.plan_id = pm.plan_id
             LEFT JOIN blending_plan_line_metals_all a ON a.plan_id = pm.plan_id AND a.metal = pm.metal
          GROUP BY pm.plan_id, pm.metal, pl.line_count, pl.planned_kg, pl.any_inbound, pl.any_output
        ), pred AS (
         SELECT c.plan_id,
            c.metal,
            c.line_count,
            c.planned_kg,
            c.any_inbound,
            c.any_output,
            c.lines_measured,
            c.lines_from_assay,
            c.lines_manual,
            c.lines_source_unknown,
                CASE
                    WHEN c.line_count > 0 AND c.lines_measured = c.line_count THEN c.weighted_sum / c.planned_kg
                    ELSE NULL::numeric
                END AS predicted_pct,
            COALESCE(c.line_count, 0) = 0 OR c.lines_measured < c.line_count AS not_measured,
            t.min_pct,
            t.max_pct,
            t.source AS target_source,
            t.metal IS NOT NULL AS has_target
           FROM calc c
             LEFT JOIN blending_plan_targets t ON t.plan_id = c.plan_id AND t.metal = c.metal
        )
 SELECT p.plan_id,
    p.metal,
    p.has_target,
    p.min_pct,
    p.max_pct,
    p.target_source,
    COALESCE(p.line_count, 0) AS line_count,
    p.planned_kg,
        CASE
            WHEN v.visible THEN p.lines_measured
            ELSE NULL::bigint
        END AS lines_measured,
        CASE
            WHEN v.visible THEN p.lines_from_assay
            ELSE NULL::bigint
        END AS lines_from_assay,
        CASE
            WHEN v.visible THEN p.lines_manual
            ELSE NULL::bigint
        END AS lines_manual,
        CASE
            WHEN v.visible THEN p.lines_source_unknown
            ELSE NULL::bigint
        END AS lines_source_unknown,
        CASE
            WHEN v.visible THEN p.predicted_pct
            ELSE NULL::numeric
        END AS predicted_pct,
        CASE
            WHEN v.visible THEN p.not_measured
            ELSE NULL::boolean
        END AS not_measured,
        CASE
            WHEN NOT v.visible OR p.predicted_pct IS NULL OR NOT p.has_target THEN NULL::text
            WHEN p.min_pct IS NOT NULL AND p.predicted_pct < p.min_pct THEN 'below_min'::text
            WHEN p.max_pct IS NOT NULL AND p.predicted_pct > p.max_pct THEN 'above_max'::text
            ELSE 'within'::text
        END AS flag,
    NOT v.visible AS content_restricted
   FROM pred p
     CROSS JOIN LATERAL ( SELECT (NOT COALESCE(p.any_inbound, false) OR has_permission('module.inbound.view'::text))
                             AND (NOT COALESCE(p.any_output, false) OR has_permission('module.output.view'::text)) AS visible) v
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.blending_plan_prediction IS
    'MES-5b-3:配料计划的预测成分,每种金属一行(目标金属 ∪ 量过的金属):按计划公斤数加权的平均,任何一行没量过这种金属就是 NULL(not_measured);出处计数;出界只标(below_min / above_max / within),不拒。门 module.processing.view;看不见其中任何一批的读者,预测、计数与旗都是 NULL(content_restricted)。';

GRANT SELECT ON public.blending_plan_prediction TO authenticated;
REVOKE ALL ON public.blending_plan_prediction FROM anon;

-- db/views/blending_plan_execution.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18,Tim):【计划的公斤数与实际投的公斤数,逐行并排,差多少照直说】。
--   实际 = 执行那一炉在这一批上的投料腿(processing_inputs.quantity_consumed)—— 不另存一份(blending_plan_lines 的表注)。
--   计划还没执行:actual_kg 与 difference_kg 为 NULL;执行了而这一批这次没用上:actual_kg = 0、difference_kg = −计划。
--   那一炉的状态一并给出(committed / reversed)—— 回滚过的那一炉,数字照旧是它当时的投料,页面说它已回滚。
--   只有公斤数,没有含量,所以不遮;门 module.processing.view(计划与加工单的读码)。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_execution WITH (security_invoker = off) AS
 SELECT l.plan_id,
    l.id AS line_id,
        CASE
            WHEN l.inbound_batch_id IS NOT NULL THEN 'inbound'::text
            ELSE 'output'::text
        END AS batch_kind,
    COALESCE(l.inbound_batch_id, l.output_batch_id) AS batch_id,
    COALESCE(ib.code, ob.code) AS batch_code,
    l.planned_kg,
        CASE
            WHEN p.run_id IS NULL THEN NULL::numeric
            ELSE COALESCE(fed.qty, 0::numeric)
        END AS actual_kg,
        CASE
            WHEN p.run_id IS NULL THEN NULL::numeric
            ELSE COALESCE(fed.qty, 0::numeric) - l.planned_kg
        END AS difference_kg,
    p.run_id,
    r.code AS run_code,
    r.status AS run_status
   FROM blending_plan_lines l
     JOIN blending_plans p ON p.id = l.plan_id
     LEFT JOIN processing_runs r ON r.id = p.run_id
     LEFT JOIN inbound_batches ib ON ib.id = l.inbound_batch_id
     LEFT JOIN output_batches ob ON ob.id = l.output_batch_id
     LEFT JOIN LATERAL ( SELECT sum(pi.quantity_consumed) AS qty
           FROM processing_inputs pi
          WHERE pi.run_id = p.run_id
            AND (pi.inbound_batch_id = l.inbound_batch_id OR pi.output_batch_id = l.output_batch_id)) fed ON true
  WHERE has_permission('module.processing.view'::text);

COMMENT ON VIEW public.blending_plan_execution IS
    'MES-5b-3:配料计划逐行的计划公斤数、执行那一炉在这一批上实际投的公斤数与差(实际 − 计划),连同那一炉的编号与状态。门 module.processing.view;只有公斤数,不遮。';

GRANT SELECT ON public.blending_plan_execution TO authenticated;
REVOKE ALL ON public.blending_plan_execution FROM anon;

-- db/views/blending_plan_outcome.sql
-- MES-5b-3(2026-10-09,MES-5b Step 0 Q18 · Q20,Tim):【混出来的那一批,之后的化验对着计划的目标品位】—— 每一条目标一行,只对执行过的计划。
--   比的是那一批【最新的一份有效化验】:没删、没被取代,按化验日、再按化验编号(ASY- 按年无洞,排得出先后)取最后一份。
--   那份化验记下了就比,不必先"应用"(应用是成本那一侧的事;Q20 说的是"之后的化验")。
--   verdict:not_assayed(那一批还没有化验)· metal_not_in_assay(化验里没有这种金属)· below_min · above_max · within。
--   比的是化验原样的数(它的 weight_basis 一并给出:as_received / dry),不换算 —— 与 contract_grade_breaches 同一个比法。
--   ★ 门:module.processing.view。含量、化验编号与判词只给持 module.output.view 的读者(那一批是一批产出,Q19);否则 NULL 且
--     content_restricted 为真。批号与目标的两个界不遮。
-- NOTE: introduced by db/migrations/2026-10-09-mes5b3-blending.sql.

CREATE VIEW public.blending_plan_outcome WITH (security_invoker = off) AS
 SELECT p.id AS plan_id,
    t.metal,
    t.min_pct,
    t.max_pct,
    p.run_id,
    r.status AS run_status,
    po.output_batch_id AS batch_id,
    ob.code AS batch_code,
        CASE
            WHEN v.visible THEN a.id
            ELSE NULL::uuid
        END AS assay_id,
        CASE
            WHEN v.visible THEN a.code
            ELSE NULL::text
        END AS assay_code,
        CASE
            WHEN v.visible THEN a.assay_date
            ELSE NULL::date
        END AS assay_date,
        CASE
            WHEN v.visible THEN a.weight_basis
            ELSE NULL::text
        END AS weight_basis,
        CASE
            WHEN v.visible THEN m.content_pct
            ELSE NULL::numeric
        END AS content_pct,
        CASE
            WHEN NOT v.visible THEN NULL::text
            WHEN a.id IS NULL THEN 'not_assayed'::text
            WHEN m.content_pct IS NULL THEN 'metal_not_in_assay'::text
            WHEN t.min_pct IS NOT NULL AND m.content_pct < t.min_pct THEN 'below_min'::text
            WHEN t.max_pct IS NOT NULL AND m.content_pct > t.max_pct THEN 'above_max'::text
            ELSE 'within'::text
        END AS verdict,
    NOT v.visible AS content_restricted
   FROM blending_plans p
     JOIN blending_plan_targets t ON t.plan_id = p.id
     JOIN processing_runs r ON r.id = p.run_id
     LEFT JOIN processing_outputs po ON po.run_id = p.run_id
     LEFT JOIN output_batches ob ON ob.id = po.output_batch_id
     LEFT JOIN LATERAL ( SELECT x.id,
            x.code,
            x.assay_date,
            x.weight_basis
           FROM assay_results x
          WHERE x.output_batch_id = po.output_batch_id AND x.deleted_at IS NULL AND x.superseded_by IS NULL
          ORDER BY x.assay_date DESC, x.code DESC
         LIMIT 1) a ON true
     LEFT JOIN assay_result_metals m ON m.assay_result_id = a.id AND m.metal = t.metal
     CROSS JOIN LATERAL ( SELECT has_permission('module.output.view'::text) AS visible) v
  WHERE p.run_id IS NOT NULL AND has_permission('module.processing.view'::text);

COMMENT ON VIEW public.blending_plan_outcome IS
    'MES-5b-3:执行过的配料计划,混出来那一批最新一份有效化验(没删、没被取代,按化验日与编号取最后一份)对着每一条目标:not_assayed / metal_not_in_assay / below_min / above_max / within。门 module.processing.view;含量、化验与判词只给持 module.output.view 的读者(否则 content_restricted)。';

GRANT SELECT ON public.blending_plan_outcome TO authenticated;
REVOKE ALL ON public.blending_plan_outcome FROM anon;

-- ── 8 · 变更记录的绑定(与 db/views/zzz_change_log_triggers.sql 逐字同一份)──
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.blending_plans
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.blending_plans
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.blending_plan_targets
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.blending_plan_targets
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();
CREATE TRIGGER zzz_change_log AFTER INSERT OR UPDATE OR DELETE ON public.blending_plan_lines
    FOR EACH ROW EXECUTE FUNCTION public.change_log_capture('id');
CREATE TRIGGER zzz_change_log_truncate AFTER TRUNCATE ON public.blending_plan_lines
    FOR EACH STATEMENT EXECUTE FUNCTION public.change_log_capture();

-- ── 9 · 并入:admin 持 module.tasks.view_all(Tim 2026-10-09;关掉 MES5B1C-ADMIN-TASKS-VIEW-ALL-UNRULED)—— 本刀唯一的一处授权改动 ──
INSERT INTO public.role_permissions (role_id, permission_code)
SELECT r.id, 'module.tasks.view_all' FROM roles r WHERE r.code = 'admin'
ON CONFLICT (role_id, permission_code) DO NOTHING;

-- ── 10 · 函数权限(与 zzz_function_grants.sql 同一套话;apply_migration.sh 之后还会整份重放)──────────
REVOKE EXECUTE ON FUNCTION public.create_blending_plan(uuid, jsonb, jsonb, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_blending_plan(uuid, jsonb, jsonb, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.amend_blending_plan(uuid, uuid, jsonb, jsonb, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.amend_blending_plan(uuid, uuid, jsonb, jsonb, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.release_blending_plan(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.release_blending_plan(uuid) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.cancel_blending_plan(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.cancel_blending_plan(uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.next_blending_plan_code(date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.next_blending_plan_code(date) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb) TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_blending_run_from_plan() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_blending_run_from_plan() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.guard_blended_batch_metals_from_assay() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guard_blended_batch_metals_from_assay() TO authenticated, service_role;
REVOKE EXECUTE ON FUNCTION public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb) FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_blending_run_from_plan() FROM authenticated;
REVOKE EXECUTE ON FUNCTION public.guard_blended_batch_metals_from_assay() FROM authenticated;

-- ── 11 · 自证 ────────────────────────────────────────────────────────────
CREATE FUNCTION pg_temp.mes5b3_pending_decider_check(p_after boolean DEFAULT true)
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

CREATE TEMP TABLE mes5b3_pending_after ON COMMIT DROP AS
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
    -- ① 授权:恰好多了 admin:module.tasks.view_all 一行,别的一行没动;admin 持目录里每一个码
    SELECT string_agg(x, ', ' ORDER BY x) INTO v_bad FROM (
        (SELECT r.code || ':' || rp.permission_code AS x FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
         EXCEPT SELECT role_code || ':' || permission_code FROM mes5b3_grants_before)
        UNION ALL
        (SELECT '-' || role_code || ':' || permission_code FROM mes5b3_grants_before
         EXCEPT SELECT '-' || r.code || ':' || rp.permission_code FROM role_permissions rp JOIN roles r ON r.id = rp.role_id)) d;
    IF v_bad IS DISTINCT FROM 'admin:module.tasks.view_all' THEN RAISE EXCEPTION 'MES5B3_PROOF|grant change is not exactly admin:module.tasks.view_all: %', v_bad; END IF;
    IF EXISTS (SELECT 1 FROM permissions p WHERE NOT EXISTS (SELECT 1 FROM role_permissions rp JOIN roles r ON r.id = rp.role_id
                                                             WHERE r.code = 'admin' AND rp.permission_code = p.code)) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|admin does not hold every code';
    END IF;
    -- 每一个角色仍满足"动作码蕴含查看码"(MES-5b-1 的规矩)
    SELECT string_agg(r.code || '->' || rp.permission_code, ', ') INTO v_bad
      FROM role_permissions rp JOIN roles r ON r.id = rp.role_id JOIN permissions p ON p.code = rp.permission_code
     WHERE p.requires_view_any IS NOT NULL AND cardinality(p.requires_view_any) > 0
       AND NOT EXISTS (SELECT 1 FROM role_permissions v WHERE v.role_id = rp.role_id AND v.permission_code = ANY (p.requires_view_any));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B3_PROOF|action-implies-view violated: %', v_bad; END IF;

    -- ② 审批开关没被碰;七个账号一个都没被停、没有新账号
    IF NOT (SELECT approvals_enabled FROM finance_settings) THEN RAISE EXCEPTION 'MES5B3_PROOF|approvals switched off'; END IF;
    IF EXISTS ((SELECT id, email, banned_until FROM auth.users EXCEPT SELECT id, email, banned_until FROM mes5b3_accounts_before)
               UNION ALL
               (SELECT id, email, banned_until FROM mes5b3_accounts_before EXCEPT SELECT id, email, banned_until FROM auth.users)) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|an account changed';
    END IF;

    -- ③ 在途单据一张不少、一张不多;既有的行逐字未变
    IF EXISTS ((SELECT b.k, b.id FROM mes5b3_pending_before b EXCEPT SELECT a.k, a.id FROM mes5b3_pending_after a)
               UNION ALL
               (SELECT a.k, a.id FROM mes5b3_pending_after a EXCEPT SELECT b.k, b.id FROM mes5b3_pending_before b)) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|a pending document changed state';
    END IF;
    IF (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_runs t) IS DISTINCT FROM (SELECT processing_runs FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_inputs t) IS DISTINCT FROM (SELECT processing_inputs FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_outputs t) IS DISTINCT FROM (SELECT processing_outputs FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inbound_batches t) IS DISTINCT FROM (SELECT inbound_batches FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM output_batches t) IS DISTINCT FROM (SELECT output_batches FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inbound_batch_metals t) IS DISTINCT FROM (SELECT inbound_batch_metals FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM output_batch_metals t) IS DISTINCT FROM (SELECT output_batch_metals FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM assay_results t) IS DISTINCT FROM (SELECT assay_results FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM assay_result_metals t) IS DISTINCT FROM (SELECT assay_result_metals FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM inventory_movements t) IS DISTINCT FROM (SELECT inventory_movements FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_entries t) IS DISTINCT FROM (SELECT journal_entries FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM journal_lines t) IS DISTINCT FROM (SELECT journal_lines FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM expenses t) IS DISTINCT FROM (SELECT expenses FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payments t) IS DISTINCT FROM (SELECT payments FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM payment_allocations t) IS DISTINCT FROM (SELECT payment_allocations FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM work_orders t) IS DISTINCT FROM (SELECT work_orders FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM devices t) IS DISTINCT FROM (SELECT devices FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM materials t) IS DISTINCT FROM (SELECT materials FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM contracts t) IS DISTINCT FROM (SELECT contracts FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM contract_grade_specs t) IS DISTINCT FROM (SELECT contract_grade_specs FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM material_forms t) IS DISTINCT FROM (SELECT material_forms FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_run_closures t) IS DISTINCT FROM (SELECT processing_run_closures FROM mes5b3_rows_before)
       OR (SELECT md5(COALESCE(string_agg(to_jsonb(t)::text, '|' ORDER BY to_jsonb(t)::text), '')) FROM processing_run_losses t) IS DISTINCT FROM (SELECT processing_run_losses FROM mes5b3_rows_before) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|a pre-existing run, leg, batch, metal content, assay, movement, journal, expense, payment, work order, device, material or contract changed';
    END IF;

    -- ④ 变更记录只多了本刀种的那几行(插入:工序 1 · 投料形态 3 · 产出形态 3 · 安全状态 1 · 单据登记 ≤ 1 · 授权 1);三张新表是空的
    SELECT string_agg(DISTINCT c.table_name || ':' || c.op, ', ') INTO v_bad FROM change_log c
     WHERE c.seq > COALESCE((SELECT mx FROM mes5b3_log_before), 0)
       AND NOT (c.op = 'INSERT' AND c.table_name IN ('operation_types', 'operation_type_input_forms', 'operation_type_output_forms',
                                                     'operation_type_safety_states', 'document_types', 'role_permissions'));
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B3_PROOF|unexpected change_log rows: %', v_bad; END IF;
    SELECT count(*) INTO v_n FROM change_log c WHERE c.seq > COALESCE((SELECT mx FROM mes5b3_log_before), 0);
    IF v_n NOT IN (9, 10) THEN RAISE EXCEPTION 'MES5B3_PROOF|change_log moved by % (expected 9, or 10 if document_types is logged)', v_n; END IF;
    IF EXISTS (SELECT 1 FROM blending_plans) OR EXISTS (SELECT 1 FROM blending_plan_targets) OR EXISTS (SELECT 1 FROM blending_plan_lines) THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the new tables must be empty';
    END IF;
    IF (SELECT require_calibrated_since FROM ingest_settings) IS NOT NULL THEN
        RAISE EXCEPTION 'MES5B3_PROOF|require_calibrated_since was set';
    END IF;

    -- ⑤ 结构:两支守卫在;配料从计划页上起;引擎的签名逐字未变;单据登记 56 行,BLD 一行
    IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_processing_runs_blending_from_plan')
       OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = 'trg_output_batch_metals_blended_from_assay') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the two guards are missing';
    END IF;
    IF NOT (SELECT started_from_run_page AND is_active AND kind_code = 'transforming' AND balance_tolerance_pct IS NULL FROM operation_types WHERE code = 'blending') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|blending must be an active transforming operation started from the plan page, with no tolerance set';
    END IF;
    IF pg_get_function_arguments('public.commit_processing_run(date, text, numeric, jsonb, jsonb, text, uuid, uuid, text, timestamp with time zone, timestamp with time zone, text, uuid, jsonb, uuid)'::regprocedure)
         <> 'p_process_date date, p_notes text, p_loss_qty numeric, p_inputs jsonb, p_outputs jsonb, p_allocation_basis text, p_work_order_id uuid DEFAULT NULL::uuid, p_equipment_id uuid DEFAULT NULL::uuid, p_operation_type_code text DEFAULT NULL::text, p_started_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_ended_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_shift_code text DEFAULT NULL::text, p_recipe_version_id uuid DEFAULT NULL::uuid, p_values jsonb DEFAULT NULL::jsonb, p_corrects_run_id uuid DEFAULT NULL::uuid' THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the run engine signature changed';
    END IF;
    IF (SELECT count(*) FROM document_types) <> 56 OR document_type_prefix('blending_plan') <> 'BLD' THEN
        RAISE EXCEPTION 'MES5B3_PROOF|document_types should be 56 with BLD';
    END IF;

    -- ⑥ 匿名面:anon 能执行的【恰好】两支;员工函数 DEFINER、调得到;内层调不到;新表与视图 anon 读不到;底表 authenticated 也读不到
    SELECT COALESCE(string_agg(p.oid::regprocedure::text, ', ' ORDER BY p.oid::regprocedure::text), '') INTO v_bad
      FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
     WHERE n.nspname = 'public' AND p.prokind = 'f' AND has_function_privilege('anon', p.oid, 'EXECUTE');
    IF v_bad <> 'cod_verification(text), ingest_submit(text,text,jsonb)' THEN
        RAISE EXCEPTION 'MES5B3_PROOF|anon executes: %', v_bad;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.create_blending_plan(uuid, jsonb, jsonb, uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.create_blending_plan(uuid, jsonb, jsonb, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.create_blending_plan(uuid, jsonb, jsonb, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|public.create_blending_plan(uuid, jsonb, jsonb, uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.amend_blending_plan(uuid, uuid, jsonb, jsonb, uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.amend_blending_plan(uuid, uuid, jsonb, jsonb, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.amend_blending_plan(uuid, uuid, jsonb, jsonb, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|public.amend_blending_plan(uuid, uuid, jsonb, jsonb, uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.release_blending_plan(uuid)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.release_blending_plan(uuid)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.release_blending_plan(uuid)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|public.release_blending_plan(uuid): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.cancel_blending_plan(uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.cancel_blending_plan(uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.cancel_blending_plan(uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|public.cancel_blending_plan(uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text)'::regprocedure)
       OR NOT has_function_privilege('authenticated', 'public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|public.execute_blending_plan(uuid, date, timestamp with time zone, timestamp with time zone, text, jsonb, numeric, uuid, text): expected SECURITY DEFINER, authenticated yes, anon no';
    END IF;
    IF has_function_privilege('authenticated', 'public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb)'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb)'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|public.blending_plan_write_children(uuid, uuid, uuid, jsonb, jsonb) must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_blending_run_from_plan()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_blending_run_from_plan()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|public.guard_blending_run_from_plan() must be a function nobody outside can call';
    END IF;
    IF has_function_privilege('authenticated', 'public.guard_blended_batch_metals_from_assay()'::regprocedure, 'EXECUTE')
       OR has_function_privilege('anon', 'public.guard_blended_batch_metals_from_assay()'::regprocedure, 'EXECUTE') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|public.guard_blended_batch_metals_from_assay() must be a function nobody outside can call';
    END IF;
    SELECT string_agg(c.relname, ', ') INTO v_bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
     WHERE n.nspname = 'public' AND c.relname IN ('blending_plans', 'blending_plan_targets', 'blending_plan_lines', 'blending_plan_line_metals_all', 'blending_plan_line_metals', 'blending_plan_prediction', 'blending_plan_execution', 'blending_plan_outcome')
       AND has_table_privilege('anon', c.oid, 'SELECT');
    IF v_bad IS NOT NULL THEN RAISE EXCEPTION 'MES5B3_PROOF|anon can read %', v_bad; END IF;
    IF has_table_privilege('authenticated', 'public.blending_plan_line_metals_all'::regclass, 'SELECT') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the base view must not be readable by authenticated';
    END IF;

    -- ⑦ 那 44 条开着的读策略还是 44 条;新表上没有写策略
    IF (SELECT count(*) FROM pg_policies WHERE schemaname = 'public' AND qual = 'true' AND 'authenticated' = ANY (roles)
          AND cmd IN ('SELECT', 'ALL')) <> 44 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|the open read policies are no longer 44';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = 'public'
                 AND tablename IN ('blending_plans', 'blending_plan_targets', 'blending_plan_lines') AND cmd <> 'SELECT') THEN
        RAISE EXCEPTION 'MES5B3_PROOF|a write policy exists on a blending table';
    END IF;

    -- ⑧ 变更记录:覆盖零缺口(三张新表记,豁免仍是 8);遮蔽零缺口(规则仍是 114 —— 本刀没有金额)
    v_j := change_log_coverage_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (v_j ->> 'excluded')::int <> 8 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|change-log coverage: %', v_j;
    END IF;
    v_j := change_log_mask_gaps();
    IF jsonb_array_length(v_j -> 'gaps') <> 0 OR (SELECT count(*) FROM change_log_mask_rules()) <> 114 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|mask gaps: % (rules %)', v_j -> 'gaps', (SELECT count(*) FROM change_log_mask_rules());
    END IF;

    -- ⑨ 提醒臂 59、待补的值 20 不变
    IF (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.operations_now'::regclass), 'AS item_type', 'g')) <> 59
       OR (SELECT count(*) FROM regexp_matches(pg_get_viewdef('public.pending_values'::regclass), 'AS value_code', 'g')) <> 20 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|reminder arms 59 / pending-value arms 20 changed';
    END IF;

    -- ⑩ 每一张在途单据都还有一个【不是它自己当事人】的决定人
    FOR k, v_bad, v_n IN SELECT c.k, c.doc || ' → ' || COALESCE(c.decider_names, '(nobody)'), c.deciders
                           FROM pg_temp.mes5b3_pending_decider_check(true) c LOOP
        RAISE NOTICE 'MES5B3 pending % %', k, v_bad;
    END LOOP;
    SELECT count(*) INTO v_n FROM pg_temp.mes5b3_pending_decider_check(true) c WHERE c.deciders = 0;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'MES5B3_PROOF|% pending document(s) would have no decider', v_n;
    END IF;
END;
$proof$;

DROP FUNCTION pg_temp.mes5b3_pending_decider_check(boolean);

NOTIFY pgrst, 'reload schema';

COMMIT;
