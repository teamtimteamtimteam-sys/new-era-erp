-- db/tables/medical_claims.sql
-- 医疗报销。批准时【不自动记费用】—— 付款路径待定,见 expense_id 一列。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.medical_claims (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,
    employee_id    uuid NOT NULL REFERENCES public.employees (id),
    claim_date     date NOT NULL,
    claim_year     integer NOT NULL,
    amount_sgd     numeric NOT NULL CHECK (amount_sgd > 0),
    description    text,
    receipt_ref    text,
    status         text NOT NULL DEFAULT 'submitted'
                   CHECK (status IN ('submitted','approved','rejected','paid')),
    decided_at     timestamptz,
    decided_by     uuid,
    decision_notes text,
    -- 【付款方式是 Tim 的运营决定】:走薪资代发,还是单独付款并入账为费用。
    -- 本切【不自动过账】—— 这一列留着,等他定了再把两边挂上。
    expense_id     uuid REFERENCES public.expenses (id),
    deleted_at     timestamptz,
    created_at     timestamptz NOT NULL DEFAULT now(),
    created_by     uuid DEFAULT auth.uid(),
    updated_at     timestamptz NOT NULL DEFAULT now(),
    updated_by     uuid DEFAULT auth.uid()
);

CREATE INDEX idx_medical_claims_employee ON public.medical_claims (employee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_medical_claims_year ON public.medical_claims (claim_year);

CREATE TRIGGER trg_medical_claims_updated_at
    BEFORE UPDATE ON public.medical_claims
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.medical_claims ENABLE ROW LEVEL SECURITY;
CREATE POLICY "medical_claims select by permission"
    ON public.medical_claims AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "medical_claims select own rows"
    ON public.medical_claims AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "medical_claims insert by permission"
    ON public.medical_claims AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "medical_claims update by permission"
    ON public.medical_claims AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "medical_claims delete by permission"
    ON public.medical_claims AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ============================================================================
