-- db/tables/work_orders.sql
-- WO-1a:工单(生产计划)的表头。四态 draft/released/closed/cancelled —— "在做中"与"完成度"由挂上来的加工单推导,不存。
--
-- NOTE: introduced by db/migrations/2026-08-16-wo1a-work-order-document.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.work_orders (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,
    -- 【四态,而且每一态都是"有人做了一个动作"】见文件头决定一:
    -- 在做中 / 完成度不在这里,它们从挂上来的加工单推导。
    status         text NOT NULL DEFAULT 'draft'
                   CHECK (status IN ('draft','released','closed','cancelled')),
    -- 排产日:【可空,且永不默认】—— 见文件头决定二。
    scheduled_date date,
    notes          text,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid,
    -- 关闭三件套:未关闭之前全为 NULL,由 close_work_order 一次写齐。
    closed_at      timestamptz,
    closed_by      uuid,
    close_reason   text,
    -- 取消两件套(理由必填,与关闭同一条理由)
    cancelled_at   timestamptz,
    cancelled_by   uuid,
    cancel_reason  text,
    -- 【状态与它的证据必须同时成立】—— 一个 closed 却没有理由的行,读起来像
    -- "关了但没人说为什么",而真相多半是某条路径忘了写。用 CHECK 而不是靠
    -- 函数自觉:函数是唯一写入口【今天】成立,而约束对任何写入者都成立。
    CONSTRAINT work_orders_closed_consistent CHECK (
        (status = 'closed') = (closed_at IS NOT NULL)
        AND (closed_at IS NULL OR btrim(COALESCE(close_reason,'')) <> '')
    ),
    CONSTRAINT work_orders_cancelled_consistent CHECK (
        (status = 'cancelled') = (cancelled_at IS NOT NULL)
        AND (cancelled_at IS NULL OR btrim(COALESCE(cancel_reason,'')) <> '')
    )
);

COMMENT ON TABLE public.work_orders IS
    'WO-1a:工单 = 一份【打算加工什么、多少、什么时候】的计划。实绩在 processing_runs 那一侧,两者由 processing_runs.work_order_id 相连(该列 WO-1a 建出、WO-1b 才由 commit_processing_run 写入)。';
COMMENT ON COLUMN public.work_orders.status IS
    '四态,每一态都是一个【动作】的结果:draft(新建即此态)→ released(放行,可以开工)→ closed(收工,理由必填,短交合法);draft/released 均可 cancelled(理由必填)。【"在做中"与"完成度"不在这里】—— 它们由挂上来的加工单推导(一处推导,N 个消费者),存下来只会与真相漂开,而且要求有人记得去点一个按钮。';
COMMENT ON COLUMN public.work_orders.scheduled_date IS
    '打算什么时候做。【可空,且永不给默认值】—— 它与 process_date / issue_date 不是同一种日期:那些决定汇率与期间,补一个今天会让"留空"比"填对"更容易通过(FIN-10);这一个决定不了任何钱,而一份计划可以诚实地还不知道什么时候做。空的意思就是"没排" —— 补一个今天会把"谁也没排过期"伪装成"排在今天"。';
COMMENT ON COLUMN public.work_orders.close_reason IS
    '收工理由,【必填】。短交(实际做的比计划少)是合法的、要记下来的事实,不是要拦住的错误 —— 拦住它只会让人把计划改小以求关单,而那会把差异从账上抹掉。';

ALTER TABLE public.work_orders ENABLE ROW LEVEL SECURITY;

-- 读:module.processing.view。写:【一条 INSERT/UPDATE/DELETE 策略都不给】——
-- 唯一写入口是 create_/release_/close_/cancel_/amend_work_order 那五个
-- SECURITY DEFINER 函数(与 so_issues / cn_issues / approval_log 同一条:
-- 单据不该有第二个写法)。
CREATE POLICY "work_orders select by permission" ON public.work_orders
    AS PERMISSIVE FOR SELECT TO authenticated USING (has_permission('module.processing.view'::text));
