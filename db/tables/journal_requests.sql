-- db/tables/journal_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-6(2026-09-25):手工凭证与它的冲销 —— 财务提,CFO 批每一张,批准当场过账
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md「手工凭证与冲销 | 财务 | CFO」,[LC] APR-6)与 N5:只有【人敲的】凭证要批;
-- 系统生成的(月结、外币重估、折旧、年结,以及每一张单据自己的函数过的账)一律不经这里 —— 审批永远不许卡住月结。
--
-- 【人敲的与系统过的,界线划在权限上,不划在 source_type 这个标签上】(APR-6 grilling Q1)
--   线上 30 支过账函数全是 SECURITY DEFINER、属主 postgres;只有 post_journal_entry 本身是 INVOKER、authenticated
--   可执行,而它收调用方给的任意 source_type。APR-6 把它的 EXECUTE 从 authenticated 收回、拿掉两张分录表的写策略
--   (直连写按名拒 JOURNAL_THROUGH_FUNCTION_ONLY)—— 于是人手里只剩这一扇门:submit_journal_request,
--   过出来的永远是 'manual'。
--
-- 【生命周期】
--   submitted ──批准(当场过账)──▶ approved
--       ├──驳回(要理由)──────────▶ rejected
--       └──撤回───────────────────▶ withdrawn
--   · 提:财务(module.finance.edit —— 矩阵「做:= 不变」)。两种:
--       entry     submit_journal_request(凭证日, 摘要, 行)           —— 与旧的 post_journal_entry 同一组行
--       reversal  submit_journal_reversal_request(分录, 冲销日, 理由) —— 冲一张【没有自己冲销路径】的分录
--                 (手工凭证,以及 sale · stocktake · writeoff · prepayment · revaluation · depreciation ·
--                  asset_disposal · shipment · 工资付款分录;Q6 (i)(iii))。有自己路径的按名拒
--                 JE_REVERSE_USE_SOURCE_PATH(journal_entry_reversal_route 一份判据)。
--     审批关着时【生下来就是 approved】并当场过账,留痕写 auto_approved(PAY-REQ-1 的 Q8 同形)。
--   · 批:CFO(二级,不分档)。门 module.finance.view + data.view_prices(与付款、贷项申请同一对码:
--     edit 是提单的码;批的人必须看得见他批的那个数)。提单人永远不能批(forbid_self_approval,按人认)。
--   · 撤回:提单人本人(按人认),或任何持 module.finance.edit 的人。撤回写在本行上,【不】写 approval_log。
--
-- 【冻结的是什么】提交时给的那一组,原样:凭证日 / 冲销日(entry_date)、摘要(memo)、行(lines,entry 才有)、
--   冲哪一张(target_entry_id,reversal 才有)与理由。批准时按它们过账,日期就是提单人填的那一天。
--   期间在等待中被锁上 → 锁【永远赢、从不被拒】(Q4:审批不许卡住月结);批准时的过账按引擎原话拒
--   (PERIOD_LOCKED · YEAR_CLOSED),整笔回滚,申请仍在等 —— CFO 驳回,或财务撤回、换一个开着的日子再提。
--
-- 【金额】amount_base 本位币 = 那张分录的借方合计(N1 对 journal_entries 退休,Q2:不分档,没有档可越;
--   CFO 与留痕看到的数由试跑算出)。提交时由试跑写入,批准后改写成实际过账的那一个。
-- 【credits_bank】过出来的分录贷了一个 is_cash 科目(1000 / 1010 …)—— CFO 那一块按它亮一句
--   「贷银行账户」(Q7:银行科目准许,但要经批准,而且要说出来)。1100 / 2000 在试跑里就按名拒
--   (JE_MANUAL_CONTROL_ACCOUNT)—— 它们有自己的单据,手敲一行会让清单与总账各说各话。
--
-- 【过出来的分录指回申请】entry:post_journal_entry(…, 'manual', 本申请的 id, …)—— source_id = 申请(Q3)。
--   reversal:reverse_journal_entry_internal 照旧抄原分录的 source_type、source_id 指原分录;申请经
--   result_journal_entry_id 指着它。职责分离那条规矩(sod_manual_posters_in)经 result_journal_entry_id
--   找回【提单人】—— 批准的 CFO 不是"记手工凭证的人"(Q5)。
--
-- 【一张分录同时只挂一张在等的冲销申请】(journal_requests_one_open_reversal;函数里先按名拒
--   JOURNAL_REQUEST_OPEN,唯一索引是第二道)。
--
-- 【没有自己的单据编号】label = 'manual journal #n' / '<分录编号> · reversal #n',给留痕与屏幕读;
--   不进 document_types(与 invoice_requests 同一条理由)。
--
-- NOTE: introduced by db/migrations/2026-09-25-apr6-manual-journals-wait-for-the-cfo.sql.

CREATE TABLE public.journal_requests (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    kind                    text NOT NULL CHECK (kind IN ('entry', 'reversal')),
    status                  text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label                   text NOT NULL,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    -- entry:凭证日;reversal:冲销日(提交时就定下,决定落进哪个期间)
    entry_date              date NOT NULL,
    -- entry:摘要(必填);reversal:冲销的理由(必填,写进冲销分录的摘要)
    memo                    text NOT NULL CHECK (btrim(memo) <> ''),
    -- entry 的行,原样(post_journal_entry 的 p_lines);reversal 为 NULL
    lines                   jsonb,
    -- reversal 冲的那一张;entry 为 NULL
    target_entry_id         uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    -- 本位币,最近一次估算(提交时试跑;批准后 = 实际过账额)
    amount_base             numeric NOT NULL CHECK (amount_base >= 0),
    -- 过出来的分录贷了现金 / 银行科目(试跑读出,批准时重读)
    credits_bank            boolean NOT NULL DEFAULT false,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at              timestamptz,
    decided_by              uuid,
    decision_notes          text,
    -- 批准当场过账:过出来的那一张分录
    result_journal_entry_id uuid REFERENCES public.journal_entries (id) ON DELETE RESTRICT,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at            timestamptz,
    withdrawn_by            uuid,
    withdraw_reason         text,
    created_at              timestamptz NOT NULL DEFAULT now(),
    created_by              uuid NOT NULL,
    CONSTRAINT journal_requests_kind_shape CHECK (
        (kind = 'entry') = (lines IS NOT NULL)
        AND (kind = 'reversal') = (target_entry_id IS NOT NULL)),
    CONSTRAINT journal_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT journal_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT journal_requests_approved_shape CHECK (
        (status = 'approved') = (result_journal_entry_id IS NOT NULL)),
    CONSTRAINT journal_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.journal_requests IS
    'APR-6:手工凭证与冲销的申请(Tim 的矩阵:财务提,CFO 批每一张,不分档;批准当场过账)。entry = 一张手工凭证(过出来永远是 manual,source_id = 本申请);reversal = 冲一张没有自己冲销路径的分录。submitted → approved(CFO,当场按冻结的日期过账)· rejected(要理由)· withdrawn(提单人本人或 module.finance.edit)。审批关着时生下来就是 approved 并当场过账(auto_approved)。1100 / 2000 按名拒(JE_MANUAL_CONTROL_ACCOUNT);贷银行科目准许并标 credits_bank。';

COMMENT ON COLUMN public.journal_requests.amount_base IS
    'APR-6:本位币 = 过出来那张分录的借方合计。提交时由试跑算出(写进 submitted 留痕);批准后改写成实际过账的那一个(写进 approved 留痕)。N1 对 journal_entries 退休(grilling Q2):不分档,没有档可越。';

COMMENT ON COLUMN public.journal_requests.credits_bank IS
    'APR-6(grilling Q7):过出来的分录贷了一个 is_cash 科目。银行科目准许手工凭证,但要经 CFO 批准,而且 CFO 那一块要把这句说出来。';

CREATE UNIQUE INDEX journal_requests_one_open_reversal
    ON public.journal_requests (target_entry_id)
    WHERE status = 'submitted' AND kind = 'reversal';
CREATE INDEX journal_requests_target_entry_id_rel ON public.journal_requests (target_entry_id);
CREATE INDEX journal_requests_result_journal_entry_id_rel ON public.journal_requests (result_journal_entry_id);

ALTER TABLE public.journal_requests ENABLE ROW LEVEL SECURITY;

-- 读:凭证页的门(module.finance.view —— AGENTS.md 常设决定 1:它蕴含看得见价格)。写:一条策略都不给 ——
-- 只经 submit_journal_request · submit_journal_reversal_request · decide_journal_request ·
-- withdraw_journal_request(全是 SECURITY DEFINER)。
CREATE POLICY "journal_requests select by permission" ON public.journal_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.journal_requests FROM anon;
