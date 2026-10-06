-- db/tables/weighings.sql
-- MES-2(2026-10-06,规格 §3.2 · §6.3 · §8.2;MES-0 §3.9 · Q12;MES-2 Step 0 Q7 · Q9 · Q11 · Q14 · Q22,Tim):【称重 —— 正式记录】。
--
-- 【怎么来的】一张确认了的草稿(网关送来的,或手工录入在同一步里确认的)。inbox_id 与 draft_id 各唯一,
--   于是一条称重一跳回到它的收件箱那一行(网关、流、序号、原始 payload)与它的草稿(改过什么、谁确认的)。
-- 【读数】weight_kg(> 0)—— 确认时的值;转换器给的原值若被改过,原值与理由在 capture_draft_changes 里。
-- 【仪器】device_id = 读数来自哪一台秤 / 地磅;为空 = 没有记录仪器("instrument not recorded",Q14:手工录入可以不选,
--   标出来,不拒)。校准状态在读数的那一刻是否有效,从 instrument_calibrations 读的时候推(Q25,视图 weighing_calibration)。
-- 【主语】ticket_id + role:挂在一张地磅单上的是毛重或皮重(gross / tare);不挂单的是一次单独的净重(net)。
--   称重挂到批次与加工的进出料是 MES-4a 的事(MES-0 Q22)。
-- 【现场指针】site_from · site_to · site_dataset_ref(规格 §2.1:原始数据留在现场,ERP 只存指针);captured_at = 读数的时刻
--   (现场时间,没有就取确认时刻)—— 校准判据看的正是它。
-- 【只追加】(规格 §4.2)更正是一条新行:corrects_id 指回被更正的那一行、correction_reason 必填(Q11);读的人取【没有被更正过】
--   的那一行。每一行最多被更正一次(corrects_id 唯一),所以"最新"是一条链的末端,不靠时间戳排序。
-- 【读】module.processing.view 或 module.inbound.view 或 module.logistics.view(Q22:地磅单页上要看得见两磅)。进变更记录。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.weighings (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    inbox_id          bigint NOT NULL UNIQUE REFERENCES public.ingest_inbox (id),
    draft_id          uuid NOT NULL UNIQUE REFERENCES public.capture_drafts (id),
    device_id         uuid REFERENCES public.devices (id),
    source            text NOT NULL CHECK (source IN ('device', 'manual')),
    weight_kg         numeric NOT NULL CHECK (weight_kg > 0),
    role              text NOT NULL CHECK (role IN ('gross', 'tare', 'net')),
    ticket_id         uuid REFERENCES public.weighbridge_tickets (id),
    site_from         timestamptz,
    site_to           timestamptz,
    site_dataset_ref  text,
    captured_at       timestamptz NOT NULL,
    confirmed_at      timestamptz NOT NULL DEFAULT now(),
    confirmed_by      uuid NOT NULL,
    corrects_id       uuid UNIQUE REFERENCES public.weighings (id),
    correction_reason text,
    CONSTRAINT weighings_subject_shape
        CHECK ((ticket_id IS NULL AND role = 'net') OR (ticket_id IS NOT NULL AND role IN ('gross', 'tare'))),
    CONSTRAINT weighings_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> '')),
    CONSTRAINT weighings_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to)
);

COMMENT ON TABLE public.weighings IS
    'MES-2:称重的正式记录(一张确认了的草稿)。weight_kg;device_id 为空 = 没有记录仪器;挂在地磅单上的是毛重 / 皮重,不挂的是净重。现场指针 site_*;captured_at 是读数时刻(校准判据看它)。只追加:更正是新行(corrects_id + 必填理由),读最新的。读:加工 / 收货 / 物流的查看码任一。';

CREATE INDEX weighings_ticket ON public.weighings (ticket_id);
CREATE INDEX weighings_device ON public.weighings (device_id);

CREATE TRIGGER trg_weighings_append_only
    BEFORE UPDATE ON public.weighings
    FOR EACH ROW EXECUTE FUNCTION public.guard_capture_append_only();
CREATE TRIGGER trg_weighings_no_delete
    BEFORE DELETE OR TRUNCATE ON public.weighings
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_capture_append_only();

ALTER TABLE public.weighings ENABLE ROW LEVEL SECURITY;

CREATE POLICY "weighings select by permission" ON public.weighings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((has_permission('module.processing.view'::text) OR has_permission('module.inbound.view'::text)
            OR has_permission('module.logistics.view'::text)));

REVOKE ALL ON public.weighings FROM anon;
