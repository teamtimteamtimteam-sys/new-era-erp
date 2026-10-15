-- db/tables/quality_limit_judgements.sql
-- MES-6b-1(2026-10-15,V17;MES-6b Step 0 Q26 · Q27,Tim):【一次质量验收限的判定】—— 一批产出批的一份化验,对着一张销售单挂着的合同副本里
--   的一个参数,判出来是什么。只追加,一行写下就不改不删(guard_append_only_log)。
--
--   【什么时候判】(judge_quality_limits,内层)两个时刻:
--     · record_assay_result 记下一份产出化验,而这一批已经预留给一张挂着【有限】的合同的销售单(trigger_event = 'assay_recorded');
--     · reserve_stock_internal 把一批【已经有化验】的产出批预留给这样一张销售单(trigger_event = 'reserved')。
--   【判哪一份化验】合同结算口径约定的那一方(settling_party)最新的一份没删的结果;那一批有过一件已结案、点名了说了算的那一份的争议时,
--     读那一份(governing_assay_id)—— 与结算选化验同一条规矩。
--   【判什么】那张销售单的合同副本(contract_document_terms.settlement_terms)里 quality_limit_basis = per_parameter 时,它的 quality_limits
--     里【适用于这批物料】的每一个参数(指了这种物料的那一行优先于空物料的那一行)。限【抄进本行】(limit_min_at / limit_max_at):
--     以后谁也改不了一条旧判定的依据 —— 合同改了也不回头判(Q26;副本本来就是挂接那一刻冻下的)。
--   【结果】within · below_min · above_max · not_measured(那份化验没报这个参数:value 为空 —— 空永远不是零,也不是"在限内",C3)。
--   【一次】(批 × 销售单 × 化验 × 参数)一行(唯一约束):同一份化验对同一张单的同一个参数只判一次 —— 部分发货就地重新预留、或同一张单的
--     第二行预留同一批,都不会再判一遍。一份【新的】化验是一个新的事实,照判。
--   【越限】below_min / above_max → 同一笔事务里开一张来源 quality_limit 的不合格报告(nonconformance_reports.judgement_id 指回本行)
--     → 这一批进质量暂扣(Q27:预留照留,不拒;发货被暂扣挡住)。not_measured 不开。
--   【读】module.quality.view,或产出批的查看码(判定挂在批次上,Q39)。写:一条策略都没有 —— 只经 judge_quality_limits。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.quality_limit_judgements (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    output_batch_id  uuid NOT NULL REFERENCES public.output_batches (id),
    sales_order_id   uuid NOT NULL REFERENCES public.sales_orders (id),
    contract_id      uuid NOT NULL REFERENCES public.contracts (id),
    assay_result_id  uuid NOT NULL REFERENCES public.assay_results (id),
    parameter        text NOT NULL,
    -- 判的那个值:水分取化验的 moisture_pct,指标取 assay_result_indicators;没报 = 空
    value            numeric,
    -- 判的那一刻在效的限,抄下来(V36 · V11 · V9 的先例:range_min_at · warning_pct_at · pass_voltage_v_at)
    limit_min_at     numeric,
    limit_max_at     numeric,
    result           text NOT NULL CHECK (result IN ('within', 'below_min', 'above_max', 'not_measured')),
    trigger_event    text NOT NULL CHECK (trigger_event IN ('assay_recorded', 'reserved')),
    judged_at        timestamptz NOT NULL DEFAULT now(),
    judged_by        uuid DEFAULT auth.uid(),
    CONSTRAINT quality_limit_judgements_once UNIQUE (output_batch_id, sales_order_id, assay_result_id, parameter),
    CONSTRAINT quality_limit_judgements_a_limit CHECK (limit_min_at IS NOT NULL OR limit_max_at IS NOT NULL),
    -- 【结果与它的证据必须同时成立】没报 ⇔ 没有值;越下限 ⇔ 有下限且值低于它;越上限 ⇔ 有上限且值高于它
    CONSTRAINT quality_limit_judgements_result_consistent CHECK (
        (result = 'not_measured' AND value IS NULL)
        OR (result = 'below_min' AND value IS NOT NULL AND limit_min_at IS NOT NULL AND value < limit_min_at)
        OR (result = 'above_max' AND value IS NOT NULL AND limit_max_at IS NOT NULL AND value > limit_max_at
            AND (limit_min_at IS NULL OR value >= limit_min_at))
        OR (result = 'within' AND value IS NOT NULL
            AND (limit_min_at IS NULL OR value >= limit_min_at) AND (limit_max_at IS NULL OR value <= limit_max_at)))
);

CREATE INDEX quality_limit_judgements_output_batch_id_rel ON public.quality_limit_judgements (output_batch_id);
CREATE INDEX quality_limit_judgements_sales_order_id_rel ON public.quality_limit_judgements (sales_order_id);
CREATE INDEX quality_limit_judgements_contract_id_rel ON public.quality_limit_judgements (contract_id);
CREATE INDEX quality_limit_judgements_assay_result_id_rel ON public.quality_limit_judgements (assay_result_id);

COMMENT ON TABLE public.quality_limit_judgements IS
    'MES-6b-1(V17;Step 0 Q26 · Q27):一次质量验收限的判定 —— 一批产出批 × 一张销售单(它的合同副本)× 一份化验(合同约定一方最新的那份,或已结案争议点名的那份)× 一个参数,一行。限抄进本行,合同以后改了不回头判;同一份化验对同一张单的同一个参数只判一次。结果 within / below_min / above_max / not_measured(没报 ≠ 在限内)。越限在同一笔事务里开一张 quality_limit 的不合格报告(→ 质量暂扣)。只追加;只经 judge_quality_limits 写;读 module.quality.view 或产出批的查看码。';
COMMENT ON COLUMN public.quality_limit_judgements.trigger_event IS
    '判在哪一刻:assay_recorded(record_assay_result 记下一份产出化验,而这一批已预留给这张单)· reserved(reserve_stock_internal 把一批已有化验的产出批预留给这张单)。';

ALTER TABLE public.quality_limit_judgements ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码,或产出批的查看码(Q39:判定挂在批次上)。写:一条策略都不给 —— 只经 judge_quality_limits。
CREATE POLICY "quality limit judgements select by permission" ON public.quality_limit_judgements
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text) OR has_permission('module.output.view'::text));
GRANT SELECT ON public.quality_limit_judgements TO authenticated;
REVOKE ALL ON public.quality_limit_judgements FROM anon;

-- 只追加:改、删、清空一律语句级拒 APPEND_ONLY|<表>|<操作>(没有写策略时行级触发器在 RLS 那里醒不过来 —— guard_append_only_log 的理由)
CREATE TRIGGER trg_quality_limit_judgements_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.quality_limit_judgements
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
