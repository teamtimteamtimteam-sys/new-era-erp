-- KPI-1:职位主数据 + KPI 框架 —— 规格是 docs/kpi-framework.md,本刀只是【建它】。
--
-- ★★【这一刀不【推导】任何东西:规格已经写好了,而它的一至七章是不可改的转录】★★
--   规格第 12 行:一至七章是「原表的逐格转录,英文原文」,**不能改**;
--   要改先改原表,再重新转录。第 17 行:那些英文是**机器从 xlsx 抄出来的**,
--   不是人打的 ——「三十条 KPI 的目标句子由人重打一遍,就是三十次漏字的机会」。
--   **所以本迁移里的英文也是机器抄的**:见 db/scripts/kpi_seed_from_spec.py,
--   它从 .md 里逐格解析,解析不出来就当场退出(一条漏掉的 KPI 与一条不存在的
--   KPI 在输出里长得一模一样)。
--
-- 【顺序,以及为什么是这个顺序 —— 规格 §11 的六步】
--   1 职位主数据 → 2 组织 KPI → 3 职位模板(要 1 与 2 都在)→
--   4 周期与打分 → 5 按职位复制 → 6 派生视图
--   表必须先于视图;kpi_template_org_links 的外键要求 kpi_organisation 先有行。
--
-- ★【两条【裁定】写在这里,因为它们解释了下面为什么长这样】★
--
--   (一)**KPI 不扩建 review_goals,两者并存**(Tim 2026-08-29;规格 §12.2 曾把它
--        列为公开问题,现已裁定)。代码本身给出了理由:`review_goals` 的表注写着
--        **「没有权重、没有逐条打分」**——「一旦有了分数,谈话就会围着分数转,
--        而不是围着结果转」。而 KPI 的全部内容就是 0–5 乘权重。
--        **两者是设计上的对立面,不是偶然的重复。**
--        本迁移因此【一个字节都不动】既有考核模块 —— 尤其不碰 review_goals
--        那三条 SELECT 策略,其中一条是「本人只在评估 approved/acknowledged 之后
--        才看得见自己的目标」,那是自评的可见性机制。
--
--   (二)**kpi_cycles 不复用 review_cycles,尽管形状一模一样。**
--        共用周期是两个模块悄悄变成一个的方式:第一次有人开一个 HR 评估周期,
--        每块 KPI 屏幕都会继承它,而上面那条裁定就被一条没人再读过的外键推翻了。
--        五个重复的列,对上一次永久的耦合。
--
-- 【employees.job_title 从员工行上【删掉】,而 employment_history.job_title 留着】
--   §12.1 点过名:「两个都留着、两个都能填,就是同一个事实有两个写入口」。
--   职位从此由 employees.position_id 回答。
--   **但履历那一列是【不可变的快照】**,记的是"那一天这个人的头衔写的是什么" ——
--   与 collection_chases.contacted_person、invoices.bill_to_snapshot 同一族。
--   快照不该变成指针:否则删一个职位就改写了一段发生过的履历。
--   **改职位仍然要写一行履历**(app/hr/employees/actions.ts),
--   而那一行的 job_title 是【当时那个职位的 title 文本】—— 少了这一半,
--   一次实质变动会在一条今天还工作着的审计轨迹里【无声消失】,那是回归不是省略。

BEGIN;

-- ═══ 第 1 步:职位主数据 ═══════════════════════════════════════════════
-- db/tables/positions.sql
-- KPI-1:职位主数据 —— 规格见 docs/kpi-framework.md 第 8.2 节。
--
-- 【为什么职位是【单独一张表】,而不是 KPI 模块里的一个子表】(规格 §8.2 原话)
--   「职位表不只服务 KPI。招聘、组织架构、薪资将来都要用它 —— 这也是它值得单独建、
--    而不是塞进 KPI 模块里的理由:一张挂在 KPI 之下的职位表,
--    第一次被招聘用到的时候就要搬家。」
--
-- 【KPI 绑在职位上,不绑在人上】(§8.1)而那不是一条新规矩:
--   docs/exec-views-plan.md 开篇写着「"谁需要哪个数"的答案取自职责,不取自职级」。
--   绑在职位上,是同一条原则用在考核上。
--
-- ★【`code` 那一列是规格提的,原表【没有】代号】★(§8.2 原话)
--   职位名(title)与 source_incumbent_name 是原表原文,一个字没动。
--
-- 【employees.job_title 去哪儿了】KPI-1 把它从 employees 上【删掉】了 ——
--   §12.1 已经点名那个风险:「两个都留着、两个都能填,就是同一个事实有两个写入口」。
--   **但 employment_history.job_title 原样保留**:那是一条【不可变的任职履历】,
--   记的是"那一天这个人的头衔写的是什么",与 collection_chases.contacted_person、
--   invoices.bill_to_snapshot 同一族 —— 快照不该变成指针,否则删一个职位
--   就改写了一段发生过的履历。
--   **改职位仍然会写一行履历**(见 app/hr/employees/actions.ts),
--   而那一行里的 job_title 是【当时那个职位的 title 文本】。
--

CREATE TABLE public.positions (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    -- 代号:规格 §8.2 建议的那六个。原表没有代号,这一列是本仓库加的。
    code                   text NOT NULL UNIQUE CHECK (btrim(code) <> ''),
    -- ★ 职位名 —— 原表 `Role` 列【原文】,不翻译、不整理 ★
    title                  text NOT NULL CHECK (btrim(title) <> ''),
    -- ★【原表记下的现任者姓名,原文】★ 它是一条【出处】,不是一条任命。
    --   谁【今天】在这个职位上,由 employees.position_id 回答 ——
    --   两者可以不同,而那正是它们分开存的理由:原表是 2026-08-27 那一天的一张快照。
    source_incumbent_name  text,
    is_active              boolean NOT NULL DEFAULT true,
    sort_order             integer NOT NULL DEFAULT 0,
    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    updated_by             uuid DEFAULT auth.uid()
);

CREATE INDEX idx_positions_active ON public.positions (sort_order) WHERE is_active;

ALTER TABLE public.positions ENABLE ROW LEVEL SECURITY;

-- 【读:HR 模块】职位是人事主数据。写:只经迁移(它是安装种子,见 check_mirrors)。
CREATE POLICY "positions select by permission"
    ON public.positions AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

COMMENT ON TABLE public.positions IS
    'KPI-1:职位主数据(规格 docs/kpi-framework.md §8.2)。**它不只服务 KPI** —— 招聘、组织架构、薪资将来都要用它,而一张挂在 KPI 之下的职位表第一次被招聘用到时就要搬家。**KPI 绑在职位上不绑在人上**(§8.1),那是 exec-views-plan 开篇「答案取自职责,不取自职级」的第二次落地。`code` 是本仓库加的,**原表没有代号**;`title` 与 `source_incumbent_name` 是原表原文。**安装种子表**:行与代码版本绑定,改一行是迁移级动作(见 db/check_mirrors.py 的 SEED_TABLES 判据)。';

COMMENT ON COLUMN public.positions.source_incumbent_name IS
    'KPI-1:**原表(2026-08-27 那一版)记下的现任者姓名,原文。它是一条出处,不是一条任命。** 谁【今天】在这个职位上由 employees.position_id 回答,两者可以不同 —— 原表是那一天的一张快照,而人是会变的。';

COMMENT ON COLUMN public.positions.title IS
    'KPI-1:原表 `Role` 列【原文】。不翻译、不整理、不缩写 —— 规格第 13 章逐条记过一次译文漂移的代价(`intended` 丢一个词,O1 那道闸的范围就从"打算开展的业务所需"变成"所有的")。';

-- ⟨KPI-1 SEED BEGIN — 机器生成,勿手改⟩
-- 来源:docs/kpi-framework.md,经 db/scripts/kpi_seed_from_spec.py 逐格解析。
-- **改这些行要先改规格,再重新生成**(规格 §1:一至七章不能改)。

INSERT INTO public.positions (code, title, source_incumbent_name, sort_order) VALUES
    ('MD', 'Founder / Managing Director', 'Vince Goh', 1),
    ('CFO', 'Chief Financial Officer', 'Tim Chen', 2),
    ('CTO', 'Chief Technology Officer', 'Cheng Siong Phua', 3),
    ('CCO', 'Chief Commercial Officer', 'Sandra Yap', 4),
    ('LEAD-ACC', 'Lead – Accounts & Corporate Services', 'Choo Er Teh', 5),
    ('LEAD-WH', 'Lead – Warehouse & Logistics', 'Fu Sheng Wong', 6);
-- ⟨KPI-1 SEED END⟩

-- ── employees:挂到职位上,并把 job_title 从这一行上退役 ────────────────────
ALTER TABLE public.employees
    ADD COLUMN position_id uuid REFERENCES public.positions (id) ON DELETE RESTRICT;
COMMENT ON COLUMN public.employees.position_id IS
    'KPI-1:这个人今天在哪个职位上。**KPI 绑在职位上,不绑在人上**(规格 §8.1)—— 那是 exec-views-plan 开篇「答案取自职责,不取自职级」的第二次落地。它取代了本表上原来那个自由文本的 job_title(已删):两个都能填就是同一个事实有两个写入口(§12.1)。**employment_history.job_title 保留**,那是一条不可变的履历快照,记的是"那一天头衔写的是什么"。';

-- ═══ 第 2 步:组织 KPI ════════════════════════════════════════════════
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

-- ═══ 第 3 步:职位 KPI 模板 ═══════════════════════════════════════════
-- db/tables/kpi_position_templates.sql
-- KPI-1:职位 KPI 模板 —— 每职位 5 条,权重合计 100(规格 §11 第 3 步、§9.3)。
-- 目标文本是规格第三章的【英文原文】,与 kpi_organisation 同一条规矩:一个字不许改。
--
-- ★★【它是【模板】,而人名下的那五条是它的【副本】】★★(§8.3)
--   一个人加入某职位时,把这五条**复制**到他名下;**日后改模板,不影响已经复制出去的**。
--   理由是仓库自己的先例,不是一句偏好:采购单的定价条款在【承诺那一刻抄下】(FIN-27)、
--   发票的税率在【开出那一刻冻结】(GST-2)。
--   **一个人某个周期被考核的是哪五条,是一件【已经发生】的事** ——
--   后来改了模板,不该回头改写他当时被考核的标准;那不是"更新",那是改历史。
--
-- 【version 是【复制时抄走的那个号】】改一条模板要把 version 加一,
--   于是人名下那份副本记着的 (source_template_id, source_template_version)
--   永远指得回"他当时被考核的是哪一版",即便模板后来变了。
--
-- ★【`evidence_source` 这一列【故意允许为空】,而空是原表的事实】★(§12.4)
--   原表第三页的列头 `Evidence / review source` 写着,而 **H5:H34 三十格没有一格有内容**。
--   「这不是转录漏了,是原表就没填。」说出来是因为它直接影响打分:
--   **一条没有证据来源的 KPI,打分时靠的是打分人自己记得该看什么。**
--   组织 KPI 那一层的 `measurement_evidence` 是填了的,缺的只有个人这一层。
--

CREATE TABLE public.kpi_position_templates (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    position_id      uuid NOT NULL REFERENCES public.positions (id) ON DELETE RESTRICT,
    -- 原表的 `KPI ID` 列:V1..V5 / T1..T5 / C1..C5 / S1..S5 / A1..A5 / F1..F5
    kpi_ref          text NOT NULL CHECK (btrim(kpi_ref) <> ''),
    -- 原表 `Individual KPI` 列,原文
    title            text NOT NULL CHECK (btrim(title) <> ''),
    weight_pct       numeric NOT NULL CHECK (weight_pct > 0 AND weight_pct <= 100),
    -- 原表 `Quantifiable target / standard` 列,【原文】
    target_text      text NOT NULL CHECK (btrim(target_text) <> ''),
    -- ★ 原表三十格全空 —— 见抬头。允许为空是在陈述一个事实,不是留了个待办。
    evidence_source  text,
    is_provisional   boolean NOT NULL DEFAULT false,
    provisional_note text,
    -- 改一条模板就加一;人名下的副本记着复制那一刻的号
    version          integer NOT NULL DEFAULT 1 CHECK (version >= 1),
    sort_order       integer NOT NULL DEFAULT 0,
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (position_id, kpi_ref),
    CONSTRAINT kpi_tpl_provisional_needs_note
        CHECK (NOT is_provisional OR (provisional_note IS NOT NULL AND btrim(provisional_note) <> ''))
);

CREATE INDEX idx_kpi_tpl_position ON public.kpi_position_templates (position_id, sort_order);

-- ── 模板 → 组织 KPI 的链接(多对多:原表里 S2 是 `O4 / O3`,T5 是 `O3 / O5`)──
-- 【这里用【真的外键】,而人名下的副本用【快照数组】—— 两者是刻意不同的】
--   模板是活的主数据,引用完整性要紧;副本是冻住的事实,自成一体要紧。
--   于是两张联动矩阵有两份推导,而那【不是重复】:复制之后改模板,
--   两边本来就该分开 —— 那正是"复制不是引用"这件事看得见的样子。
CREATE TABLE public.kpi_template_org_links (
    template_id  uuid NOT NULL REFERENCES public.kpi_position_templates (id) ON DELETE CASCADE,
    org_code     text NOT NULL REFERENCES public.kpi_organisation (code) ON DELETE RESTRICT,
    PRIMARY KEY (template_id, org_code)
);

ALTER TABLE public.kpi_position_templates ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kpi_position_templates select by permission"
    ON public.kpi_position_templates AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

ALTER TABLE public.kpi_template_org_links ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kpi_template_org_links select by permission"
    ON public.kpi_template_org_links AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));

-- ★【每个职位的模板权重合计 = 100 的闸】★(§9.3)
-- 与组织那条同一形状:DEFERRABLE,提交时按【职位】分组检查。
CREATE OR REPLACE FUNCTION public.guard_kpi_template_weight_total()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
DECLARE v_bad record;
BEGIN
    -- 【只检查【有模板行的】职位】一个还没配模板的职位不是一个错的职位。
    FOR v_bad IN
        SELECT p.code, SUM(t.weight_pct) AS total
          FROM kpi_position_templates t JOIN positions p ON p.id = t.position_id
         GROUP BY p.code HAVING SUM(t.weight_pct) <> 100
    LOOP
        RAISE EXCEPTION 'KPI_TEMPLATE_WEIGHTS_NOT_100|%|%', v_bad.code, v_bad.total
          USING HINT = '一个职位的五条 KPI 权重合计必须正好 100 —— 加了第六条、或者把 25 改成 30 的那一刻它会变成 105,而加权分照样算得出来(规格 §9.3)';
    END LOOP;
    RETURN NULL;
END;
$function$;

CREATE CONSTRAINT TRIGGER trg_kpi_template_weight_total
    AFTER INSERT OR UPDATE OR DELETE ON public.kpi_position_templates
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION public.guard_kpi_template_weight_total();

COMMENT ON TABLE public.kpi_position_templates IS
    'KPI-1:职位 KPI 模板,每职位 5 条、权重合计 100(规格 §9.3 的闸,DEFERRABLE 约束触发器按职位分组在提交时检查)。目标文本是规格第三章的**英文原文**,一个字不许改;**安装种子表,逐行跟踪线上**。★**它是模板,人名下那五条是它的副本**★(§8.3):加入职位时【复制】,日后改模板不影响已复制的 —— 先例是 FIN-27 的已承诺定价条款与 GST-2 的开票冻结税率,因为"某个周期被考核的是哪五条"是一件已经发生的事。`version` 是复制时被抄走的那个号。★`evidence_source` 故意允许为空★:原表第三页那一列**三十格全空**(§12.4)—— 不是转录漏了,是原表没填,而它直接影响打分(没有证据来源时,打分靠的是打分人自己记得该看什么)。';

COMMENT ON TABLE public.kpi_template_org_links IS
    'KPI-1:模板 → 组织 KPI 的链接,多对多(原表里 S2 是 `O4 / O3`、T5 是 `O3 / O5`)。**这里是真外键,而人名下的副本用快照数组 —— 刻意不同**:模板是活的主数据(引用完整性要紧),副本是冻住的事实(自成一体要紧)。于是两张联动矩阵有两份推导,而那【不是重复】:改了模板之后两边本来就该分开,那正是"复制不是引用"看得见的样子。';

-- ⟨KPI-1 SEED BEGIN — 机器生成,勿手改⟩
-- 来源:docs/kpi-framework.md,经 db/scripts/kpi_seed_from_spec.py 逐格解析。
-- **改这些行要先改规格,再重新生成**(规格 §1:一至七章不能改)。

INSERT INTO public.kpi_position_templates (position_id, kpi_ref, title, weight_pct, target_text, is_provisional, provisional_note, sort_order) VALUES
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V1', 'Regulatory leadership & escalation', 25,
     'Own master regulatory roadmap; 100% critical regulatory milestones have named owner, due date and escalation; no critical regulator action >5 working days overdue.',
     false, NULL, 1),
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V2', 'Commissioning governance', 20,
     'Chair weekly equipment/commissioning review; ≥90% critical project milestones delivered by committed date; all red issues escalated within 2 working days.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 2),
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V3', 'Liquidity & funding decisions', 20,
     'Approve/secure cash plan that maintains ≥3 months fixed-OPEX liquidity buffer; 100% material cash commitments reviewed against 13-week forecast.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 3),
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V4', 'Strategic customers & supply continuity', 20,
     'Personally sponsor ≥5 priority strategic relationships by month 6; secure executive-level support for commitments covering ≥70% of planned initial capacity.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 4),
    ((SELECT id FROM public.positions WHERE code = 'MD'), 'V5', 'Safety & governance culture', 15,
     'Monthly management HSE/compliance review; 100% critical actions assigned and tracked; zero knowingly approved operation outside regulatory/safety controls.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T1', '13-week cash forecast', 25,
     'Update forecast weekly with 100% on-time completion; target forecast variance for next 4 weeks within ±10%.',
     false, NULL, 1),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T2', 'Liquidity buffer', 20,
     'Maintain minimum cash reserve ≥3 months fixed OPEX, with weekly visibility and documented mitigation for any projected breach.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 2),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T3', 'AR / collections discipline', 20,
     'Issue invoices within 2 working days of approved billing trigger; maintain DSO ≤45 days once meaningful billing begins; escalate overdue balances >30 days weekly.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 3),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T4', 'Financial controls for licensing & capex', 20,
     '100% licence, equipment and commissioning payments matched to approved budget/contract milestones; zero unapproved material commitments.',
     false, NULL, 4),
    ((SELECT id FROM public.positions WHERE code = 'CFO'), 'T5', 'Close & governance', 15,
     'Monthly management accounts and cash reconciliation completed by 5th working day; 100% material control exceptions logged and closed/actioned.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C1', 'Equipment delivery & installation', 25,
     '100% critical equipment specifications/POs confirmed; ≥90% critical delivery/installation milestones on time; installation sign-off completed.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 1),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C2', 'Commissioning & process acceptance', 25,
     'Complete ≥3 successful end-to-end commissioning runs from battery feed through separation/black mass output, with agreed safety, quality and process acceptance criteria met.',
     false, NULL, 2),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C3', 'Technical licensing support', 15,
     '100% required technical drawings, process descriptions, equipment data, risk assessments and regulator technical responses submitted by agreed dates.',
     false, NULL, 3),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C4', 'Process safety & operating readiness', 20,
     '100% critical SOPs, JSA/risk assessments, interlocks and emergency operating procedures completed and trained before relevant commissioning/operations.',
     false, NULL, 4),
    ((SELECT id FROM public.positions WHERE code = 'CTO'), 'C5', 'Maintenance resilience', 15,
     '100% critical equipment PM schedule and critical-spares list established before handover; downtime response protocol tested at least once.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S1', 'Priority customer conversion', 25,
     'Secure ≥3 priority customers at signed LOI/contract stage by month 3 and ≥5 by month 6, with clear volume/specification/price/terms.',
     false, NULL, 1),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S2', 'Revenue / order coverage', 25,
     'Build firm customer commitments covering ≥70% of planned initial processing capacity for the first 90 days after commissioning.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 2),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S3', 'Commercial terms & credit protection', 20,
     '100% customer contracts use approved pricing, Incoterms, payment milestones/deposits/credit limits and collection protections; 0 sales commitments without finance/operations capacity check.',
     false, NULL, 3),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S4', 'Order-to-cash readiness', 15,
     '100% contracted orders have feedstock check, production slot, assay/release, logistics, invoicing and collection owner documented before commitment.',
     false, NULL, 4),
    ((SELECT id FROM public.positions WHERE code = 'CCO'), 'S5', 'Customer quality / retention', 15,
     '100% customer product specifications and QA/assay requirements documented before shipment; 0 avoidable customer escalations caused by missing commercial/quality information.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A1', 'Cash & AR administration', 25,
     '100% customer invoices, receipts and AR ageing records maintained accurately; collection follow-up list updated and reconciled weekly.',
     false, NULL, 1),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A2', 'Corporate records & governance', 20,
     '100% statutory/corporate records, approvals, contracts and key registers maintained in a controlled repository; zero missing critical documents at monthly review.',
     false, NULL, 2),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A3', 'Licensing administration', 20,
     'Maintain master licence/regulatory document register with 100% submissions, approvals, expiry/renewal dates and regulator correspondence logged.',
     false, NULL, 3),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A4', 'Facility / HSE administration', 20,
     '100% required training, inspection, drill, incident and corrective-action records filed and current; monthly compliance pack issued on time.',
     false, NULL, 4),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-ACC'), 'A5', 'Payroll / people readiness', 15,
     '100% required employee onboarding, safety induction and training records complete before site duties; payroll/admin processed accurately and on schedule.',
     false, NULL, 5),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F1', 'Warehouse & inventory readiness', 25,
     'Warehouse layout, segregation, labelling and inventory controls 100% ready before battery/material receipt; inventory accuracy ≥98% in monthly checks.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 1),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F2', 'Inbound/ outbound declaration capability and clearance', 25,
     '100% inbound/outbound battery movements supported by required certification, documentation, classification, packaging and approved transport arrangements; 0 major logistics compliance breaches.',
     false, NULL, 2),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F3', 'Feedstock coverage & inbound continuity', 20,
     'Maintain rolling inbound plan covering ≥100% of committed production requirements; escalate supply gaps ≥10 working days before planned receipt.',
     false, NULL, 3),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F4', 'Dispatch & documentation', 15,
     '≥98% on-time dispatch readiness once sales begin; 100% shipping documents complete before dispatch and invoice trigger.',
     true, 'Some targets are management recommendations rather than facts stated in the supplied materials — particularly the 3-month/6-month dates, ≥3 months fixed-OPEX liquidity buffer, DSO ≤45 days, ≥70% initial-capacity customer coverage, ≥98% inventory accuracy, and ≥90% milestone adherence. They are intentionally quantifiable launch controls and should be adjusted accordingly to the final commissioning schedule, licensed capacity, commercial terms or financing plan changes.', 4),
    ((SELECT id FROM public.positions WHERE code = 'LEAD-WH'), 'F5', 'Warehouse safety & emergency readiness', 15,
     '100% warehouse staff trained on battery handling/emergency procedures; ≥2 emergency drills supported; 0 critical housekeeping/safety findings left overdue.',
     false, NULL, 5);

INSERT INTO public.kpi_template_org_links (template_id, org_code) VALUES
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V1'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V2'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V3'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V4'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'MD' AND t.kpi_ref = 'V5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T1'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T2'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T3'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T4'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T4'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T5'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CFO' AND t.kpi_ref = 'T5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C1'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C2'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C3'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C4'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C5'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CTO' AND t.kpi_ref = 'C5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S1'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S2'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S2'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S3'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S3'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S4'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S4'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S5'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'CCO' AND t.kpi_ref = 'S5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A1'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A2'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A2'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A3'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A4'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-ACC' AND t.kpi_ref = 'A5'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F1'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F1'), 'O2'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F2'), 'O1'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F2'), 'O5'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F3'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F4'), 'O3'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F4'), 'O4'),
    ((SELECT t.id FROM public.kpi_position_templates t JOIN public.positions p ON p.id = t.position_id WHERE p.code = 'LEAD-WH' AND t.kpi_ref = 'F5'), 'O5');
-- ⟨KPI-1 SEED END⟩

-- ═══ 第 4 步:周期与条目 ══════════════════════════════════════════════
-- db/tables/kpi_cycles.sql
-- KPI-1:KPI 的考核周期 —— 0–5 打分、加权、M3 / M6 两道关口(规格 §11 第 4 步)。
--
-- ★★【为什么【不】复用 review_cycles,尽管形状一模一样】★★(Tim 2026-08-29 裁定)
--   `review_cycles` 今天 0 行,列也逐个对得上(name / period_start / period_end /
--   due_date / status)—— 复用在技术上是免费的。**而那正是危险所在:**
--   **共用周期,是两个模块悄悄变成一个的方式。** 第一次有人开一个 HR 评估周期,
--   每一块 KPI 屏幕都会继承它,于是【Tim 裁过的"两者并存"会被一条没人再读过的外键推翻】。
--   五个重复的列,对上一次永久的耦合 —— 这不是一个接近的取舍。
--   **形状是刻意保持一致的**,好让将来真要合并时代价还是小的。
--
-- 【两者为什么必须并存,而不是二选一】(规格 §12.2,已由 Tim 裁定为"另起")
--   `review_goals` 的表注自己写着:**「没有权重、没有逐条打分」**,
--   理由是「一旦有了分数,谈话就会围着分数转,而不是围着结果转」。
--   而 KPI 的全部内容就是 0–5 乘权重。**两者是设计上的对立面,不是偶然的重复。**
--   本模块因此【不读也不写】review_goals,尤其不碰它那三条 SELECT 策略 ——
--   其中一条是「本人只在评估 approved/acknowledged 之后才看得见自己的目标」,
--   那是自评的可见性机制,KPI 不替代它、也不许放宽它。
--

CREATE TABLE public.kpi_cycles (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    name         text NOT NULL CHECK (btrim(name) <> ''),
    period_start date NOT NULL,
    period_end   date NOT NULL,
    due_date     date NOT NULL,
    status       text NOT NULL DEFAULT 'draft' CHECK (status IN ('draft','open','closed')),
    -- ★【M3 / M6 两道关口】★ 原表第一页:「Use Month 3 and Month 6 gates; review monthly.」
    --   月度打分的周期 gate 为空;正式关口的那两次各自标出来。
    --   规格第六章说得更细:M3 是 launch-readiness review,M6 是 commissioning /
    --   operating-readiness review 与第一次正式考核。
    gate         text CHECK (gate IS NULL OR gate IN ('M3','M6')),
    notes        text,
    deleted_at   timestamptz,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid DEFAULT auth.uid(),
    CONSTRAINT kpi_cycles_period_order CHECK (period_end >= period_start)
);

CREATE INDEX idx_kpi_cycles_open ON public.kpi_cycles (period_start DESC) WHERE deleted_at IS NULL;

ALTER TABLE public.kpi_cycles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "kpi_cycles select by permission"
    ON public.kpi_cycles AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));
CREATE POLICY "kpi_cycles insert by permission"
    ON public.kpi_cycles AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'::text));
CREATE POLICY "kpi_cycles update by permission"
    ON public.kpi_cycles AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit'::text)) WITH CHECK (has_permission('module.hr.edit'::text));

COMMENT ON TABLE public.kpi_cycles IS
    'KPI-1:KPI 的考核周期。★**刻意不复用 review_cycles,尽管形状一模一样**★(Tim 2026-08-29):共用周期是两个模块悄悄变成一个的方式 —— 第一次有人开一个 HR 评估周期,每块 KPI 屏幕都会继承它,而 Tim 裁过的"两者并存"就被一条没人再读过的外键推翻了。五个重复的列 vs 一次永久的耦合。**形状刻意保持一致**,好让将来真要合并时代价还是小的。两者必须并存的理由在 review_goals 自己的表注里:它写着「没有权重、没有逐条打分」,而 KPI 的全部内容就是 0–5 乘权重 —— **设计上的对立面,不是偶然的重复**。本模块不读也不写 review_goals,尤其不碰它那条「本人只在 approved/acknowledged 之后才看得见自己目标」的自评可见性策略。';

COMMENT ON COLUMN public.kpi_cycles.gate IS
    'KPI-1:M3 / M6 两道正式关口(原表第一页:Use Month 3 and Month 6 gates; review monthly)。月度打分的周期这里为空 —— 关口不是"又一次打分",第六章给它们各自的判断题:M3 决定是否 regulatory-ready / equipment-ready / commercially ready / financially protected,M6 决定是否 ready for sustained controlled operations。';
-- db/tables/kpi_entries.sql
-- KPI-1:一个人在一个周期里被考核的那五条 —— **模板的副本,不是模板的引用**(§8.3)。
--
-- ★★【这张表存在的全部理由:被考核的标准是一件【已经发生】的事】★★
--   规格 §8.3 原话:「一个人加入某职位时,把该职位模板的五条**复制**到他名下;
--   日后修改职位模板,**不影响已经复制出去的条目**。」
--   仓库自己的先例:采购单定价条款在【承诺那一刻抄下】(FIN-27)、
--   发票税率在【开出那一刻冻结】(GST-2)。
--   **后来改了模板,不该回头改写他当时被考核的标准 —— 那不是"更新",那是改历史。**
--
--   所以下面每一个来自模板的字段都是【抄过来的值】,不是一个指针:
--   title / weight_pct / target_text / evidence_source / is_provisional /
--   provisional_note / org_codes 全部是副本。
--   source_position_id 与 source_template_id / source_template_version 只用来
--   **回答"它从哪儿来、是哪一版"**,不用来在读取时回查内容。
--
--   ★ FIN-27 留下的下半句一并继承(§8.3 末):
--     **「引用了模板却没有留下副本的记录,要按名拒绝,
--       不许悄悄回退去读『现在的模板』。」**
--     所以 target_text 是 NOT NULL —— 一条没抄下目标的条目建不出来。
--
-- 【org_codes 是【快照数组】,而模板那边是真外键 —— 刻意不同】
--   见 kpi_template_org_links 的表注。改了模板之后两张矩阵本来就该分开,
--   那正是"复制不是引用"看得见的样子。
--
-- ★【算出来的分与人判断的分,在数据里就分开】★(§10.2)
--   `score_kind` 不是装饰:§10.2 写着这是**设计要求,不是可选项** ——
--   一份记分卡上 `98.4%`(盘点算出来的)与 `4 分`(有人看了证据判的)
--   如果长得一模一样,**打分的人会默认两个数一样可靠**。
--   本仓库对这一族已有先例:lib/permissions.ts 存在的全部理由,就是
--   `null`(看不到)与 `0`(确实是零)不能长得一样。
--

CREATE TABLE public.kpi_entries (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    cycle_id                uuid NOT NULL REFERENCES public.kpi_cycles (id) ON DELETE RESTRICT,
    employee_id             uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    -- ── 来源:回答"从哪儿来、哪一版",不用于回查内容 ──────────────────────
    source_position_id      uuid NOT NULL REFERENCES public.positions (id) ON DELETE RESTRICT,
    source_template_id      uuid NOT NULL REFERENCES public.kpi_position_templates (id) ON DELETE RESTRICT,
    source_template_version integer NOT NULL CHECK (source_template_version >= 1),
    -- ── 抄过来的那一份(改模板不动这里)────────────────────────────────────
    kpi_ref                 text NOT NULL CHECK (btrim(kpi_ref) <> ''),
    title                   text NOT NULL CHECK (btrim(title) <> ''),
    weight_pct              numeric NOT NULL CHECK (weight_pct > 0 AND weight_pct <= 100),
    target_text             text NOT NULL CHECK (btrim(target_text) <> ''),
    evidence_source         text,
    is_provisional          boolean NOT NULL DEFAULT false,
    provisional_note        text,
    org_codes               text[] NOT NULL CHECK (array_length(org_codes, 1) >= 1),
    -- ── 打分 ───────────────────────────────────────────────────────────────
    -- 0–5,整数(原表第六页逐档定义 5/4/3/2/1/0,没有小数档)
    score                   integer CHECK (score IS NULL OR (score BETWEEN 0 AND 5)),
    -- ★ 这个分是【算出来的】还是【人判的】—— 见抬头 §10.2
    score_kind              text CHECK (score_kind IS NULL OR score_kind IN ('judged','computed')),
    -- 算出来的那一支要留下【它算的是什么】,否则"computed"只是一个标签
    computed_basis          text,
    evidence_note           text,
    scored_by               uuid,
    scored_at               timestamptz,
    -- ★【安全/监管否决:一个【封顶】动作,不是一个分数】★(原表第六页)
    --   「Major breach can cap score at 0–2 depending on severity」、
    --   「Any unauthorized operation = 0」。封顶要留下【封到几分】与【为什么】,
    --   而且不覆盖原始判断 —— 原始分与封顶后的分都要看得见,
    --   否则事后没人分得清"他本来就只有 2 分"与"他被封到 2 分"。
    override_cap            integer CHECK (override_cap IS NULL OR (override_cap BETWEEN 0 AND 5)),
    override_reason         text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid DEFAULT auth.uid(),
    updated_at              timestamptz NOT NULL DEFAULT now(),
    updated_by              uuid,
    UNIQUE (cycle_id, employee_id, kpi_ref),
    CONSTRAINT kpi_entries_provisional_needs_note
        CHECK (NOT is_provisional OR (provisional_note IS NOT NULL AND btrim(provisional_note) <> '')),
    -- 打了分就得说这个分是哪一种 —— 一个没有来路的分数是本刀最想消灭的东西
    CONSTRAINT kpi_entries_score_needs_kind
        CHECK ((score IS NULL) = (score_kind IS NULL)),
    -- 【算出来的必须说出它算的是什么】否则 'computed' 只是一个更好看的标签
    CONSTRAINT kpi_entries_computed_needs_basis
        CHECK (score_kind IS DISTINCT FROM 'computed'
               OR (computed_basis IS NOT NULL AND btrim(computed_basis) <> '')),
    CONSTRAINT kpi_entries_override_needs_reason
        CHECK (override_cap IS NULL OR (override_reason IS NOT NULL AND btrim(override_reason) <> ''))
);

CREATE INDEX idx_kpi_entries_cycle_emp ON public.kpi_entries (cycle_id, employee_id);
CREATE INDEX idx_kpi_entries_employee ON public.kpi_entries (employee_id);

ALTER TABLE public.kpi_entries ENABLE ROW LEVEL SECURITY;

-- 【读:HR 模块 + 评估数据类】与 performance_reviews 同一道门,不比它宽。
CREATE POLICY "kpi_entries select by permission"
    ON public.kpi_entries AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text) AND has_permission('data.view_reviews'::text));

-- ★【本人看得见自己的那五条】★ 而这【不是】review_goals 那条策略的复制:
--   那一条把自评正文压到 approved/acknowledged 之后才可见,理由是自评过程中的
--   草稿不该被当事人看到。**KPI 条目不同:它是"你这个周期被考核的是哪五条"** ——
--   那是期初就该让人知道的事,藏起来才是错的。
--   所以本人始终看得见自己的条目;而**未定稿的分数由视图挡住**(见 my_kpi_entries)。
CREATE POLICY "kpi_entries select own"
    ON public.kpi_entries AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());

COMMENT ON TABLE public.kpi_entries IS
    'KPI-1:一个人在一个周期里被考核的那五条 —— **模板的副本,不是引用**(规格 §8.3)。title / weight_pct / target_text / evidence_source / is_provisional / provisional_note / org_codes 全是【抄过来的值】;source_position_id 与 source_template_id/version 只回答"从哪儿来、哪一版",**不在读取时回查内容**。理由是仓库先例:FIN-27 的定价条款在承诺那一刻抄下、GST-2 的税率在开票那一刻冻结 —— 后来改模板不该回头改写他当时被考核的标准,那不是更新,那是改历史。FIN-27 的下半句一并继承:**引用了模板却没留下副本的记录要按名拒绝,不许悄悄回退去读"现在的模板"**,所以 target_text 是 NOT NULL。`score_kind` 把【算出来的分】与【人判的分】在数据里就分开(§10.2 是设计要求不是可选项:98.4% 与 4 分并排且长得一样,打分的人会默认两个一样可靠)—— 与 lib/permissions.ts 让 null 与 0 长得不一样是同一条。`override_cap` 是原表第六页那个【封顶】动作,原始分与封顶都留着,否则事后分不清"本来就 2 分"与"被封到 2 分"。';

COMMENT ON COLUMN public.kpi_entries.score_kind IS
    'KPI-1:`computed` = 这个分背后有系统算得出来的证据(F1 盘点准确率、C5 前半的保养计划、A1/T3 一部分的应收账龄);`judged` = 一个人看了证据判的。**两者在屏幕上必须长得不一样**(规格 §10.2)—— 它们的可靠性差着一整个数量级:一个点得开看到是哪几次盘点、哪几行差异,另一个背后是一个人的判断,可能有证据也可能只是印象。';

COMMENT ON COLUMN public.kpi_entries.org_codes IS
    'KPI-1:这条 KPI 支撑哪几条组织 KPI —— **复制那一刻的快照数组**,不是外键。模板那一侧是真外键(kpi_template_org_links)。**刻意不同**:模板是活的主数据,副本是冻住的事实。于是职位级与员工级两张联动矩阵有两份推导,而那不是重复 —— 改了模板之后两边本来就该分开。';

-- ═══ 第 5 步:按职位复制 + 打分 ═══════════════════════════════════════
-- db/functions/assign_position_kpis.sql
-- KPI-1:把一个职位的五条模板【复制】到一个人名下(规格 §11 第 5 步、§8.3)。
--
-- ★★【复制,不是引用 —— 这支函数就是那句话的实现】★★
--   每一个来自模板的字段都在这里被**读出来、写进去**。写完之后,
--   kpi_entries 那一行与 kpi_position_templates 那一行【再无内容上的联系】:
--   改模板不动副本。source_template_id / source_template_version 只用来回答
--   "它从哪儿来、是哪一版",**任何读取路径都不许拿它回查内容** ——
--   一旦有人那么写,复制就退化成了引用,而退化是静悄悄的。
--
-- 【为什么权重在这里【再查一次】,尽管表上已经有 DEFERRABLE 闸】
--   那道闸守的是【写模板】那条路。这支函数是【读模板】——
--   而模板可能是在闸建起来之前就存在的、也可能被将来某条新路径绕过。
--   复制一份合计不是 100 的模板出去,人名下那五条就永远算不出可比的分数,
--   **而它算得出数、不报错**。所以这里按名拒,不猜。
--   (「闸要拦在今天所有的入口上」——AGENTS.md 记过两次的那条。)

CREATE OR REPLACE FUNCTION public.assign_position_kpis(p_employee_id uuid, p_cycle_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_emp    employees%ROWTYPE;
    v_pos    positions%ROWTYPE;
    v_cycle  kpi_cycles%ROWTYPE;
    v_total  numeric;
    v_n      integer := 0;
    v_t      record;
    v_codes  text[];
BEGIN
    -- 【SECURITY DEFINER 自己查权限】属主权限绕过 RLS,所以这一句不是礼节。
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_emp FROM employees WHERE id = p_employee_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'EMPLOYEE_NOT_FOUND|%', p_employee_id;
    END IF;
    SELECT * INTO v_cycle FROM kpi_cycles WHERE id = p_cycle_id AND deleted_at IS NULL;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'KPI_CYCLE_NOT_FOUND|%', p_cycle_id;
    END IF;
    IF v_cycle.status = 'closed' THEN
        RAISE EXCEPTION 'KPI_CYCLE_CLOSED|%', v_cycle.name
          USING HINT = '这个周期已经关了 —— 往一个关掉的周期里生成条目,等于事后给一段已经结束的考核补标准';
    END IF;

    -- 【没有职位就没有模板可抄】而这条拒绝要指路,不是一句"失败"。
    IF v_emp.position_id IS NULL THEN
        RAISE EXCEPTION 'EMPLOYEE_HAS_NO_POSITION|%', v_emp.code
          USING HINT = 'KPI 绑在职位上,不绑在人上(规格 §8.1)—— 先到【人事 → 员工】给这个人指定一个职位,他名下的五条才有来源';
    END IF;
    SELECT * INTO v_pos FROM positions WHERE id = v_emp.position_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'POSITION_NOT_FOUND|%', v_emp.position_id;
    END IF;

    -- 【已经生成过就按名拒,不悄悄再来一遍】重复生成会造出第二组条目,
    -- 而 UNIQUE(cycle_id, employee_id, kpi_ref) 会用一个裸约束名把它挡下来 ——
    -- 裸约束违例到了浏览器上是一串机器码。这里先说人话。
    SELECT count(*) INTO v_n FROM kpi_entries
     WHERE cycle_id = p_cycle_id AND employee_id = p_employee_id;
    IF v_n > 0 THEN
        RAISE EXCEPTION 'KPI_ENTRIES_ALREADY_GENERATED|%|%|%', v_emp.code, v_cycle.name, v_n
          USING HINT = '这个人在这个周期里已经有条目了 —— 要换一套标准,先决定那已经存在的一套怎么办,不要在旁边再长出一套';
    END IF;

    -- ★【模板一条都没有 → 拒绝,而不是生成零条】★
    --   生成零条会成功返回,而屏幕上看起来"生成过了" —— 一个空集不是一次成功。
    SELECT count(*), COALESCE(SUM(weight_pct), 0) INTO v_n, v_total
      FROM kpi_position_templates WHERE position_id = v_pos.id;
    IF v_n = 0 THEN
        RAISE EXCEPTION 'POSITION_HAS_NO_TEMPLATES|%', v_pos.code
          USING HINT = '这个职位还没有 KPI 模板 —— 生成零条会看起来像生成成功了,所以这里拒绝';
    END IF;
    -- 见抬头:闸要拦在今天所有的入口上。
    IF v_total <> 100 THEN
        RAISE EXCEPTION 'KPI_TEMPLATE_WEIGHTS_NOT_100|%|%', v_pos.code, v_total
          USING HINT = '这个职位的模板权重合计不是 100 —— 照它复制出去的五条永远算不出可比的分数,而它算得出数、不报错(规格 §9.3)';
    END IF;

    -- ★★ 逐条【抄】过去 ★★
    v_n := 0;
    FOR v_t IN
        SELECT * FROM kpi_position_templates WHERE position_id = v_pos.id ORDER BY sort_order, kpi_ref
    LOOP
        -- 链接也抄成快照数组 —— 见 kpi_entries.org_codes 的列注。
        SELECT array_agg(l.org_code ORDER BY l.org_code) INTO v_codes
          FROM kpi_template_org_links l WHERE l.template_id = v_t.id;
        -- 【一条不链任何组织 KPI 的模板是坏的】原表第三章每一条都有 `Linked Org KPI(s)`,
        -- 而 roll-up 与联动矩阵全靠它。抄出一条空链接,矩阵会静静少一格。
        IF v_codes IS NULL OR array_length(v_codes, 1) IS NULL THEN
            RAISE EXCEPTION 'KPI_TEMPLATE_HAS_NO_ORG_LINK|%|%', v_pos.code, v_t.kpi_ref
              USING HINT = '每一条个人 KPI 都要链到至少一条组织 KPI(原表第三章的 Linked Org KPI(s) 一列)—— 没有链接,联动矩阵会静静少一格';
        END IF;

        INSERT INTO kpi_entries (
            cycle_id, employee_id,
            source_position_id, source_template_id, source_template_version,
            kpi_ref, title, weight_pct, target_text, evidence_source,
            is_provisional, provisional_note, org_codes, created_by)
        VALUES (
            p_cycle_id, p_employee_id,
            v_pos.id, v_t.id, v_t.version,
            v_t.kpi_ref, v_t.title, v_t.weight_pct, v_t.target_text, v_t.evidence_source,
            v_t.is_provisional, v_t.provisional_note, v_codes, auth.uid());
        v_n := v_n + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'employee_code', v_emp.code,
        'position_code', v_pos.code,
        'cycle', v_cycle.name,
        'entries_created', v_n,
        -- 【把版本回给调用方】屏幕要说得出"这是照第几版模板抄的"
        'template_versions', (SELECT jsonb_object_agg(kpi_ref, version)
                                FROM kpi_position_templates WHERE position_id = v_pos.id));
END;
$function$;

COMMENT ON FUNCTION public.assign_position_kpis(uuid, uuid) IS
'KPI-1:把职位模板的五条【复制】到一个人名下(规格 §8.3、§11 第 5 步)。**每一个字段都是读出来再写进去的** —— 写完之后条目与模板再无内容上的联系,改模板不动副本;source_template_id/version 只回答"从哪儿来、哪一版",**任何读取路径都不许拿它回查内容**,一旦那么写,复制就静悄悄退化成了引用。权重在这里【再查一次】尽管表上已有 DEFERRABLE 闸:那道闸守的是写模板那条路,这支函数走的是读模板那条 ——「闸要拦在今天所有的入口上」。四条按名拒都带指路:没有职位、职位没有模板(生成零条会看起来像成功)、已经生成过、模板缺组织链接(矩阵会静静少一格)。';
-- db/functions/score_kpi_entry.sql
-- KPI-1:给一条 KPI 打分 —— 0–5,并说清这个分是【算出来的】还是【人判的】(§10.2)。
--
-- ★【安全/监管否决是一个【封顶】动作,不是一个分数】★(原表第六页)
--   「Major breach can cap score at 0–2 depending on severity」、
--   「Critical control gap may cap at 2」、「Any unauthorized operation = 0」。
--   **封顶不覆盖原始判断**:score 与 override_cap 都留着,
--   于是事后分得清「他本来就只有 2 分」与「他被封到 2 分」——
--   这两句话在一次复盘里意思完全不同,而一个只存最终分的实现说不出后一句。
--   生效分 = LEAST(score, override_cap),由视图算,不另存(算得出来的不存)。

CREATE OR REPLACE FUNCTION public.score_kpi_entry(
    p_entry_id uuid,
    p_score integer,
    p_score_kind text DEFAULT 'judged'::text,
    p_evidence_note text DEFAULT NULL::text,
    p_computed_basis text DEFAULT NULL::text,
    p_override_cap integer DEFAULT NULL::integer,
    p_override_reason text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_e     kpi_entries%ROWTYPE;
    v_cycle kpi_cycles%ROWTYPE;
BEGIN
    PERFORM require_permission('module.hr.edit');

    SELECT * INTO v_e FROM kpi_entries WHERE id = p_entry_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'KPI_ENTRY_NOT_FOUND|%', p_entry_id; END IF;
    SELECT * INTO v_cycle FROM kpi_cycles WHERE id = v_e.cycle_id;
    IF v_cycle.status = 'closed' THEN
        RAISE EXCEPTION 'KPI_CYCLE_CLOSED|%', v_cycle.name
          USING HINT = '这个周期已经关了 —— 改一个关掉的周期里的分数是在改历史,要改先重开周期,那一步会留痕';
    END IF;

    IF p_score IS NULL OR p_score < 0 OR p_score > 5 THEN
        RAISE EXCEPTION 'KPI_SCORE_OUT_OF_RANGE|%', COALESCE(p_score::text, 'null')
          USING HINT = '打分是 0–5 的整数(原表第六页逐档定义了 5/4/3/2/1/0,没有小数档)';
    END IF;
    IF p_score_kind IS NULL OR p_score_kind NOT IN ('judged','computed') THEN
        RAISE EXCEPTION 'KPI_SCORE_KIND_INVALID|%', COALESCE(p_score_kind, 'null')
          USING HINT = '一个分数要说出它是【算出来的】还是【人判的】—— 两者可靠性差着一个数量级,而屏幕上必须长得不一样(规格 §10.2)';
    END IF;
    -- ★【说自己是算出来的,就得说出算的是什么】★ 否则 computed 只是一个更好看的标签,
    --   而那正是 §10.2 要防的:打分的人以为整条都有据可依。
    IF p_score_kind = 'computed'
       AND NULLIF(btrim(COALESCE(p_computed_basis, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_COMPUTED_NEEDS_BASIS|%', v_e.kpi_ref
          USING HINT = '标成【算出来的】就要写清它算的是什么(哪几次盘点、哪张账龄、截至哪一天)—— 否则 computed 只是一个更好看的标签';
    END IF;
    -- 封顶要有理由 —— 一次没有理由的否决,事后与一次低分长得一模一样。
    IF p_override_cap IS NOT NULL
       AND NULLIF(btrim(COALESCE(p_override_reason, '')), '') IS NULL THEN
        RAISE EXCEPTION 'KPI_OVERRIDE_NEEDS_REASON|%', v_e.kpi_ref
          USING HINT = '安全/监管否决要写明是哪一件事(原表:major breach 可封到 0–2、unauthorized operation = 0)—— 没有理由的封顶,事后与一次低分长得一模一样';
    END IF;
    IF p_override_cap IS NOT NULL AND (p_override_cap < 0 OR p_override_cap > 5) THEN
        RAISE EXCEPTION 'KPI_SCORE_OUT_OF_RANGE|%', p_override_cap; END IF;

    UPDATE kpi_entries
       SET score = p_score,
           score_kind = p_score_kind,
           computed_basis = NULLIF(btrim(COALESCE(p_computed_basis, '')), ''),
           evidence_note = NULLIF(btrim(COALESCE(p_evidence_note, '')), ''),
           override_cap = p_override_cap,
           override_reason = NULLIF(btrim(COALESCE(p_override_reason, '')), ''),
           scored_by = auth.uid(), scored_at = now(),
           updated_at = now(), updated_by = auth.uid()
     WHERE id = p_entry_id;

    RETURN jsonb_build_object(
        'entry_id', p_entry_id,
        'kpi_ref', v_e.kpi_ref,
        'score', p_score,
        'score_kind', p_score_kind,
        -- 生效分:封顶之后的那个。**两个数都回,不只回一个** —— 见抬头。
        'effective_score', LEAST(p_score, COALESCE(p_override_cap, 5)),
        'capped', (p_override_cap IS NOT NULL AND p_override_cap < p_score),
        'weighted', round(LEAST(p_score, COALESCE(p_override_cap, 5))::numeric / 5 * v_e.weight_pct, 2));
END;
$function$;

COMMENT ON FUNCTION public.score_kpi_entry(uuid, integer, text, text, text, integer, text) IS
'KPI-1:给一条 KPI 打 0–5 分。**分数必须说出自己是 judged 还是 computed**(规格 §10.2 是设计要求不是可选项),而**标成 computed 就必须写出它算的是什么** —— 否则 computed 只是一个更好看的标签,打分的人会以为整条都有据可依。**安全/监管否决是【封顶】不是【分数】**(原表第六页):score 与 override_cap 都留着,于是事后分得清「他本来就只有 2 分」与「他被封到 2 分」—— 一个只存最终分的实现说不出后一句。生效分 = LEAST(score, cap),由视图算,不另存。';

-- ── 把两位在册员工挂到职位上 ───────────────────────────────────────────────
-- ★【这一步是【有据】的,不是推断的】★(Tim 2026-08-29 裁定)
--   · Choo Er Teh → LEAD-ACC:她在原表第三、四页被点名在这个职位上,
--     那是一条【记录在案的事实】。
--   · Tim → CFO:Tim 本人确认他就是 Tim Chen、职位是 CFO。
--     那是【他关于自己的陈述】,所以不是本刀从四个字母去猜一个人是谁。
--   实测线上 employees 有 21 行,其中 19 行是 ZZ-* 脚手架,真员工只有这两位;
--   而原表点名的六个人里【另外四个根本没有员工档案】。
--   **于是员工级 roll-up 今天只会显示【六分之二】,而那必须被说出来**
--   ——一张只显示两个人、什么都不说的 roll-up,看起来像是全部。
UPDATE public.employees SET position_id = (SELECT id FROM public.positions WHERE code = 'LEAD-ACC')
 WHERE code = 'EMP-2026-0001';
UPDATE public.employees SET position_id = (SELECT id FROM public.positions WHERE code = 'CFO')
 WHERE code = 'EMP-2026-0002';


-- ── my_profile 跟着改:头衔从职位来 ────────────────────────────────────────
-- 【必须在 DROP COLUMN job_title 【之前】替换】否则那张视图会拦住 DROP:
-- 它今天 SELECT e.job_title,而一个被视图引用的列删不掉。
-- db/views/employees_masked.sql
-- 员工档案的遮蔽伴生视图。身份/联系方式要 data.view_identity,月固定工资要 data.view_pay,
-- 两者都【对本人让路】。
--
-- 【年假三列都是派生的】annual_leave_days 那一列已随 HR-2c 删除。
--   annual_leave_rate_days       年度【费率】,界面必须按费率标,不是余额
--   annual_leave_accrued_days    到今天已经挣到的
--   annual_leave_available_days  扣掉已请、加上结转后真正能请的
-- 软删的行用 deleted_at 守卫(那些函数对已删除员工会报错)。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.
--       PDPA-1 追加 anonymised_at / anonymised_by —— **排在末尾**,因为
--       CREATE OR REPLACE VIEW 只许追加,不许改动既有列的次序。两列都不遮蔽:
--       "这一行已经不再保有个人数据"这件事本身不是个人数据,而且必须看得见。

CREATE OR REPLACE VIEW public.employees_masked WITH (security_invoker = off) AS
 SELECT id,
    code,
    legal_name,
    preferred_name,
    department_id,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- **列名保持 job_title**,是为了不惊动这张视图的下游读者 ——
    -- 它回答的仍然是同一个问题(这个人的头衔是什么),只是真源换了。
    (SELECT p.title FROM positions p WHERE p.id = employees.position_id) AS job_title,
    manager_id,
    employment_type,
    work_category,
    hire_date,
    probation_end_date,
    employment_status,
    separation_date,
    separation_type,
    separation_notes,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_email
            ELSE NULL::text
        END AS work_email,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_phone
            ELSE NULL::text
        END AS work_phone,
    residency_status,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN identity_no
            ELSE NULL::text
        END AS identity_no,
    work_pass_type,
        CASE
            WHEN has_permission('data.view_identity'::text) OR id = current_user_employee() THEN work_pass_no
            ELSE NULL::text
        END AS work_pass_no,
    work_pass_issue_date,
    work_pass_expiry_date,
    user_id,
    notes,
    deleted_at,
    created_at,
    created_by,
    updated_at,
    updated_by,
    confirmation_date,
        CASE
            WHEN has_permission('data.view_pay'::text) OR id = current_user_employee() THEN monthly_salary
            ELSE NULL::numeric
        END AS monthly_salary,
    monthly_salary_set,
    review_exempt,
        CASE
            WHEN deleted_at IS NULL THEN annual_leave_rate_per_year(id)
            ELSE NULL::numeric
        END AS annual_leave_rate_days,
        CASE
            WHEN deleted_at IS NULL THEN accrued_annual_leave(id)
            ELSE NULL::numeric
        END AS annual_leave_accrued_days,
        CASE
            WHEN deleted_at IS NULL THEN (leave_balance_internal(id, 'annual'::text) ->> 'available'::text)::numeric
            ELSE NULL::numeric
        END AS annual_leave_available_days,
    anonymised_at,
    anonymised_by
   FROM employees
  WHERE has_permission('module.hr.view'::text) OR id = current_user_employee();

-- db/views/employee_directory.sql
-- 员工目录:一名【在册】员工一行。读遮蔽伴生视图而非基表,遮蔽因此是继承来的。
-- 年假三列(年度费率 / 已累积 / 可请)同样继承自 employees_masked。
-- SECURITY INVOKER。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE OR REPLACE VIEW public.employee_directory WITH (security_invoker = on) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    e.department_id,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    -- KPI-1:这里的 e 是 employees_masked,不是 employees ——
    -- 那张视图已经把 job_title 换成从职位来了,所以这一行【原样不动】。
    e.job_title,
    e.manager_id,
    mgr.code AS manager_code,
    mgr.legal_name AS manager_name,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    e.annual_leave_rate_days,
    e.annual_leave_accrued_days,
    e.annual_leave_available_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_expiry_date,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::integer
            ELSE e.work_pass_expiry_date - CURRENT_DATE
        END AS days_to_work_pass_expiry,
        CASE
            WHEN e.work_pass_expiry_date IS NULL THEN NULL::text
            WHEN e.work_pass_expiry_date < CURRENT_DATE THEN 'expired'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 30 THEN 'critical'::text
            WHEN (e.work_pass_expiry_date - CURRENT_DATE) <= 90 THEN 'warning'::text
            ELSE NULL::text
        END AS work_pass_alert,
    pay.gross_pay AS current_gross_pay,
    pay.period_month AS current_pay_period,
    COALESCE(tr.training_count, 0::bigint) AS training_count
   FROM employees_masked e
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees_masked mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT pl.gross_pay,
            pp.period_month
           FROM payroll_lines_masked pl
             JOIN payroll_periods pp ON pp.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND pp.status = 'posted'::text AND pp.deleted_at IS NULL
          ORDER BY pp.period_month DESC
         LIMIT 1) pay ON true
     LEFT JOIN LATERAL ( SELECT count(*) AS training_count
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
  WHERE e.deleted_at IS NULL;

-- db/views/my_review_subjects.sql
-- 评估人读得到的被评估人名录:每份"我评的评估"一行。
-- employees 的 SELECT 是 module.hr.view 或本人,零 HR 权限的部门经理据此读不到
-- 被评估人的名字 —— /my-reviews 会只剩一串 uuid。修法沿用 cut 2b 的属主权限视图:
-- 行谓词把基表那条 "select as reviewer" 策略【原样】写进视图体。
-- 【列清单就是权限边界】工号、姓名、职务、部门名、评估轮名;
-- 没有薪酬、没有证件号、没有银行、没有在职状态。
--
-- NOTE: introduced by db/migrations/2026-08-03-hr3d-ui-read-support.sql.

CREATE OR REPLACE VIEW public.my_review_subjects WITH (security_invoker = off) AS
 SELECT r.id AS review_id,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name AS employee_name,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- **列名保持 job_title**,是为了不惊动这张视图的下游读者 ——
    -- 它回答的仍然是同一个问题(这个人的头衔是什么),只是真源换了。
    (SELECT p.title FROM positions p WHERE p.id = e.position_id) AS job_title,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    c.name AS cycle_name
   FROM performance_reviews r
     JOIN employees e ON e.id = r.employee_id
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN review_cycles c ON c.id = r.cycle_id
  WHERE r.reviewer_employee_id = current_user_employee();

COMMENT ON VIEW public.my_review_subjects IS
    '评估人读得到的被评估人名录:每份"我评的评估"一行。列清单就是权限边界 —— 只有名录与评估轮名,没有任何受限数据。';

-- db/views/my_profile.sql
-- 员工自助的那一行。属主权限 + 视图体里的 current_user_employee() 谓词。
-- 【敏感列照给】—— 那是这个人自己的数据。年假三列同 employees_masked。
--
-- NOTE: introduced by db/migrations/2026-08-06-hr2c-monthly-accrual.sql;
--       annual-rate form by db/migrations/2026-08-07-hr2c-fu1-annual-rate-and-immutable-rates.sql.

CREATE OR REPLACE VIEW public.my_profile WITH (security_invoker = off) AS
 SELECT e.id AS employee_id,
    e.code,
    e.legal_name,
    e.preferred_name,
    -- KPI-1:employees.job_title 已删,头衔改从【职位】来。
    -- 列名保持 job_title,是为了让 /me 那一格与它的历史记录读起来仍然是同一件事
    -- (employment_history.job_title 是那一天的文本快照,这里是"今天的")。
    pos.title AS job_title,
    e.employment_type,
    e.work_category,
    e.employment_status,
    e.hire_date,
    e.probation_end_date,
    annual_leave_rate_per_year(e.id) AS annual_leave_rate_days,
    accrued_annual_leave(e.id) AS annual_leave_accrued_days,
    (leave_balance_internal(e.id, 'annual'::text) ->> 'available'::text)::numeric AS annual_leave_available_days,
    e.residency_status,
    e.work_pass_type,
    e.work_pass_no,
    e.work_pass_issue_date,
    e.work_pass_expiry_date,
    e.identity_no,
    e.work_email,
    e.work_phone,
    d.name_en AS department_name_en,
    d.name_zh AS department_name_zh,
    mgr.legal_name AS manager_name,
    mgr.code AS manager_code,
    COALESCE(tr.cnt, 0::bigint) AS training_count,
    pp.code AS latest_payroll_code,
    pp.period_month AS latest_payroll_month,
    -- KPI-1:【新列加在末尾】—— CREATE OR REPLACE VIEW 只允许在末尾追加列,
    -- 中间插一列要 DROP + 重建,而这张视图有下游读者。
    pos.code AS position_code
   FROM employees e
     LEFT JOIN positions pos ON pos.id = e.position_id
     LEFT JOIN departments d ON d.id = e.department_id
     LEFT JOIN employees mgr ON mgr.id = e.manager_id
     LEFT JOIN LATERAL ( SELECT count(*) AS cnt
           FROM training_records t
          WHERE t.employee_id = e.id AND t.deleted_at IS NULL) tr ON true
     LEFT JOIN LATERAL ( SELECT p.code,
            p.period_month
           FROM payroll_lines pl
             JOIN payroll_periods p ON p.id = pl.payroll_period_id
          WHERE pl.employee_id = e.id AND p.status = 'posted'::text AND p.deleted_at IS NULL
          ORDER BY p.period_month DESC
         LIMIT 1) pp ON true
  WHERE e.id = current_user_employee() AND e.deleted_at IS NULL;


-- ═══ 第 6 步:派生视图(roll-up 与联动矩阵,不建表)═══════════════════
-- db/views/kpi_position_linkage_matrix.sql
-- KPI-1:联动矩阵 —— **职位这一层**。派生,不另存(规格 §9.1)。
--
-- ★★【原表第五页那六行数字,必须能从链接列【算出来】,而规格已经验算过】★★
--   §9.1 逐人统计过一遍,与原表写死的六行【逐格相同】(六行全中)。
--   所以"矩阵是派生的"是一句**被验过的话**,不是一句设计意图 ——
--   而本视图就是那次验算的可执行版本:fixture 146 拿它与 §9.1 那张表逐格对。
--
-- ★【为什么要有【职位级】这一张,而原表画的是【员工级】】★(Tim 2026-08-29)
--   原表六行是六个人,而六个人与六个职位一一对应。
--   **员工级那张今天是空的**(线上只有两个人挂了职位,原表另外四个人根本没有员工档案),
--   于是它**验不了** —— 一张空矩阵与一张对的矩阵长得一样。
--   职位级这一张在模板种下去的那一刻就是满的,而且【可以对着原表逐格核】。
--   两张都要,各自标清楚是哪一层 —— 见 kpi_employee_linkage_matrix。
--
-- ★★【这句话必须贴着数字放,原表原文,不许改写】★★(§9.1)
--   *A single employee KPI can support more than one organization KPI. The detailed
--   Employee KPIs sheet preserves the exact linkage. The matrix is a management view
--   of coverage, not a mathematical re-weighting of the organization scorecard.*
--
--   **为什么它必须贴着数字:** 那六行数字长得像权重(整数、按组织 KPI 分列,
--   下面还紧跟着一行 Weight 25/25/20/15/15)。没有这句话在旁边,
--   第一个读它的人会把「Sandra 在 O4 上有 5 条」读成「Sandra 的 O4 权重是 5」。
--
-- 【属主权限】它 join positions + templates + links 三张表,都在 HR 门内,
-- 谓词写进视图体(OPS-14 的补救 (a))。

CREATE VIEW public.kpi_position_linkage_matrix WITH (security_invoker = off) AS
 SELECT p.code AS position_code,
    p.title AS position_title,
    p.sort_order,
    count(*) FILTER (WHERE l.org_code = 'O1') AS o1_count,
    count(*) FILTER (WHERE l.org_code = 'O2') AS o2_count,
    count(*) FILTER (WHERE l.org_code = 'O3') AS o3_count,
    count(*) FILTER (WHERE l.org_code = 'O4') AS o4_count,
    count(*) FILTER (WHERE l.org_code = 'O5') AS o5_count,
    count(DISTINCT t.id) AS kpi_count,
    -- 【权重合计放在这里,是为了让那道闸的结果【看得见】】
    -- 子查询而不是 sum(t.weight_pct):上面 LEFT JOIN 链接表会把一条链两个组织
    -- KPI 的模板行【复制成两行】,直接 sum 会把它的权重算两遍。
    -- (这正是 §9.1 那句"矩阵是覆盖度不是权重"在 SQL 里的样子。)
    (SELECT COALESCE(sum(t2.weight_pct), 0)
       FROM kpi_position_templates t2 WHERE t2.position_id = p.id) AS weight_total
   FROM positions p
     JOIN kpi_position_templates t ON t.position_id = p.id
     LEFT JOIN kpi_template_org_links l ON l.template_id = t.id
  WHERE has_permission('module.hr.view'::text)
  GROUP BY p.id, p.code, p.title, p.sort_order;

COMMENT ON VIEW public.kpi_position_linkage_matrix IS
'KPI-1:联动矩阵的【职位】那一层 —— 派生,不另存(规格 §9.1:原表第四、五页每一个数字都能从 KPI 行推导,原表自己就是用公式算的)。★**这句话必须贴着数字放,原表原文**★:*A single employee KPI can support more than one organization KPI. The detailed Employee KPIs sheet preserves the exact linkage. **The matrix is a management view of coverage, not a mathematical re-weighting of the organization scorecard.*** —— 因为那六行数字长得像权重(整数、按组织 KPI 分列,下面还跟着 Weight 25/25/20/15/15),没有这句话在旁边,第一个读的人会把「Sandra 在 O4 上有 5 条」读成「Sandra 的 O4 权重是 5」。**为什么有职位级这一张**:原表画的是员工级,而员工级今天是空的(只有两人挂了职位,原表另外四人没有员工档案),空矩阵与对的矩阵长得一样、验不了;职位级在模板种下的那一刻就是满的,而且可以对着原表逐格核 —— fixture 146 就是这么核的。';

-- db/views/kpi_employee_linkage_matrix.sql
-- KPI-1:联动矩阵 —— **员工这一层**,也就是原表第五页画的那一张。派生,不另存(§9.1)。
--
-- ★★【它今天【是空的】,而那必须被【说出来】,不能画成一片零】★★(Tim 2026-08-29)
--   实测:线上只有两个真员工(其余 19 行是 ZZ-* 脚手架),
--   而原表点名的六个人里【四个根本没有员工档案】。
--   **一张画满零的矩阵读起来是「这些人什么都没贡献」** ——
--   而事实是"他们还没被建档"。两句话差得很远,屏幕上必须分得开。
--   所以本视图只返回【真的有条目的人】,而"六个人里只到了两个"这句话
--   由页面上的具名缺席去说(见 /hr/kpi 那一段)。
--
-- 【它从 kpi_entries.org_codes 这个【快照数组】推导,而职位级那张从链接表推导】
--   两份推导是**刻意的**,不是重复:复制之后改模板,两边本来就该分开 ——
--   那正是"复制不是引用"看得见的样子。一份实现会把这件事藏起来。

CREATE VIEW public.kpi_employee_linkage_matrix WITH (security_invoker = off) AS
 SELECT e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name,
    p.code AS position_code,
    k.cycle_id,
    count(*) FILTER (WHERE c.org_code = 'O1') AS o1_count,
    count(*) FILTER (WHERE c.org_code = 'O2') AS o2_count,
    count(*) FILTER (WHERE c.org_code = 'O3') AS o3_count,
    count(*) FILTER (WHERE c.org_code = 'O4') AS o4_count,
    count(*) FILTER (WHERE c.org_code = 'O5') AS o5_count,
    count(DISTINCT k.id) AS kpi_count
   FROM kpi_entries k
     JOIN employees e ON e.id = k.employee_id
     JOIN positions p ON p.id = k.source_position_id
     LEFT JOIN LATERAL unnest(k.org_codes) AS c(org_code) ON true
  WHERE has_permission('module.hr.view'::text)
    AND has_permission('data.view_reviews'::text)
  GROUP BY e.id, e.code, e.legal_name, p.code, k.cycle_id;

COMMENT ON VIEW public.kpi_employee_linkage_matrix IS
'KPI-1:联动矩阵的【员工】那一层 —— 原表第五页画的就是这一张。派生,不另存。★**它今天是空的,而那必须被说出来、不能画成一片零**★:线上只有两个真员工,原表点名的六个人里四个没有员工档案 —— 一张画满零的矩阵读起来是「这些人什么都没贡献」,而事实是「他们还没被建档」。本视图只返回真的有条目的人,"六个里只到了两个"由页面上的具名缺席去说。**它从 kpi_entries.org_codes 这个快照数组推导,而职位级那张从链接表推导 —— 两份推导是刻意的**:改了模板之后两边本来就该分开,那正是"复制不是引用"看得见的样子;一份实现会把这件事藏起来。';

-- db/views/kpi_employee_rollup.sql
-- KPI-1:Associate Roll-up —— 原表第四页。**派生,不另存**(规格 §9.1)。
--
-- 原表那两列本来就是公式:
--   `Weighted score achieved` = `=SUM('Asspcoate KPIs'!J5:J9)`
--   `Performance %`           = `=IF(C5=0,"",D5/C5)`
-- 而每条 KPI 的加权分在原表里是 `=IF(I5="","",I5/5*C5)` —— 也就是 分/5 × 权重。
-- 本视图逐字照这个算,不另发明。
--
-- ★【生效分 = LEAST(分, 封顶)】★ 安全/监管否决是一个【封顶】动作(原表第六页):
--   「Major breach can cap score at 0–2」、「Any unauthorized operation = 0」。
--   **原始分与封顶都留在行上**,这里算的是生效分 —— 于是事后仍然分得清
--   「他本来就只有 2 分」与「他被封到 2 分」。
--
-- ★【没打分的不算 0】★ 原表的公式是 `=IF(I5="","",…)` —— 空就是空,不是零。
--   本视图跟着它:`scored_count` 与 `kpi_count` 分开报,
--   于是"五条打了两条"与"五条都打了但分低"在屏幕上分得开。
--   **把没打分的当成 0,是把"还没评"读成"评了个不及格"** ——
--   与 lib/permissions.ts 存在的理由(null ≠ 0)是同一条。

CREATE VIEW public.kpi_employee_rollup WITH (security_invoker = off) AS
 SELECT k.cycle_id,
    cy.name AS cycle_name,
    cy.gate,
    e.id AS employee_id,
    e.code AS employee_code,
    e.legal_name,
    p.code AS position_code,
    p.title AS position_title,
    count(*) AS kpi_count,
    count(*) FILTER (WHERE k.score IS NOT NULL) AS scored_count,
    count(*) FILTER (WHERE k.score_kind = 'computed') AS computed_count,
    count(*) FILTER (WHERE k.score_kind = 'judged') AS judged_count,
    count(*) FILTER (WHERE k.override_cap IS NOT NULL) AS capped_count,
    count(*) FILTER (WHERE k.is_provisional) AS provisional_count,
    sum(k.weight_pct) AS weight_total,
    -- 加权分 = Σ(生效分 / 5 × 权重),只算【打过分的】那些行
    round(COALESCE(sum(
        LEAST(k.score, COALESCE(k.override_cap, 5))::numeric / 5 * k.weight_pct
    ) FILTER (WHERE k.score IS NOT NULL), 0), 2) AS weighted_score_achieved,
    -- Performance % —— 原表 =IF(C5=0,"",D5/C5)。分母是【打过分的那些行的权重和】,
    -- 不是 100:五条打了两条时,拿 100 做分母会把"还没评"读成"没做到"。
    CASE WHEN COALESCE(sum(k.weight_pct) FILTER (WHERE k.score IS NOT NULL), 0) = 0
         THEN NULL
         ELSE round(
             COALESCE(sum(LEAST(k.score, COALESCE(k.override_cap, 5))::numeric / 5 * k.weight_pct)
                      FILTER (WHERE k.score IS NOT NULL), 0)
             / sum(k.weight_pct) FILTER (WHERE k.score IS NOT NULL) * 100, 1)
    END AS performance_pct
   FROM kpi_entries k
     JOIN employees e ON e.id = k.employee_id
     JOIN positions p ON p.id = k.source_position_id
     JOIN kpi_cycles cy ON cy.id = k.cycle_id
  WHERE has_permission('module.hr.view'::text)
    AND has_permission('data.view_reviews'::text)
  GROUP BY k.cycle_id, cy.name, cy.gate, e.id, e.code, e.legal_name, p.code, p.title;

COMMENT ON VIEW public.kpi_employee_rollup IS
'KPI-1:Associate Roll-up(原表第四页),**派生不另存**(§9.1)。逐字照原表的公式算:每条加权分 = 分/5 × 权重(`=IF(I5="","",I5/5*C5)`),合计 = SUM,Performance % = D5/C5。**生效分 = LEAST(分, 封顶)** —— 安全/监管否决是一个封顶动作(原表第六页),而原始分与封顶都留在行上,所以事后分得清「本来就 2 分」与「被封到 2 分」。★**没打分的不算 0**★:原表公式就是 `=IF(I5="","",…)`,空是空不是零;`scored_count` 与 `kpi_count` 分开报,performance% 的分母是【打过分那些行的权重和】而不是 100 —— 五条打了两条时拿 100 做分母,会把"还没评"读成"没做到",与 lib/permissions.ts 存在的理由(null ≠ 0)同一条。';

-- db/views/my_kpi_entries.sql
-- KPI-1:【本人】看自己这个周期被考核的那五条 —— /me 上那块自助面板读的就是它。
--
-- ★★【它与 review_goals 那条自评可见性策略【刻意不同】,而差别要说清楚】★★
--   `review_goals` 有一条 SELECT 策略:本人只在评估 `approved`/`acknowledged`
--   之后才看得见自己的目标行。理由是**自评过程中的草稿不该被当事人看到**。
--   **KPI 条目不是那种东西**:它是「你这个周期被考核的是哪五条、标准是什么」——
--   那是【期初就该让人知道】的事,藏起来才是错的。
--   所以本人【始终】看得见自己的条目与目标。
--
--   ★ 而【分数】不同:一个还没定稿的分数被当事人提前看到,
--     与自评草稿被看到是同一件事。所以本视图在周期 `closed` 之前
--     **把分数一族整列压成 NULL**,并用 `score_visible` 说出"为什么现在没有分"——
--     **不是留白**:一个空着的分数与一个"还没打"的分数长得一样,
--     而人会把前者读成"我得了 0 分"。
--
-- 【属主权限】它 join kpi_entries + kpi_cycles + positions,而本人这条路
--   不该要求 data.view_reviews(那是 HR 看别人的门)。谓词写进视图体:
--   employee_id = current_user_employee()。

CREATE VIEW public.my_kpi_entries WITH (security_invoker = off) AS
 SELECT k.id,
    k.cycle_id,
    cy.name AS cycle_name,
    cy.status AS cycle_status,
    cy.gate,
    cy.period_start,
    cy.period_end,
    cy.due_date,
    p.code AS position_code,
    p.title AS position_title,
    k.kpi_ref,
    k.title,
    k.weight_pct,
    k.target_text,
    k.evidence_source,
    k.is_provisional,
    k.provisional_note,
    k.org_codes,
    k.source_template_version,
    -- ★ 分数只在周期关掉之后才对本人可见 —— 见抬头
    (cy.status = 'closed') AS score_visible,
    CASE WHEN cy.status = 'closed' THEN k.score END AS score,
    CASE WHEN cy.status = 'closed' THEN k.score_kind END AS score_kind,
    CASE WHEN cy.status = 'closed' THEN k.computed_basis END AS computed_basis,
    CASE WHEN cy.status = 'closed' THEN k.evidence_note END AS evidence_note,
    CASE WHEN cy.status = 'closed' THEN k.override_cap END AS override_cap,
    CASE WHEN cy.status = 'closed' THEN k.override_reason END AS override_reason
   FROM kpi_entries k
     JOIN kpi_cycles cy ON cy.id = k.cycle_id
     JOIN positions p ON p.id = k.source_position_id
  WHERE k.employee_id = current_user_employee();

COMMENT ON VIEW public.my_kpi_entries IS
    'KPI-1:本人看自己被考核的那五条(/me 的自助面板)。★**与 review_goals 那条自评可见性策略刻意不同**★:那一条把自评正文压到 approved/acknowledged 之后才可见,因为**自评草稿不该被当事人看到**;而 KPI 条目是「你这个周期被考核的是哪五条」—— 期初就该让人知道,藏起来才是错的,所以条目与目标【始终】可见。★**但分数不同**★:一个还没定稿的分数被提前看到,与自评草稿被看到是同一件事,所以周期 closed 之前分数一族整列压成 NULL,并由 `score_visible` 说出为什么现在没有分 —— **不是留白**,因为一个空着的分数与"打了 0 分"长得一样。';


-- ── 现在才删 employees.job_title —— ★顺序不是风格问题★ ─────────────────────
-- 【为什么放在最后】my_profile 今天 SELECT e.job_title,
-- 而**一个被视图引用的列删不掉**(PostgreSQL 会拒)。所以必须先把那张视图
-- 替换成读 positions.title 的版本(就在上面),这一句才走得通。
-- employment_history 上的同名列【不动】:它是不可变的履历快照,见本文件抬头。
ALTER TABLE public.employees DROP COLUMN job_title;

COMMIT;
