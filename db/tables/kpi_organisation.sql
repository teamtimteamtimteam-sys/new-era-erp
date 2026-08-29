-- db/tables/kpi_organisation.sql
-- KPI-1:组织 KPI O1–O5 —— 规格 docs/kpi-framework.md 第二章,【逐格转录的英文原文】。
--
-- ★★【这张表里的英文一个字都不许改】★★
--   规格第 8 行那张表写着:第一至七章是「原表的逐格转录,英文原文」,**不能改**;
--   要改先改原表,再重新转录。第 17 行更硬:那些英文是【机器从 xlsx 抄出来的】,
--   不是人打的 —— 「三十条 KPI 的目标句子由人重打一遍,就是三十次漏字的机会」。
--   本表因此是**安装种子**(db/check_mirrors.py 的 SEED_TABLES),逐行跟踪线上:
--   **一条目标悄悄漂了,gate 会红。**
--   代价说清楚:**调一条目标从此是【迁移级动作】**,与加一个税码同级。
--   而规格 §9.2 说的正是这个 —— 目标应当【随排期变化而调整】,
--   不是"谁都可以在表单里重打一遍"。
--
-- ★【权重合计必须 = 100,而且是【闸】不是提示】★(§9.3)
--   由 trg_kpi_org_weight_total(DEFERRABLE INITIALLY DEFERRED 约束触发器)在
--   【提交那一刻】检查 —— 逐行插入时不能立即检查,否则第一行就红。
--   §9.3 的原话:「原表今天是对的 —— 正因为今天是对的,才要把它做成闸」:
--   一张今天合计 100 的表,在有人加第六条、或把 25 改成 30 的那一刻会变成 105,
--   而**加权分照样算得出来**,只是从此没有一个数是可比的。
--
-- 【O3 的两栏没有 `Month 3:` / `Month 6:` 前缀,而 O1/O2/O4/O5 有】(§13 末)
--   原表自己的不一致,照录不改 —— 所以**任何按前缀解析这两栏的代码都会在 O3 上落空**。
--   本表把它们存成两个独立的列,于是根本不需要解析。
--
-- NOTE: introduced by db/migrations/2026-08-29-kpi1-positions-and-the-kpi-framework.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.kpi_organisation (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                text NOT NULL UNIQUE CHECK (code ~ '^O[1-9][0-9]*$'),
    title               text NOT NULL CHECK (btrim(title) <> ''),
    weight_pct          numeric NOT NULL CHECK (weight_pct > 0 AND weight_pct <= 100),
    -- 原表第二页的四栏,逐格原文
    definition          text NOT NULL,
    month3_target       text NOT NULL,
    month6_target       text NOT NULL,
    measurement_evidence text NOT NULL,
    criticality_note    text NOT NULL,
    -- ★【这条目标是【建议值】还是【既定标准】】★(§9.2 的落地要求)
    --   「系统必须能看出哪些目标是暂定的。**不是一句备注,是目标行上的一个属性。**」
    is_provisional      boolean NOT NULL DEFAULT false,
    -- ★ 而它【必须带上理由】★ 一个只写着"暂定"的徽章,把"暂定到什么时候为止"
    --   留给读的人去猜 —— 那正是 §9.2 预言的那次误读:
    --   「第一个读到 T3 的人会把 DSO ≤45 days 当成公司已经定下的政策」。
    --   note 里放的是**原表自己的句子**,不是本仓库的转述。
    provisional_note    text,
    sort_order          integer NOT NULL DEFAULT 0,
    created_at          timestamptz NOT NULL DEFAULT now(),
    updated_at          timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT kpi_organisation_provisional_needs_note
        CHECK (NOT is_provisional OR (provisional_note IS NOT NULL AND btrim(provisional_note) <> ''))
);

ALTER TABLE public.kpi_organisation ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kpi_organisation select by permission"
    ON public.kpi_organisation AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

-- ★【权重合计 = 100 的闸】★ 见抬头。约束触发器,提交时检查。
CREATE OR REPLACE FUNCTION public.guard_kpi_org_weight_total()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_total numeric;
BEGIN
    SELECT COALESCE(SUM(weight_pct), 0) INTO v_total FROM kpi_organisation;
    -- 【0 行是合法的】—— 一张还没种下去的表不是一张错的表。
    -- 有行就必须合计 100。
    IF v_total <> 0 AND v_total <> 100 THEN
        RAISE EXCEPTION 'KPI_ORG_WEIGHTS_NOT_100|%', v_total
          USING HINT = '组织 KPI 的权重合计必须正好 100 —— 一张合计 105 的表照样算得出加权分,只是从此没有一个数是可比的(规格 §9.3)';
    END IF;
    RETURN NULL;
END;
$function$;

CREATE CONSTRAINT TRIGGER trg_kpi_org_weight_total
    AFTER INSERT OR UPDATE OR DELETE ON public.kpi_organisation
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_kpi_org_weight_total();

COMMENT ON TABLE public.kpi_organisation IS
    'KPI-1:组织 KPI O1–O5,规格 docs/kpi-framework.md 第二章的**逐格转录英文原文**。★这张表里的英文一个字都不许改★ —— 规格自己写着一至七章「不能改,要改先改原表再重新转录」,而那些句子是机器从 xlsx 抄出来的,不是人打的。**安装种子表,逐行跟踪线上**:一条目标悄悄漂了,gate 会红;代价是【调一条目标从此是迁移级动作】,与加一个税码同级 —— 而 §9.2 说的正是"目标应随排期变化而调整",不是"谁都可以在表单里重打一遍"。权重合计 = 100 由 DEFERRABLE 约束触发器在提交那一刻强制(§9.3:正因为今天是对的,才要把它做成闸)。**O3 的 Month 3 / Month 6 两栏没有 `Month 3:` 前缀而其余四条有** —— 原表自己的不一致(§13),所以这里存成两个独立的列,谁都不必去解析前缀。';

COMMENT ON COLUMN public.kpi_organisation.is_provisional IS
    'KPI-1:这条目标是【管理层的建议值】,不是供给材料里陈述过的事实(规格 §9.2)。**它是目标行上的一个属性,不是一句备注** —— 因为一个建议值在系统里长得像一条既定标准,就是一次误导。为真时 provisional_note 必填,而那句话取自原表自己,不是本仓库的转述。';

-- ⟨KPI-1 SEED BEGIN — 机器生成,勿手改⟩
-- 来源:docs/kpi-framework.md,经 db/scripts/kpi_seed_from_spec.py 逐格解析。
-- **改这些行要先改规格,再重新生成**(规格 §1:一至七章不能改)。

INSERT INTO public.kpi_organisation (code, title, weight_pct, definition, month3_target, month6_target, measurement_evidence, criticality_note, is_provisional, provisional_note, sort_order) VALUES
    ('O1', 'Licensing & regulatory readiness', 25, 'All permits, licences, registrations, notifications and regulator conditions required for intended battery receipt, storage, handling and recycling operations.',
     'Month 3: 100% required applications/submissions lodged; 100% regulator queries/actions tracked with owner/date.',
     'Month 6: 100% required approvals/licences in force before operations; 0 unauthorized receipt/processing.',
     'Regulatory tracker, submission receipts, approval letters, conditions register.',
     'Critical gate: no commercial production or battery receipt beyond what is legally permitted.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes. || The profile does not specify the exact licence names or regulator approval dates, so O1 deliberately uses a generic ''all required approvals/licences'' gate. Actual licenses and timelines need to be developed once there is clarity', 1),
    ('O2', 'Line equipment readiness & commissioning', 25, 'Critical recycling line equipment confirmed, delivered, installed, tested and commissioned to agreed acceptance criteria.',
     'Month 3: 100% critical equipment specifications/POs confirmed; FAT/inspection completed where applicable; installation schedule locked.',
     'Month 6: 100% critical line installed and commissioned; ≥3 successful end-to-end commissioning runs; critical punch-list items closed.',
     'Equipment tracker, FAT/SAT records, installation sign-off, commissioning reports.',
     'Protects processing continuity and the transition from pre-processing to black mass output.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 2),
    ('O3', 'Critical cashflow continuity', 20, 'Liquidity, collections, working capital and cash visibility controlled through the full order-to-cash cycle.',
     'Weekly 13-week cash forecast maintained 100% of weeks; minimum cash reserve ≥3 months fixed OPEX; DSO target ≤45 days once invoicing starts.',
     '0 unapproved material cash commitments; cash reserve maintained at ≥3 months fixed OPEX; overdue AR actively managed.',
     '13-week cash forecast, bank reconciliation, AR ageing, AP schedule, approval log.',
     'Reflects EVoltrya''s cashflow controls: payment terms, credit risk, working capital, forecasting and governance.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 3),
    ('O4', 'Commercial readiness & secured business', 15, 'Build a credible customer and feedstock base before committing processing capacity.',
     'Month 3: ≥3 priority customers at signed LOI/contract stage and first 90-day sales plan established.',
     'Month 6: ≥5 priority customers/long-term relationships with firm commitments covering ≥70% of planned initial processing capacity; feedstock coverage ≥100% of committed production.',
     'Signed LOIs/contracts, CRM/pipeline, feedstock contracts, order/backlog and capacity plan.',
     'Aligned with the stated objective of 3–5 key long-term customers and controlled supply-to-sale continuity.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes. || The deck gives identified feedstock of 423 MT/month and potential additional 90 MT/month, but does not state that all volumes are contractually firm; therefore the KPI uses ''firm commitments'' and capacity coverage rather than treating the pipeline as contracted. Contracts need to be drawn and secured once the business kicks in', 4),
    ('O5', 'Facility safety, environmental & compliance readiness', 15, 'Facility, people and operating controls ready for safe battery handling and compliant recycling.',
     'Month 3: 100% critical HSE/environmental risk assessments, SOPs and emergency controls completed; 100% pre-operational training complete for assigned staff.',
     'Month 6: 0 major non-conformities; 100% critical corrective actions closed by due date; ≥2 emergency drills completed; required inspections/documentation current.',
     'HSE register, SOP matrix, training records, drill reports, inspection logs, corrective-action register.',
     'Matches EVoltrya''s safety-first, traceability, storage/environmental compliance and responsible-operations positioning.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 5);
-- ⟨KPI-1 SEED END⟩
