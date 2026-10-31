-- db/tables/whistleblowing_reports.sql
-- ESG-2(Tim 2026-10-31 Q11 – Q14):【举报登记簿】—— 一行 = 一件举报。
--   【谁交】(Q11)任何一位登录的员工,在 /me 的「提出一个关切」里交(source = in_system,filed_by_employee_id = 他自己);
--     读者也可以把【系统之外】收到的举报登记进来(电邮、信、电话、当面):outside_named(写下举报人)或 outside_anonymous(匿名来源)。
--   【保密,不是匿名】(Q12)系统里交的举报存着交的人是谁,只有读者看得见;表单照直这么说。「匿名来源」只出现在读者登记的外来举报上。
--   【谁读】(Q13)concerns_cco = false → 持 data.view_whistleblowing 的人(cco);concerns_cco = true(交的人勾了「这件事涉及 CCO」)→ 只有持
--     data.view_whistleblowing_escalated 的人(cfo)读,cco 读不到。判据只有一份:whistleblowing_report_readable(concerns_cco)。
--     交的人读得到【自己那几件的状态】(my_concerns(),不经本表的读策略)。
--   【不改、不删】(Q14)状态的变化是 whistleblowing_updates 的追加行;本表的行写下就定了(语句级守卫,对谁都按名拒)。本刀不设保留期。
--   【不进变更记录】变更记录会把每一行的【操作人】印给持 data.view_change_log 的人(admin · cfo · auditor)—— 那就把「谁交了举报」交了出去;
--     而行本身写下就不改、自带谁在何时(recorded_by / recorded_at)。于是两张举报表登记为变更记录的豁免(change_log_exclusions,带理由),
--     举报的内容与交的人在变更记录里对谁都不出现(Q13:"masked in Change history for everyone except the report's readers" —— 读者在举报页上读全部)。
--   【写】只经 whistleblowing_report_file(员工自己交)与 whistleblowing_report_record_outside(读者登记外来的)。
--
-- NOTE: introduced by db/migrations/2026-10-31-esg-2.sql.
-- First-run script (plain CREATEs).
CREATE TABLE public.whistleblowing_reports (
    id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    source                text NOT NULL CHECK (source IN ('in_system', 'outside_named', 'outside_anonymous')),
    concerns_cco          boolean NOT NULL,
    filed_by_employee_id  uuid REFERENCES public.employees (id),
    reporter_name         text,
    received_via          text CHECK (received_via IS NULL OR received_via IN ('email', 'letter', 'phone', 'in_person', 'other')),
    received_on           date NOT NULL,
    subject               text NOT NULL CHECK (length(btrim(subject)) BETWEEN 1 AND 200),
    details               text NOT NULL CHECK (length(btrim(details)) BETWEEN 1 AND 10000),
    recorded_at           timestamptz NOT NULL DEFAULT now(),
    recorded_by           uuid NOT NULL,
    -- 系统里交的:交的人是一名员工、没有收到的方式与外来的名字;外来的:有收到的方式,具名的写下名字,匿名的不写
    CONSTRAINT whistleblowing_reports_source_shape CHECK (
        (source = 'in_system' AND filed_by_employee_id IS NOT NULL AND reporter_name IS NULL AND received_via IS NULL)
        OR (source = 'outside_named' AND filed_by_employee_id IS NULL AND reporter_name IS NOT NULL AND btrim(reporter_name) <> '' AND received_via IS NOT NULL)
        OR (source = 'outside_anonymous' AND filed_by_employee_id IS NULL AND reporter_name IS NULL AND received_via IS NOT NULL))
);
CREATE INDEX whistleblowing_reports_filed_by_employee_id_rel ON public.whistleblowing_reports (filed_by_employee_id);
COMMENT ON TABLE public.whistleblowing_reports IS
    'ESG-2(Q11–Q14):举报登记簿,一行一件。员工在 /me 交(保密,不是匿名),或读者登记系统之外收到的(具名或匿名来源)。concerns_cco = 真的只由持 data.view_whistleblowing_escalated 的人读(cfo),否则由持 data.view_whistleblowing 的人读(cco)。不改、不删;状态在 whistleblowing_updates。不进变更记录(操作人会把交的人交出去)。';
COMMENT ON COLUMN public.whistleblowing_reports.concerns_cco IS
    '交的人勾了「这件事涉及 CCO」(Q13):真 → 只有持 data.view_whistleblowing_escalated 的人读得到,cco 读不到。';

CREATE OR REPLACE FUNCTION public.guard_whistleblowing_write()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
BEGIN
    RAISE EXCEPTION 'WHISTLEBLOWING_IMMUTABLE';
END;
$function$;
CREATE TRIGGER trg_whistleblowing_reports_immutable
    BEFORE UPDATE OR DELETE ON public.whistleblowing_reports
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_whistleblowing_write();
CREATE TRIGGER trg_whistleblowing_reports_truncate
    BEFORE TRUNCATE ON public.whistleblowing_reports
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();

ALTER TABLE public.whistleblowing_reports ENABLE ROW LEVEL SECURITY;
CREATE POLICY "whistleblowing_reports select by its reader code" ON public.whistleblowing_reports
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (whistleblowing_report_readable(concerns_cco));
REVOKE ALL ON public.whistleblowing_reports FROM authenticated, anon;
GRANT SELECT ON public.whistleblowing_reports TO authenticated;
