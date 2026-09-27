-- db/tables/gst_filing_requests.sql
-- ════════════════════════════════════════════════════════════════════════════
-- APR-10(2026-09-27):GST 申报申请 —— 财务提,CFO 批【报出去的那一组数】,批准之后财务才去 IRAS 报
-- ════════════════════════════════════════════════════════════════════════════
-- Tim 的矩阵(docs/role-matrix.md §2「GST 申报与更正 | 财务 | CFO」):不分档,批准之前什么都不生效。
-- ★【批的是数字,不是一条事后的记录】(grilling Q1)申报本身在 IRAS 网站上做;在那之后再批一条记录,
--   什么都控制不了。所以三步:
--     ① 财务提(submit_gst_filing_request):那一季 F5 每一格的数字【冻结】在本行 boxes 里;
--     ② CFO 批(decide_gst_filing_request):再算一遍,与冻结的那一组逐格相等才批 —— 批准把那一组抄进
--        gst_return_boxes(不可改、不可删的快照),期间 open → approved;
--     ③ 财务去 IRAS 报,回来一步记下申报日与参考号(record_gst_filing,不经批准:数字已经锁死了),
--        期间 approved → filed。
--   file_gst_return 从此只会按名拒(GST_FILING_NEEDS_APPROVED_REQUEST)。
--
-- 【生命周期】APR-9 处置的形状(grilling Q4)
--   submitted ──批准(写快照,期间 → approved)──▶ approved
--       ├──驳回(要理由)──────────────────────────▶ rejected
--       └──撤回──────────────────────────────────────▶ withdrawn
--   · 提:财务(module.finance.edit —— 申报原来的门)。前置条件与 file_gst_return 当年那一句相同:
--     那一季的每一个月都已关账(GST_PERIOD_NOT_LOCKED)。审批关着时【生下来就是 approved】,当场写快照,
--     留痕 auto_approved。
--   · 批:CFO(二级,不分档)。门 module.finance.view + data.view_prices(APR-7 / APR-9 同一对码)。
--     提单人永远不能批(按人认);提单人之外没人批得动 → 提交就拒 GST_FILING_NO_OTHER_DECIDER。
--   · 撤回:提单人本人(按人认),或持 module.finance.edit 的人。撤回不写 approval_log。
--
-- 【更正(F7)】(grilling Q2)开一份 F7 仍是一步(correct_gst_return,要理由);【报 F7】走同一张申请,
--   CFO 在屏幕上看见它与原件快照逐格的差。
--
-- 【在等的时候冻结什么】(grilling Q3)那一季的数字靠期间锁冻结 —— 前置条件就是那一季每个月都已关账。
--   所以在等的时候,把锁往回挪到这一季之内(reopen_period、重开年度、手动锁)按名拒
--   GST_FILING_WAITING_BLOCKS_REOPEN(guard_gst_filing_lock,挂在 finance_settings 上)。
--   批准时再判一次锁(GST_PERIOD_NOT_LOCKED)、再算一遍 F5 与 boxes 比(GST_RETURN_CHANGED_SINCE_REQUEST)——
--   锁里仍然许可的路(APR-7 的已锁期间回滚之类)若动了数字,批准就拒,申请仍在等。
--
-- 【没有金额】approval_log 的四列留空(terms_request 同形):批的是一组申报数,不是一笔钱;box 8 可以是负的(退税)。
--
-- NOTE: introduced by db/migrations/2026-09-27-apr10-gst-filing-and-po-categories.sql.

CREATE TABLE public.gst_filing_requests (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    status             text NOT NULL DEFAULT 'submitted'
        CHECK (status IN ('submitted', 'approved', 'rejected', 'withdrawn')),
    label              text NOT NULL,
    period_id          uuid NOT NULL REFERENCES public.gst_periods (id) ON DELETE RESTRICT,
    -- ── 冻结的那一组 ─────────────────────────────────────────────────────────
    -- 提交那一刻 f5_return(period_start, period_end)->'boxes' 原样:每一格 {box, label_en, label_zh, value}。
    -- 它同时是 fingerprint:批准时再算一遍,逐字相等才批。
    boxes              jsonb NOT NULL,
    -- 提单人的附言(可空)
    note               text,
    -- ── 决定 ─────────────────────────────────────────────────────────────────
    decided_at         timestamptz,
    decided_by         uuid,
    decision_notes     text,
    -- 批准当场写快照的时刻
    executed_at        timestamptz,
    -- ── 撤回 ─────────────────────────────────────────────────────────────────
    withdrawn_at       timestamptz,
    withdrawn_by       uuid,
    withdraw_reason    text,
    created_at         timestamptz NOT NULL DEFAULT now(),
    created_by         uuid NOT NULL,
    CONSTRAINT gst_filing_requests_boxes_shape CHECK (jsonb_typeof(boxes) = 'array'),
    CONSTRAINT gst_filing_requests_decision_shape CHECK ((decided_at IS NULL) = (decided_by IS NULL)),
    CONSTRAINT gst_filing_requests_reject_reason CHECK (
        status <> 'rejected' OR (decided_at IS NOT NULL AND btrim(COALESCE(decision_notes, '')) <> '')),
    CONSTRAINT gst_filing_requests_approved_shape CHECK ((status = 'approved') = (executed_at IS NOT NULL)),
    CONSTRAINT gst_filing_requests_withdraw_shape CHECK (
        (status = 'withdrawn') = (withdrawn_at IS NOT NULL)
        AND (withdrawn_at IS NULL) = (withdrawn_by IS NULL))
);

COMMENT ON TABLE public.gst_filing_requests IS
    'APR-10:GST 申报申请 —— 财务提(module.finance.edit),CFO 批每一张,不分档。批的是【报出去之前的那一组数】:提交冻结 F5 每一格(boxes,同时是 fingerprint);批准时再算一遍、逐字相等才把它抄进 gst_return_boxes,期间 open → approved;之后财务去 IRAS 报、用 record_gst_filing 一步记下申报日与参考号(approved → filed)。submitted → approved · rejected(要理由)· withdrawn(提单人本人或 module.finance.edit)。审批关着时生下来就是 approved(auto_approved)。在等的时候把锁挪回这一季按名拒 GST_FILING_WAITING_BLOCKS_REOPEN。一个期间同一时刻只挂一张在等的申请。file_gst_return 只会按名拒 GST_FILING_NEEDS_APPROVED_REQUEST。';

COMMENT ON COLUMN public.gst_filing_requests.boxes IS
    'APR-10(grilling Q1):提交那一刻 f5_return(那一季)->''boxes'' 原样。批准时再算一遍、与它逐字相等才批(GST_RETURN_CHANGED_SINCE_REQUEST);批准把它抄进 gst_return_boxes。';

CREATE UNIQUE INDEX gst_filing_requests_one_open
    ON public.gst_filing_requests (period_id) WHERE status = 'submitted';
CREATE INDEX gst_filing_requests_period_id_rel ON public.gst_filing_requests (period_id);

ALTER TABLE public.gst_filing_requests ENABLE ROW LEVEL SECURITY;

-- 读:GST 页那一个码(module.finance.view)。写:一条策略都不给 —— 只经 submit / decide / withdraw
-- (全是 SECURITY DEFINER)。屏幕读 gst_filing_requests_visible()。
CREATE POLICY "gst_filing_requests select by permission" ON public.gst_filing_requests
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text));

-- anon 什么都不给(check-anon-grant-decision:每一张新表都要【说出】它对 anon 的决定)。
REVOKE ALL ON public.gst_filing_requests FROM anon;
