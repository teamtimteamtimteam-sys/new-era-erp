-- db/tables/samples.sql
-- MES-6a-1(2026-10-09,MES-0 功能 15 · Q53 · Q61;MES-6a Step 0 Q7–Q10 · Q14 · Q15,Tim):【一份实物样品】—— 从一批货上取下来的那一罐。
--   SETTLE-1 留下的那个"说出来的未满足前提"(仲裁要送第三方复检,而复检要有一个罐子)在这里落地:系统从此说得出一份样品
--   是谁的、哪一批的、在谁手上、在哪儿、还留多久、处置了没有。
--
--   【编号】SMP-YYYY-NNNN,按年、无洞(next_sample_code;document_types 里的 'sample',MES-0 Q53)。
--   【父】恰好一批 —— 进料批或产出批(num_nonnulls = 1,化验单 assay_results_one_parent 的同一个形状)。
--   【种类】ours · counterparty · umpire · retained · contamination(MES-0 Q61)。种类说的是这一罐【为谁、为什么】取的,
--     不说它现在在哪 —— 那是 sample_events 的事。contamination 那一种可以指一条交叉污染抽检(MES-4b 的表一字未改,Q10)。
--   【留到哪一天】retain_until 在建的那一刻【抄下来】,以后不改(Q8):
--     · 指了一张销售单、而那张单挂着的合同副本(contract_document_terms.settlement_terms)要求留样并写了天数 → 取样日 + 合同天数(contract);
--     · 否则 → 取样日 + V16(quality_settings.internal_retention_days,internal);
--     · V16 也是空的 → retain_until 为空,屏幕上是 "Not yet set"(not_set)—— 没有人说过留多久,系统不编一个。
--     V16 或合同以后改了,【不】回头改一份已有的样品(retain_until_source 与 retention_days_at 说清楚当时按的是什么)。
--   【写】只经 SECURITY DEFINER 函数 record_sample(module.quality.edit)—— 表上一条写策略都没有。保管与处置写在 sample_events(只追加)。
--   【读】module.quality.view,或那一批自己那一页的查看码(Q11:批次与化验页上的样品面板给两种码任一的人看)。
--   【没有金额】这里只有克数与日期,所以没有遮蔽的列(Q40)。
--
-- NOTE: introduced by db/migrations/2026-10-09-mes6a1-samples-and-disputes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.samples (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                   text NOT NULL UNIQUE,
    inbound_batch_id       uuid REFERENCES public.inbound_batches (id),
    output_batch_id        uuid REFERENCES public.output_batches (id),
    kind                   text NOT NULL CHECK (kind IN ('ours', 'counterparty', 'umpire', 'retained', 'contamination')),
    taken_on               date NOT NULL,
    mass_g                 numeric CHECK (mass_g IS NULL OR mass_g > 0),
    -- 可选:这一罐是为哪一张销售单留的(只有产出批有销售单)—— 留样天数从那张单挂着的合同副本里读(Q8)
    sales_order_id         uuid REFERENCES public.sales_orders (id),
    -- 可选:kind = contamination 时指它那一条交叉污染抽检(Q10)
    contamination_check_id bigint REFERENCES public.contamination_checks (id),
    retain_until           date,
    retain_until_source    text NOT NULL CHECK (retain_until_source IN ('contract', 'internal', 'not_set')),
    retention_days_at      integer CHECK (retention_days_at IS NULL OR retention_days_at > 0),
    notes                  text,
    created_at             timestamptz NOT NULL DEFAULT now(),
    created_by             uuid DEFAULT auth.uid(),
    CONSTRAINT samples_one_parent CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT samples_sales_order_on_output CHECK (sales_order_id IS NULL OR output_batch_id IS NOT NULL),
    CONSTRAINT samples_check_only_for_contamination CHECK (contamination_check_id IS NULL OR kind = 'contamination'),
    -- 【留到哪一天与它的出处必须同时成立】not_set ⇔ 没有日期、没有天数;其余两种 ⇔ 两样都有,而日期 = 取样日 + 天数
    CONSTRAINT samples_retention_consistent CHECK (
        (retain_until_source = 'not_set' AND retain_until IS NULL AND retention_days_at IS NULL)
        OR (retain_until_source IN ('contract', 'internal') AND retention_days_at IS NOT NULL
            AND retain_until = taken_on + retention_days_at))
);

CREATE INDEX samples_inbound_batch_id_rel ON public.samples (inbound_batch_id);
CREATE INDEX samples_output_batch_id_rel ON public.samples (output_batch_id);
CREATE INDEX samples_sales_order_id_rel ON public.samples (sales_order_id);
CREATE INDEX samples_contamination_check_id_rel ON public.samples (contamination_check_id);
-- 搜索:code 的后缀匹配(与 blending_plans 同一条)
CREATE INDEX samples_code_trgm ON public.samples USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.samples IS
    'MES-6a-1:一份实物样品(SMP-YYYY-NNNN)—— 一批货(进料或产出,恰好一个)上取下来的一罐。种类 ours / counterparty / umpire / retained / contamination(MES-0 Q61)。留到哪一天在建的那一刻抄下(合同天数、否则 V16、否则 Not yet set),以后不改(Q8)。保管与处置是 sample_events(只追加);谁拿着、在哪、什么状态都从最近那一条读(sample_rows)。写只经 record_sample(module.quality.edit)。';
COMMENT ON COLUMN public.samples.retain_until IS
    '留到哪一天。建的那一刻 = 取样日 + 合同副本的留样天数(那张销售单的合同要求留样时)或 + V16;两样都没有时为空 —— 屏幕上是 Not yet set,不编日子,也不进 sample_retention_due 的提醒。以后改合同或 V16【不】回头改它。';
COMMENT ON COLUMN public.samples.retain_until_source IS
    'retain_until 按的是什么:contract(销售单挂着的合同副本)· internal(V16,quality_settings.internal_retention_days)· not_set(都没有)。';
COMMENT ON COLUMN public.samples.contamination_check_id IS
    'kind = contamination 时可以指它那一条交叉污染抽检(MES-4b,contamination_checks;那张表本刀一字未改)。那条抽检必须是同一批产出批上的、取过样的那一种。';

ALTER TABLE public.samples ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码,或那一批自己那一页的查看码(Q11)。写:一条策略都不给 —— 只经 record_sample。
CREATE POLICY "samples select by permission" ON public.samples
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text)
        OR (inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));
GRANT SELECT ON public.samples TO authenticated;
REVOKE ALL ON public.samples FROM anon;
