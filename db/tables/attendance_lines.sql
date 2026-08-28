-- db/tables/attendance_lines.sql
-- ATTEND-1:每月每人一行。
--
-- ★【「没记」与「记了是零」的分界是 recorded_at,不是工时之和】★
-- 把前者折叠成后者,就是让一次工资过账把「缺勤未知」当成「全勤」。
-- 表级 CHECK attendance_lines_recorded_shape 顺带让那半边状态【建不出来】——
-- 故障注入 B2 撞的正是它。
--
-- NOTE: introduced by db/migrations/2026-08-28-attend1-attendance-as-payroll-input.sql.

CREATE TABLE public.attendance_lines (
    id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    period_id              uuid NOT NULL REFERENCES public.attendance_periods (id) ON DELETE CASCADE,
    employee_id            uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    -- ★【加班按【何时发生】分三列,而【没有】倍率那一列】★ 见抬头 §3:
    -- 何时发生是事实,乘以多少是《雇佣法令》下一个还开着的问题。
    ot_normal_hours        numeric NOT NULL DEFAULT 0 CHECK (ot_normal_hours >= 0),
    ot_rest_day_hours      numeric NOT NULL DEFAULT 0 CHECK (ot_rest_day_hours >= 0),
    ot_public_holiday_hours numeric NOT NULL DEFAULT 0 CHECK (ot_public_holiday_hours >= 0),
    note                   text,
    -- ★【「没记」与「记了是零」的分界就在这一列】★
    recorded_at            timestamptz,
    recorded_by            uuid,
    -- ══ 完成那一刻冻下来的【推导值】════════════════════════════════════════
    -- 冻它们,是为了「我们当时报给服务商的是什么」在请假单事后被取消之后
    -- 仍然读得出来。
    unpaid_days            numeric,
    active_from            date,
    active_to              date,
    frozen_at              timestamptz,
    UNIQUE (period_id, employee_id),
    CONSTRAINT attendance_lines_recorded_shape
        CHECK ((recorded_at IS NULL) = (recorded_by IS NULL))
);

COMMENT ON TABLE public.attendance_lines IS
    'ATTEND-1:每月每人一行的工资申报底稿。★【唯一【打字】进来的只有加班工时与一句备注】★ —— 无薪假天数【推导】自已批准的请假单(请假是一个完整的 15 支函数模块,含 unpaid 假别与半天精度,calculate_leave_days 本身就懂工作日与公共假期),月中入离职推导自 employees.hire_date / separation_date。重打一遍就会有两个答案,而它们会在请假单事后被取消那一刻分家。★【「没记」不是「零」】★ 三列工时 NOT NULL DEFAULT 0,而【有没有人记过】由 recorded_at 单独说:NULL = 没人记过,非空 = 记过(哪怕三个数都是 0)。把前者折叠成后者,就是让一次工资过账把「缺勤未知」当成「全勤」—— 这一刀最要防的正是这件事。【加班没有倍率列】何时发生是事实,乘以多少是《雇佣法令》下开着的问题,而本仓库读得到的文档里没有任何关于它的记录,在册六人也全是 office/full_time。';

CREATE INDEX idx_attendance_lines_period ON public.attendance_lines (period_id);
CREATE INDEX idx_attendance_lines_employee ON public.attendance_lines (employee_id);
CREATE INDEX idx_attendance_lines_unrecorded ON public.attendance_lines (period_id)
    WHERE recorded_at IS NULL;

ALTER TABLE public.attendance_lines ENABLE ROW LEVEL SECURITY;

-- 【读:HR 看得见全部,员工看得见自己那一行】—— 与 my_profile / 报销同一条思路。
-- 员工看得见【关于他自己被报了什么】,正是让错误被抓住的那一半。
CREATE POLICY "attendance_lines select by permission" ON public.attendance_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text)
        OR employee_id = current_user_employee());
