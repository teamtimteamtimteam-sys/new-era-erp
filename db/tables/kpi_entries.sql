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
-- NOTE: introduced by db/migrations/2026-08-29-kpi1-positions-and-the-kpi-framework.sql.
-- First-run script (plain CREATEs).

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
