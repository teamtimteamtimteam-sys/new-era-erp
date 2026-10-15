-- db/tables/nonconformance_reports.sql
-- MES-6b-1(2026-10-15,MES-0 功能 17 · Q53 · Q65 · Q66;MES-6b Step 0 Q2 · Q7 · Q9 · Q21 · Q22,Tim):【一张不合格报告(NCR)】——
--   有人(或系统)说"这一批货有问题,先别动它",直到另一个人决定怎么处置。
--
--   【它就是质量暂扣】(Q2):一批货在【它有一张 open 的不合格报告】期间处于质量暂扣 —— 没有第二张"暂扣"表,一件事一条记录、一条放行的路。
--     手动暂扣 = 开一张来源 manual 的报告。hold_stock / release_stock(库存桶 on_hold)仍是它自己那件库存动作,与这里无关。
--     暂扣挡什么、放什么在流水上的那一道守卫里(guard_quality_hold,inventory_movements BEFORE INSERT);另外三处明着问:销售结算
--     (sale_settlement_compute)与配料计划(建 / 改不收、放行拒)。判"这一批此刻是不是被暂扣"只有一支:batch_quality_hold。
--   【编号】NCR-YYYY-NNNN,按年、无洞(next_ncr_code;document_types 的 'ncr';宽度 GREATEST(4, 位数) —— CODE-WIDTH-4)。
--   【父】恰好一批 —— 进料批或产出批(num_nonnulls = 1)。一批可以同时有几张开着的;暂扣持续到【每一张】都决定了(Q7)。
--   【来源】manual(人开的)· customer_complaint(客户投诉,人开的)· quality_limit(系统开的:一次 V17 越限,judgement_id 指那一行判定)·
--     inspection(留给 MES-7b 的来料检验,今天开不出来 —— open_ncr 按名拒)。【只有 V17 越限自动开】(Q6):来料品位违反、交叉污染过 V11、
--     放电失败只在提醒(quality_prompt_ncr)里提示人去开一张。
--   【可选的指向】一份化验、一件化验争议、一张销售单(只有产出批有)、一行判定 —— 都必须是同一批的(open_ncr 判)。
--   【两态】open → decided,只经函数(Q7):
--     open     open_ncr(module.quality.edit;人开的)/ judge_quality_limits(系统开的,opened_by 为空)。描述必填。
--              人开的:除开单人这个【人】之外,没有一个真持有人持 action.ncr_decide,就不让它生下来(NCR_NO_OTHER_DECIDER —— 否则它是一张
--              永远决定不了的报告,而它挡着那一批货)。
--     decided  decide_ncr(action.ncr_decide;cco · cto · admin)—— 处置 + 一句说明 + 谁、什么时候。【开单人永远不能决定自己开的那一张】
--              (forbid_self_approval,按人认 → SELF_APPROVAL_FORBIDDEN|raiser);系统开的(opened_by 空)任何持码人都能决定(Q9)。
--   【处置】(Q22)accept 放行 · accept_with_penalty 放行,并指出钱走哪一张既有单据(产出批 → 一张贷项通知申请 invoice_requests;
--     进料批 → 一张收货定价申请 receipt_price_requests)—— 报告本身【不带金额】· rework 放行(下一张加工单就是返工)·
--     downgrade 放行,只记下(没有改等级的函数 —— 登记在 known-issues)· reject 【不放行】:暂扣留着,直到这一批没有货了 ——
--     它的出路是既有的 CFO 注销申请(Q21;流水守卫在执行那张申请时放行注销)。
--   【只追加】决定之外,一行写下就不改:open → decided 那一次只许动决定那几列;不许删(guard_ncr_mutation)。更正 = 开一张新的、在描述里
--     指出旧的那一张。写只经上面那几支 SECURITY DEFINER 函数 —— 表上一条写策略都没有。
--   【读】module.quality.view,或那一批自己那一页的查看码(批次页上的暂扣那一行给两种码任一的人看,与样品同一个处置)。
--   【没有金额】—— 没有遮蔽的列(Q39)。
--
-- NOTE: introduced by db/migrations/2026-10-15-mes6b1-quality-hold-ncr-and-limits.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.nonconformance_reports (
    id                          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code                        text NOT NULL UNIQUE,
    inbound_batch_id            uuid REFERENCES public.inbound_batches (id),
    output_batch_id             uuid REFERENCES public.output_batches (id),
    source                      text NOT NULL CHECK (source IN ('manual', 'customer_complaint', 'quality_limit', 'inspection')),
    description                 text NOT NULL CHECK (btrim(description) <> ''),
    -- 可选的指向:都必须是同一批的(open_ncr 判;系统开的那一张由 judge_quality_limits 填)
    assay_result_id             uuid REFERENCES public.assay_results (id),
    assay_dispute_id            uuid REFERENCES public.assay_disputes (id),
    sales_order_id              uuid REFERENCES public.sales_orders (id),
    judgement_id                bigint REFERENCES public.quality_limit_judgements (id),
    status                      text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'decided')),
    opened_at                   timestamptz NOT NULL DEFAULT now(),
    -- 空 = 系统开的(quality_limit);人开的是开单人的账号
    opened_by                   uuid,
    disposition                 text CHECK (disposition IN ('accept', 'accept_with_penalty', 'reject', 'rework', 'downgrade')),
    decision_note               text,
    decided_at                  timestamptz,
    decided_by                  uuid,
    -- accept_with_penalty 时钱走的那一张既有单据:产出批 → 贷项通知申请;进料批 → 收货定价申请(Q22)
    penalty_invoice_request_id  uuid REFERENCES public.invoice_requests (id),
    penalty_price_request_id    uuid REFERENCES public.receipt_price_requests (id),
    CONSTRAINT nonconformance_reports_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    CONSTRAINT nonconformance_reports_sales_order_on_output CHECK (sales_order_id IS NULL OR output_batch_id IS NOT NULL),
    -- 系统开的 ⇔ 没有开单人,并且必须指着它那一行判定
    CONSTRAINT nonconformance_reports_system_opened CHECK (
        (source = 'quality_limit') = (opened_by IS NULL)
        AND (source <> 'quality_limit' OR judgement_id IS NOT NULL)),
    -- 【状态与它的证据必须同时成立】(配料计划、争议那几条 CHECK 的同一个理由:约束对任何写入者都成立)
    CONSTRAINT nonconformance_reports_decided_consistent CHECK (
        (status = 'open' AND disposition IS NULL AND decision_note IS NULL AND decided_at IS NULL AND decided_by IS NULL)
        OR (status = 'decided' AND disposition IS NOT NULL AND decision_note IS NOT NULL AND btrim(decision_note) <> ''
            AND decided_at IS NOT NULL AND decided_by IS NOT NULL)),
    -- 带罚的接受恰好指一张钱的单据,而且是这一批那一侧的那一种;别的处置一张都不指
    CONSTRAINT nonconformance_reports_penalty_document CHECK (
        (disposition IS DISTINCT FROM 'accept_with_penalty'
            AND penalty_invoice_request_id IS NULL AND penalty_price_request_id IS NULL)
        OR (disposition = 'accept_with_penalty' AND output_batch_id IS NOT NULL
            AND penalty_invoice_request_id IS NOT NULL AND penalty_price_request_id IS NULL)
        OR (disposition = 'accept_with_penalty' AND inbound_batch_id IS NOT NULL
            AND penalty_price_request_id IS NOT NULL AND penalty_invoice_request_id IS NULL))
);

CREATE INDEX nonconformance_reports_inbound_batch_id_rel ON public.nonconformance_reports (inbound_batch_id);
CREATE INDEX nonconformance_reports_output_batch_id_rel ON public.nonconformance_reports (output_batch_id);
CREATE INDEX nonconformance_reports_assay_result_id_rel ON public.nonconformance_reports (assay_result_id);
CREATE INDEX nonconformance_reports_assay_dispute_id_rel ON public.nonconformance_reports (assay_dispute_id);
CREATE INDEX nonconformance_reports_sales_order_id_rel ON public.nonconformance_reports (sales_order_id);
CREATE INDEX nonconformance_reports_judgement_id_rel ON public.nonconformance_reports (judgement_id);
CREATE INDEX nonconformance_reports_penalty_invoice_request_id_rel ON public.nonconformance_reports (penalty_invoice_request_id);
CREATE INDEX nonconformance_reports_penalty_price_request_id_rel ON public.nonconformance_reports (penalty_price_request_id);
-- 搜索:code 的后缀匹配(与 samples 同一条)
CREATE INDEX nonconformance_reports_code_trgm ON public.nonconformance_reports USING gin (code extensions.gin_trgm_ops);

COMMENT ON TABLE public.nonconformance_reports IS
    'MES-6b-1:一张不合格报告(NCR-YYYY-NNNN)—— 恰好一批(进料或产出)。它开着,那一批就在质量暂扣里(Step 0 Q2:没有另一张暂扣表;判据只有 batch_quality_hold):流水上不许投料、销售、发货、预留(guard_quality_hold),结算与配料计划也不收。来源 manual / customer_complaint(人开,module.quality.edit)· quality_limit(V17 越限时系统开)· inspection(留给 MES-7b)。open → decided 只经 decide_ncr(action.ncr_decide;开单人按人认永远不能决定自己那一张;系统开的任何持码人都能决定)。处置 accept / accept_with_penalty(指出钱走的那张贷项通知申请或收货定价申请,报告不带金额)/ rework / downgrade 放行;reject 不放行,出路是 CFO 注销申请,货没了暂扣就结束。决定之外只追加。';
COMMENT ON COLUMN public.nonconformance_reports.opened_by IS
    '开单人的账号;空 = 系统开的(来源 quality_limit:一次 V17 越限)。四眼认的就是它 —— 人开的那一张开单人这个人永远不能决定;系统开的没有开单人,任何持 action.ncr_decide 的人都能决定(Step 0 Q9)。';
COMMENT ON COLUMN public.nonconformance_reports.disposition IS
    '处置(MES-0 Q65):accept 放行 · accept_with_penalty 放行,钱走 penalty_invoice_request_id / penalty_price_request_id 指的那张既有单据 · rework 放行(下一张加工单就是返工)· downgrade 放行,只记下(今天没有改等级的函数)· reject 不放行 —— 暂扣留到这一批没有货(出路是 CFO 注销申请)。';

ALTER TABLE public.nonconformance_reports ENABLE ROW LEVEL SECURITY;
-- 读:质量查看码,或那一批自己那一页的查看码。写:一条策略都不给 —— 只经 open_ncr / decide_ncr / judge_quality_limits。
CREATE POLICY "nonconformance_reports select by permission" ON public.nonconformance_reports
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.quality.view'::text)
        OR (inbound_batch_id IS NOT NULL AND has_permission('module.inbound.view'::text))
        OR (output_batch_id IS NOT NULL AND has_permission('module.output.view'::text)));
GRANT SELECT ON public.nonconformance_reports TO authenticated;
REVOKE ALL ON public.nonconformance_reports FROM anon;

-- 只追加,唯一的例外是 open → decided 那一次(只许动决定那几列);不许删、不许清空。属主路径同样受它管 —— 它守的是记录的形状,不是权限。
CREATE TRIGGER trg_nonconformance_reports_mutation
    BEFORE UPDATE OR DELETE ON public.nonconformance_reports
    FOR EACH ROW EXECUTE FUNCTION public.guard_ncr_mutation();
CREATE TRIGGER trg_nonconformance_reports_truncate
    BEFORE TRUNCATE ON public.nonconformance_reports
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
