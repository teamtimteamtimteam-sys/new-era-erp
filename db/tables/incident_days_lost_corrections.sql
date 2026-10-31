-- db/tables/incident_days_lost_corrections.sql
-- ESG-2(Tim 2026-10-31 Q7):【误工天数的更正】—— 误工天数是健康数据(data.view_health,或受伤的那名员工本人),所以它的更正不能住在
--   incident_updates 里(那张表的 new_value 对每一个持 module.safety.view 的人都可读)。一行 = 一次带理由的更正;最后一行说了算(id 是 identity)。
--   【谁写】持 module.safety.edit 的人(与记下这件事故、记下原来那个数的是同一批人),经 record_incident_days_lost_correction:
--     只在有受伤的人的事故上;理由必填;与现在的值相同按名拒。
--   【谁读】持 data.view_health 的人,或受伤的那名员工本人 —— 与 incidents_masked 里 days_lost 那句 CASE 同一个判据。
--   【现在的值】incident_rows.days_lost = 最后一次更正,没有更正就是原来那个数(遮蔽照旧);安全率页按同一个值算误工天数与误工事故。
--   不改、不删。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.incident_days_lost_corrections (
    id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    incident_id  uuid NOT NULL REFERENCES public.incidents (id),
    days_lost    numeric NOT NULL CHECK (days_lost >= 0),
    reason       text NOT NULL CHECK (length(btrim(reason)) BETWEEN 1 AND 2000),
    recorded_at  timestamptz NOT NULL DEFAULT now(),
    recorded_by  uuid DEFAULT auth.uid()
);
CREATE INDEX incident_days_lost_corrections_incident_id_rel ON public.incident_days_lost_corrections (incident_id, id);
COMMENT ON TABLE public.incident_days_lost_corrections IS
    'ESG-2(Q7):一件事故误工天数的更正(带理由,最后一次说了算)。健康数据:读要 data.view_health 或就是受伤的那名员工本人。写只经 record_incident_days_lost_correction(module.safety.edit)。不改、不删。';
CREATE OR REPLACE FUNCTION public.guard_incident_days_lost_correction_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'INCIDENT_IMMUTABLE';
END;
$function$;
CREATE TRIGGER trg_incident_days_lost_corrections_immutable
    BEFORE UPDATE OR DELETE ON public.incident_days_lost_corrections
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_incident_days_lost_correction_write();
CREATE TRIGGER trg_incident_days_lost_corrections_truncate
    BEFORE TRUNCATE ON public.incident_days_lost_corrections
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
ALTER TABLE public.incident_days_lost_corrections ENABLE ROW LEVEL SECURITY;
CREATE POLICY "incident_days_lost_corrections select by health or self" ON public.incident_days_lost_corrections
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('data.view_health'::text))
        OR incident_injured_is_caller(incident_id));
REVOKE ALL ON public.incident_days_lost_corrections FROM authenticated, anon;
GRANT SELECT ON public.incident_days_lost_corrections TO authenticated;
