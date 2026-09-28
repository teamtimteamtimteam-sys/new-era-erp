-- db/tables/overtime_batches.sql
-- OVERTIME-1(2026-09-28):加班的月批次 —— 财务按月录、仓库一次批完。
--
-- 【一批 = 一个月】period_month 是当月 1 号;批里每一行的日期都落在这个月里(没有补发到后一个月,Tim Q8)。
-- 【状态】draft → submitted → approved · rejected(要备注,整批退回、改完再提)→ submitted …;
--   submitted → draft(财务撤回);approved → reversed(整批冲销,要理由,只在那个月考勤还开着时);
--   draft / rejected → discarded(不要了 —— 否则一张没人要的草稿会永远挡住那个月的考勤完成)。
-- 【"开着"的批】draft · submitted · rejected。一个月同一时刻只许一张开着的(部分唯一索引);
--   批过之后可以再开一张补充批(Tim Q6)。
-- 【审批开关不管它】(Tim Q5)仓库的人永远要按一次;approval_log 在开关关着时写一句说明。
-- 【没有 code 列】人读的名字是 label(OT 2026-10 #1),与各张申请表同形,不进 document_types。
-- 【没有写策略】只有 SELECT 策略:一切写都经 SECURITY DEFINER 函数(create / submit / withdraw /
--   decide / reverse / discard_overtime_batch)。直连 INSERT 被 RLS 拒;直连 UPDATE / DELETE 碰不到任何行。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE TABLE public.overtime_batches (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    label           text NOT NULL UNIQUE,
    period_month    date NOT NULL,
    seq             integer NOT NULL CHECK (seq > 0),
    status          text NOT NULL DEFAULT 'draft'
        CHECK (status IN ('draft', 'submitted', 'approved', 'rejected', 'reversed', 'discarded')),
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid,
    submitted_at    timestamptz,
    submitted_by    uuid,
    decided_at      timestamptz,
    decided_by      uuid,
    decision_notes  text,
    reversed_at     timestamptz,
    reversed_by     uuid,
    reverse_reason  text,
    discarded_at    timestamptz,
    discarded_by    uuid,
    UNIQUE (period_month, seq),
    CONSTRAINT overtime_batches_month_shape
        CHECK (period_month = date_trunc('month', period_month)::date),
    -- 交过的批一定有提交时刻(驳回的批也保留它那一次提交的时刻,所以这里是蕴含,不是等价)
    CONSTRAINT overtime_batches_submitted_shape
        CHECK (status NOT IN ('submitted', 'approved', 'reversed') OR submitted_at IS NOT NULL),
    CONSTRAINT overtime_batches_decided_shape
        CHECK ((status IN ('approved', 'rejected', 'reversed')) = (decided_at IS NOT NULL)),
    -- 驳回必须有备注(Tim Q10)
    CONSTRAINT overtime_batches_reject_note
        CHECK (status <> 'rejected' OR btrim(COALESCE(decision_notes, '')) <> ''),
    CONSTRAINT overtime_batches_reversed_shape
        CHECK ((status = 'reversed') = (reversed_at IS NOT NULL)
               AND (reversed_at IS NULL OR btrim(COALESCE(reverse_reason, '')) <> '')),
    CONSTRAINT overtime_batches_discarded_shape
        CHECK ((status = 'discarded') = (discarded_at IS NOT NULL))
);

COMMENT ON TABLE public.overtime_batches IS
    'OVERTIME-1:现场员工加班的月批次。财务(action.overtime_enter)按月录,仓库(action.overtime_approve)整批一次批或驳回(驳回要备注)。审批开关不管它;四眼:提交人不能批,批里任何一个员工(按人认)也不能批;R2 永远不覆盖加班。一个月同一时刻只许一张开着的批(draft / submitted / rejected),批过之后可以开补充批。批过的小时数在那个月考勤完成时冻进 attendance_lines 的三个桶,只算一次。那个月考勤完成之后,建、提交、批、冲销一律拒。OS 只报【小时】,不报钱(政策 7.1)。';

-- 一个月同一时刻只许一张开着的批 —— 函数先按名拒(OVERTIME_BATCH_OPEN_EXISTS),这里兜底。
CREATE UNIQUE INDEX overtime_batches_one_open_per_month
    ON public.overtime_batches (period_month) WHERE status IN ('draft', 'submitted', 'rejected');

ALTER TABLE public.overtime_batches ENABLE ROW LEVEL SECURITY;

-- 读:人力、录的人、批的人。仓库不持 module.hr.view,所以批的人要靠自己的码读得到。
CREATE POLICY "overtime_batches select by permission" ON public.overtime_batches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text)
        OR has_permission('action.overtime_enter'::text)
        OR has_permission('action.overtime_approve'::text));

REVOKE ALL ON public.overtime_batches FROM anon;
