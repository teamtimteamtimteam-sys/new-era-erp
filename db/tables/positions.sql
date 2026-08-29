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
-- NOTE: introduced by db/migrations/2026-08-29-kpi1-positions-and-the-kpi-framework.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

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
