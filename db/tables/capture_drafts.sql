-- db/tables/capture_drafts.sql
-- MES-2(2026-10-06,规格 §6.3;MES-0 §3.6 · Q10–Q13;MES-2 Step 0 Q4 · Q8 · Q10,Tim):【草稿】—— 网关送来的数据先成为一张草稿,
--   工位上的人确认之后才成为正式记录(规格 §6.3:"Automatic direct posting is not used")。
--
-- 【一行收件箱 → 一张草稿】(Q4)分派器(ingest_transform_row)在把收件箱一行标成 transformed 的同一个子事务里,
--   为 creates_draft 为真的那几类(MES-2:weighing)落一张草稿;proposed = 转换器的输出,原样。inbox_id 唯一。
--   转换器是 IMMUTABLE、只吃 payload(MES-1 的决定 7),所以它落不了草稿 —— 分派器落。
-- 【决定】pending → confirmed(confirm_capture_draft,写出正式记录 weighings,改过的值各一行 capture_draft_changes)
--   或 rejected(reject_capture_draft,理由必填,终局 —— Q10)。决定只做一次,之后冻住(守卫)。草稿永不过期(MES-0 Q13),
--   提醒臂 capture_draft_pending 按年龄列出来。
-- 【手工录入】(MES-0 Q10)同一条路:收件箱一行(source = manual)→ 同一支转换器 → 草稿 → 同一步里由录入人确认。
--   于是手工的草稿生下来就是 confirmed;一张 pending 的草稿只可能来自网关。
-- 【读】module.processing.view(MES-0 §3.10);【写】只经函数,没有写策略。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.capture_drafts (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbox_id      bigint NOT NULL UNIQUE REFERENCES public.ingest_inbox (id),
    data_class    text NOT NULL REFERENCES public.ingest_data_classes (code),
    source        text NOT NULL CHECK (source IN ('device', 'manual')),
    device_id     uuid REFERENCES public.devices (id),
    station       text,
    proposed      jsonb NOT NULL,
    status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'confirmed', 'rejected')),
    created_at    timestamptz NOT NULL DEFAULT now(),
    confirmed_at  timestamptz,
    confirmed_by  uuid,
    rejected_at   timestamptz,
    rejected_by   uuid,
    reject_reason text,
    CONSTRAINT capture_drafts_confirmed_shape
        CHECK ((status = 'confirmed') = (confirmed_at IS NOT NULL AND confirmed_by IS NOT NULL)),
    CONSTRAINT capture_drafts_rejected_shape
        CHECK ((status = 'rejected') = (rejected_at IS NOT NULL AND rejected_by IS NOT NULL
                                        AND btrim(COALESCE(reject_reason, '')) <> ''))
);

COMMENT ON TABLE public.capture_drafts IS
    'MES-2:草稿(规格 §6.3)。分派器为 creates_draft 的数据类(weighing)每一行 transformed 的收件箱落一张,proposed = 转换器输出。pending → confirmed(写出 weighings,改过的值记在 capture_draft_changes)或 rejected(理由必填,终局)。只决定一次;永不过期、永不删。手工录入在同一步里由录入人确认。读:module.processing.view;写只经函数。';

CREATE INDEX capture_drafts_status ON public.capture_drafts (status, created_at);
CREATE INDEX capture_drafts_device ON public.capture_drafts (device_id);

CREATE TRIGGER trg_capture_drafts_write
    BEFORE UPDATE ON public.capture_drafts
    FOR EACH ROW EXECUTE FUNCTION public.guard_capture_drafts_write();
CREATE TRIGGER trg_capture_drafts_no_delete
    BEFORE DELETE OR TRUNCATE ON public.capture_drafts
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_capture_drafts_write();

ALTER TABLE public.capture_drafts ENABLE ROW LEVEL SECURITY;

CREATE POLICY "capture_drafts select by permission" ON public.capture_drafts
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.capture_drafts FROM anon;
