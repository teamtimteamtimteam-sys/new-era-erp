-- db/tables/leave_requests.sql
-- 请假申请。days 由 submit_leave_request 算出,不采信调用方传入。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.leave_requests (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code            text NOT NULL UNIQUE,
    employee_id     uuid NOT NULL REFERENCES public.employees (id),
    leave_type_code text NOT NULL REFERENCES public.leave_types (code),
    start_date      date NOT NULL,
    end_date        date NOT NULL,
    start_half_day  boolean NOT NULL DEFAULT false,
    end_half_day    boolean NOT NULL DEFAULT false,
    -- days 由 submit_leave_request 用 calculate_leave_days 算出,【不采信调用方传入的值】
    days            numeric NOT NULL CHECK (days > 0),
    reason          text,
    certificate_ref text,
    status          text NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','approved','rejected','cancelled')),
    decided_at      timestamptz,
    decided_by      uuid,
    decision_notes  text,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid(),
    -- cut 2b 例外路径。【ALTER 加的列留在末尾】,与线上 attnum 顺序一致(见 AGENTS.md)。
    -- days 由 HR 手填而非 calculate_leave_days 算出,两种情形:
    -- 六天制/轮班下周一至周五口径不对;以及逐案变通标准天数(恩恤/婚假)。
    is_exception    boolean NOT NULL DEFAULT false,
    exception_reason text,
    CONSTRAINT leave_requests_date_order CHECK (end_date >= start_date),
    -- 没有理由的例外,三个月后没人知道当时为什么这么批
    CONSTRAINT leave_requests_exception_reason
        CHECK (NOT is_exception OR (exception_reason IS NOT NULL AND btrim(exception_reason) <> ''))
);

CREATE INDEX idx_leave_requests_employee ON public.leave_requests (employee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_leave_requests_status ON public.leave_requests (status);
CREATE INDEX idx_leave_requests_start ON public.leave_requests (start_date);

CREATE TRIGGER trg_leave_requests_updated_at
    BEFORE UPDATE ON public.leave_requests
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.leave_requests ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_requests select by permission"
    ON public.leave_requests AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
-- 自助:自己的申请自己看得见(权限 cut 4 的行级模式)
CREATE POLICY "leave_requests select own rows"
    ON public.leave_requests AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "leave_requests insert by permission"
    ON public.leave_requests AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_requests update by permission"
    ON public.leave_requests AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_requests delete by permission"
    ON public.leave_requests AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ============================================================================

-- 列注释:说明写在数据库里,重建出来的库也带着它们(OPS-1 补齐)。
COMMENT ON COLUMN public.leave_requests.is_exception IS
    'True when days were entered by hand rather than computed from calculate_leave_days. Two cases: (a) a six-day or shift schedule where Mon-Fri counting is wrong, (b) case-by-case leave (compassionate, marriage) varying the standard entitlement.';
