-- db/tables/overtime_lines.sql
-- OVERTIME-1(2026-09-28):一行 = 一个员工一天的加班 —— 日期 + 小时 + 可选备注(Tim 的裁定)。
--
-- 【小时是批准的那个数】不从打卡推(系统里没有打卡:Tim 裁定打卡在另一个 App 里)。
-- 【day_kind】那一天是哪一类:public_holidays 里有的 → public_holiday;星期日 → rest_day(对所有人);
--   其余 → weekday(Tim Q4)。录的时候算一次,提交与批准时再算一次 —— 批准那一刻的答案就是冻进
--   考勤的那个桶。按人的休息日是以后的事(docs/known-issues.md C-2-OT)。
-- 【同一个员工同一天只许一行活着的】(Tim Q15)部分唯一索引兜底,函数先按名拒 OVERTIME_DUPLICATE_DAY。
--   "活着" = voided_at IS NULL。整批冲销或丢弃时,那一批的行一起作废,日期随之腾出来。
--
-- NOTE: introduced by db/migrations/2026-09-28-overtime1-site-staff-overtime-by-month.sql.

CREATE TABLE public.overtime_lines (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    batch_id    uuid NOT NULL REFERENCES public.overtime_batches (id) ON DELETE CASCADE,
    employee_id uuid NOT NULL REFERENCES public.employees (id) ON DELETE RESTRICT,
    work_date   date NOT NULL,
    hours       numeric(4,2) NOT NULL CHECK (hours > 0 AND hours <= 24),
    day_kind    text NOT NULL CHECK (day_kind IN ('weekday', 'rest_day', 'public_holiday')),
    note        text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid,
    voided_at   timestamptz
);

COMMENT ON TABLE public.overtime_lines IS
    'OVERTIME-1:一个员工一天的加班小时(批准的数,不是从打卡推出来的)。只经 add_overtime_line 写入(只录得进标为现场员工的人,日期在批次那个月里、不在未来、在职);同一个员工同一天只许一行活着的(voided_at IS NULL)。day_kind 按 overtime_day_kind 判:公共假期 → public_holiday,星期日 → rest_day,其余 → weekday。';

CREATE UNIQUE INDEX overtime_lines_one_per_employee_day
    ON public.overtime_lines (employee_id, work_date) WHERE voided_at IS NULL;
CREATE INDEX overtime_lines_employee_id_rel ON public.overtime_lines (employee_id);
CREATE INDEX overtime_lines_batch_id_rel ON public.overtime_lines (batch_id);

ALTER TABLE public.overtime_lines ENABLE ROW LEVEL SECURITY;

-- 读:与批次同一组码。
-- ★【本人那一半【不】写成一条策略】/me 上员工读自己【已批准、没作废】的行(Tim Q14)。
--   写成策略要问"那一批批准了没有",而那一问读 overtime_batches —— 策略里的子查询照样受
--   overtime_batches 自己的 RLS 约束,一个普通员工读不到批次,于是 EXISTS 恒假、他一行都看不见,
--   而且不报错。所以本人那一半走属主权限的 my_overtime_lines()(与 my_document_decisions 同形)。
CREATE POLICY "overtime_lines select by permission" ON public.overtime_lines
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.hr.view'::text)
        OR has_permission('action.overtime_enter'::text)
        OR has_permission('action.overtime_approve'::text));

REVOKE ALL ON public.overtime_lines FROM anon;
