-- db/tables/meter_readings.sql
-- MES-5a-2(2026-10-08,规格 §9 "Energy and run time";MES-0 §3.2 · D4 · Q27;MES-5a Step 0 Q19 · Q20,Tim):
--   【一台电表的累计寄存器读数】—— 某一刻表上显示的 kWh(不是那一段用了多少)。只追加。
--   【哪一台表】device_id 必须是一台 kind = 'meter' 的设备;它属于哪台机器 = 那台设备的 equipment_id,为空 = 共用池(Q19)。
--     机器在设备页上由 action.manage_devices 设(save_device —— MES-1 就有那一格;本刀不加列)。
--   【一段用了多少】从这里推出来,不存:同一台表、同一段时间里【当前】读数两两相邻之差的和(electricity_allocation_compute)。
--   【比上一条小的拒】(Q20)同一台表上,按读数时刻排,比它前面那一条当前读数小 → METER_READING_BELOW_PREVIOUS;
--     比它后面那一条大(而后面那一条不是寄存器清零)→ METER_READING_ABOVE_NEXT。只有标成【寄存器清零】(is_register_reset,
--     理由必填)的那一条可以比前一条小 —— 它是一条新的起点:跨过它的那一段用量【量不出来】,不计(本刀的决定,见交回)。
--   【更正】新行指回原行(corrects_id 唯一)+ 必填理由;withdrawn = 撤回这一条(记在了错的表上)。当前 = 没被更正、没被撤回。
--   【来源】source = manual(手工,action.confirm_capture,在设备页上)| device(设备转换器 —— 本刀【没有建】:没有任何电表给过
--     数据格式,MES-3b Q25 · MES-4a Q14;meter_reading 这一类的 transform 仍为空,设备来的消息停在 awaiting_transform)。
--     收件箱 / 草稿 / 现场数据指针几列已经在,所以将来接上转换器不必改表。
--   【不规定读数频率】(Q20)一段时间里少于两条读数,那台表那一段就是"量不出来",不是零。
--   只经 record_meter_reading / correct_meter_reading 写;UPDATE / DELETE / TRUNCATE 语句级拒。
--
-- NOTE: introduced by db/migrations/2026-10-08-mes5a2-energy.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.meter_readings (
    id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id          uuid NOT NULL REFERENCES public.devices (id),
    read_at            timestamptz NOT NULL,
    register_kwh       numeric NOT NULL CHECK (register_kwh >= 0),
    is_register_reset  boolean NOT NULL DEFAULT false,
    reset_reason       text,
    withdrawn          boolean NOT NULL DEFAULT false,
    source             text NOT NULL DEFAULT 'manual' CHECK (source IN ('manual', 'device')),
    inbox_id           bigint REFERENCES public.ingest_inbox (id),
    draft_id           uuid REFERENCES public.capture_drafts (id),
    site_from          timestamptz,
    site_to            timestamptz,
    site_dataset_ref   text,
    notes              text,
    recorded_at        timestamptz NOT NULL DEFAULT now(),
    recorded_by        uuid DEFAULT auth.uid(),
    corrects_id        bigint UNIQUE REFERENCES public.meter_readings (id),
    correction_reason  text,
    CONSTRAINT meter_readings_reset_shape
        CHECK ((NOT is_register_reset AND reset_reason IS NULL)
               OR (is_register_reset AND reset_reason IS NOT NULL AND btrim(reset_reason) <> '')),
    CONSTRAINT meter_readings_withdrawn_is_correction CHECK (NOT withdrawn OR corrects_id IS NOT NULL),
    CONSTRAINT meter_readings_correction_shape
        CHECK ((corrects_id IS NULL) = (correction_reason IS NULL)
               AND (correction_reason IS NULL OR btrim(correction_reason) <> '')),
    CONSTRAINT meter_readings_site_range
        CHECK (site_from IS NULL OR site_to IS NULL OR site_from <= site_to)
);

COMMENT ON TABLE public.meter_readings IS
    'MES-5a-2:电表的累计寄存器读数(kWh,某一刻表上显示的数),只追加。用量从相邻两条当前读数之差推出来,不存。比前一条小的拒,除非标成寄存器清零并写理由;跨过清零的那一段量不出来,不计。更正 = 新行(corrects_id + 理由),撤回 = 一条 withdrawn 的更正。手工录入要 action.confirm_capture;设备转换器没有建(没有电表给过格式)。';

CREATE INDEX meter_readings_device_read_at ON public.meter_readings (device_id, read_at);
CREATE INDEX meter_readings_inbox_id_rel ON public.meter_readings (inbox_id);
CREATE INDEX meter_readings_draft_id_rel ON public.meter_readings (draft_id);

CREATE TRIGGER trg_meter_readings_append_only
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.meter_readings
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.meter_readings ENABLE ROW LEVEL SECURITY;
-- 读:设备页的读者(加工查看码),以及电费分摊页的读者(财务查看码)。kWh 不遮(Q30)。写只经函数。
CREATE POLICY "meter_readings select by permission" ON public.meter_readings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_any_permission(ARRAY['module.processing.view'::text, 'module.finance.view'::text]));
GRANT SELECT ON public.meter_readings TO authenticated;
REVOKE ALL ON public.meter_readings FROM anon;
