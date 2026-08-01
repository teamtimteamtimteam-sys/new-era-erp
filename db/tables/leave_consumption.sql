-- db/tables/leave_consumption.sql
-- 假期账的【借方】,仅追加。draw / release 两种分录,取消申请写 release 而不是删行。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.leave_consumption (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    leave_request_id uuid NOT NULL REFERENCES public.leave_requests (id) ON DELETE RESTRICT,
    leave_grant_id   uuid NOT NULL REFERENCES public.leave_grants (id),
    entry_type       text NOT NULL DEFAULT 'draw' CHECK (entry_type IN ('draw','release')),
    days             numeric NOT NULL CHECK (days > 0),
    notes            text,
    created_at       timestamptz NOT NULL DEFAULT now(),
    created_by       uuid DEFAULT auth.uid()
);

CREATE INDEX idx_leave_consumption_request ON public.leave_consumption (leave_request_id);
CREATE INDEX idx_leave_consumption_grant ON public.leave_consumption (leave_grant_id);

CREATE OR REPLACE FUNCTION public.reject_leave_consumption_mutation()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    RAISE EXCEPTION 'LEAVE_CONSUMPTION_IMMUTABLE';
END;
$fn$;

CREATE TRIGGER trg_leave_consumption_immutable
    BEFORE UPDATE OR DELETE ON public.leave_consumption
    FOR EACH ROW EXECUTE FUNCTION public.reject_leave_consumption_mutation();

ALTER TABLE public.leave_consumption ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_consumption select by permission"
    ON public.leave_consumption AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "leave_consumption insert by permission"
    ON public.leave_consumption AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));

-- ============================================================================
