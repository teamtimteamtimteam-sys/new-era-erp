-- db/tables/training_records.sql
-- 培训与证书记录。
-- 安全类与合规类证书【会过期】—— expiry_date 驱动 hr_alerts 的到期提醒,
-- 合规切次还会读这张表做上岗资格检查(某工序要求持证)。
-- ON DELETE RESTRICT:员工是软删的,硬删会带走培训史,拦下。
--
-- NOTE: introduced by db/migrations/2026-08-01-hr1a-hr-core.sql.
-- First-run script (plain CREATEs). Run in the Supabase SQL Editor.

CREATE TABLE public.training_records (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    training_name   text NOT NULL,
    category        text CHECK (category IN ('induction','safety','compliance','cybersecurity','technical','leadership','other')),
    completed_date  date NOT NULL,
    expiry_date     date,
    provider        text,
    certificate_ref text,
    notes           text,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid()
);

CREATE INDEX idx_training_records_employee ON public.training_records (employee_id);
CREATE INDEX idx_training_records_expiry ON public.training_records (expiry_date) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_training_records_updated_at
    BEFORE UPDATE ON public.training_records
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.training_records ENABLE ROW LEVEL SECURITY;
CREATE POLICY "authenticated full access on training_records"
    ON public.training_records AS PERMISSIVE FOR ALL TO authenticated
    USING (true) WITH CHECK (true);
