-- db/tables/leave_grants.sql
-- 假期账的【贷方】。expires_on 驱动"先用旧的"消耗顺序。
--
-- NOTE: introduced by db/migrations/2026-08-02-hr2a-leave-and-claims.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.leave_grants (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    employee_id     uuid NOT NULL REFERENCES public.employees (id),
    leave_type_code text NOT NULL REFERENCES public.leave_types (code),
    leave_year      integer NOT NULL,
    days            numeric NOT NULL CHECK (days > 0),
    granted_on      date NOT NULL,
    -- 【expires_on 是"先用旧的"的依据】。当年度的 entitlement 授予到【次年年底】失效,
    -- 这就是那条"结转后 12 个月失效"的规则落在数据上的样子。
    -- null = 永不失效(目前没有这样的授予,留给日后)。
    expires_on      date,
    grant_type      text NOT NULL CHECK (grant_type IN ('entitlement','carry_forward','adjustment','pro_rata')),
    -- 结转授予指向它的来源,于是"这 19 天是从哪来的"查得到
    source_grant_id uuid REFERENCES public.leave_grants (id),
    notes           text,
    deleted_at      timestamptz,
    created_at      timestamptz NOT NULL DEFAULT now(),
    created_by      uuid DEFAULT auth.uid(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    updated_by      uuid DEFAULT auth.uid()
);

CREATE INDEX idx_leave_grants_employee ON public.leave_grants (employee_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_leave_grants_type ON public.leave_grants (leave_type_code);
CREATE INDEX idx_leave_grants_expiry ON public.leave_grants (expires_on) WHERE deleted_at IS NULL;

CREATE TRIGGER trg_leave_grants_updated_at
    BEFORE UPDATE ON public.leave_grants
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

ALTER TABLE public.leave_grants ENABLE ROW LEVEL SECURITY;
CREATE POLICY "leave_grants select by permission"
    ON public.leave_grants AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'));
CREATE POLICY "leave_grants select own rows"
    ON public.leave_grants AS PERMISSIVE FOR SELECT TO authenticated
    USING (employee_id = current_user_employee());
CREATE POLICY "leave_grants insert by permission"
    ON public.leave_grants AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_grants update by permission"
    ON public.leave_grants AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.hr.edit')) WITH CHECK (has_permission('module.hr.edit'));
CREATE POLICY "leave_grants delete by permission"
    ON public.leave_grants AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.hr.edit'));

-- ============================================================================
