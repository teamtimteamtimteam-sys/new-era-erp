-- db/tables/attendance_periods.sql
-- ATTEND-1:一个月一行的工资申报底稿期间。
--
-- ★【它喂的不是一次计算】★ 工资什么都不算(会计政策 7.1:外部服务商编制,
-- 系统只记录与过账)。所以这张表不是算式的输入,它是【我们每月告诉服务商的
-- 那些数】—— 而那些数在这一刀之前不留任何痕迹。
--
-- NOTE: introduced by db/migrations/2026-08-28-attend1-attendance-as-payroll-input.sql.

CREATE TABLE public.attendance_periods (
    id             uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    code           text NOT NULL UNIQUE,          -- ATT-YYYY-MM
    period_month   date NOT NULL UNIQUE,          -- 当月 1 号
    status         text NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'complete')),
    opened_at      timestamptz NOT NULL DEFAULT now(),
    opened_by      uuid,
    completed_at   timestamptz,
    completed_by   uuid,
    reopened_at    timestamptz,
    reopened_by    uuid,
    reopen_reason  text,
    CONSTRAINT attendance_periods_month_shape
        CHECK (period_month = date_trunc('month', period_month)::date),
    CONSTRAINT attendance_periods_complete_shape
        CHECK ((status = 'complete') = (completed_at IS NOT NULL)),
    CONSTRAINT attendance_periods_reopen_shape
        CHECK ((reopened_at IS NULL) = (reopened_by IS NULL)),
    -- 重开必须给理由 —— 一次没有理由的重开,下一个人无从判断该不该信这份底稿
    CONSTRAINT attendance_periods_reopen_reason
        CHECK (reopened_at IS NULL OR btrim(COALESCE(reopen_reason, '')) <> '')
);

COMMENT ON TABLE public.attendance_periods IS
    'ATTEND-1:一个月一行的【工资申报底稿】期间。★【它喂的不是一次计算】★ —— 实测工资什么都不算(会计政策 7.1:由外部服务商编制,系统只记录与过账;upsert_payroll_period 把 gross/CPF/net 原样收下)。所以加班、无薪假、月中入离职都不是"喂进算式",它们是【我们每月告诉服务商的那些数】,而那些数今天不留任何痕迹 —— 没人能重建一张工资单为什么是这个数。【为什么"完成"是一次人的断言】系统无法知道考勤是否齐全,只能知道有没有人说过它齐全;与 finance_settings.system_start_date 是【声明】而不是【推断】同一条。而工资过账正是靠这句断言才敢拒绝。【重开的边界】那个月的工资一旦过账,这份底稿就不许再动 —— 一张已过账工资单的依据不能在它脚下改变;要改先 unpost(那支函数自己有 CPF/扣款已汇出的守卫)。';

CREATE INDEX idx_attendance_periods_month ON public.attendance_periods (period_month DESC);

ALTER TABLE public.attendance_periods ENABLE ROW LEVEL SECURITY;

CREATE POLICY "attendance_periods select by permission" ON public.attendance_periods
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text));
