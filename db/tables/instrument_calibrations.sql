-- db/tables/instrument_calibrations.sql
-- MES-2(2026-10-06,规格 §8.2;MES-0 Q30 · Q31;MES-2 Step 0 Q23–Q25,Tim):【校准记录】—— "calibration records held in the system"。
--
-- 【一次校准 = 一行】哪一台仪器(秤、地磅、电表、在线仪表 —— Q23)、哪一天校的、证书自己写的有效期(必填,MES-0 Q31)、
--   通过还是没通过、证书号、校准机构。由持 action.manage_devices 的人记(Q24)。
-- 【在不在校准期内 —— 读的时候推】(Q25)对一个时刻 T(读数的那一天,新加坡日历):取这台仪器【没作废、calibrated_on ≤ T】
--   的最近一行(按 calibrated_on,再按 id —— id 是 identity,同一天记两次也排得出先后);通过且 T ≤ valid_until = 在期内;
--   通过而 T 已过期 = expired;没通过 = failed;一行都没有 = never_calibrated —— 也算不在期内。补录的证书对它覆盖的那段时间算数
--   (这一行本身进变更记录:谁、何时录的)。判据只有一份:calibration_status_from(结论, 有效期, T)。
-- 【只追加】记错了的作废(带理由),不改;不删(守卫)。【读】module.processing.view。进变更记录(设备那个审计主语的成员)。
--
-- NOTE: introduced by db/migrations/2026-10-06-mes2-confirmation-weighing-calibration.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.instrument_calibrations (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    device_id        uuid NOT NULL REFERENCES public.devices (id),
    calibrated_on    date NOT NULL,
    valid_until      date NOT NULL,
    result           text NOT NULL CHECK (result IN ('passed', 'failed')),
    certificate_no   text,
    calibrating_body text,
    notes            text,
    recorded_at      timestamptz NOT NULL DEFAULT now(),
    recorded_by      uuid DEFAULT auth.uid(),
    voided_at        timestamptz,
    voided_by        uuid,
    void_reason      text,
    CONSTRAINT instrument_calibrations_valid_after CHECK (valid_until >= calibrated_on),
    CONSTRAINT instrument_calibrations_voided_shape
        CHECK ((voided_at IS NULL) = (voided_by IS NULL)
               AND (voided_at IS NULL OR btrim(COALESCE(void_reason, '')) <> ''))
);

COMMENT ON TABLE public.instrument_calibrations IS
    'MES-2:校准记录(规格 §8.2)。仪器、校准日、证书有效期(必填)、通过 / 没通过、证书号、机构。某一刻在不在期内是读的时候推的:没作废、calibrated_on ≤ 那一天的最近一行,通过且没过期 = 在期内;一行都没有 = 不在期内。只追加:记错的作废(理由必填)。读:module.processing.view;写:action.manage_devices。';

CREATE INDEX instrument_calibrations_device ON public.instrument_calibrations (device_id, calibrated_on);

CREATE TRIGGER trg_instrument_calibrations_write
    BEFORE UPDATE ON public.instrument_calibrations
    FOR EACH ROW EXECUTE FUNCTION public.guard_instrument_calibrations_write();
CREATE TRIGGER trg_instrument_calibrations_no_delete
    BEFORE DELETE OR TRUNCATE ON public.instrument_calibrations
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_instrument_calibrations_write();

ALTER TABLE public.instrument_calibrations ENABLE ROW LEVEL SECURITY;

CREATE POLICY "instrument_calibrations select by permission" ON public.instrument_calibrations
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));

REVOKE ALL ON public.instrument_calibrations FROM anon;
