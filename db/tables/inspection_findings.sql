-- db/tables/inspection_findings.sql
-- MES-7b-2(2026-10-16,MES-0 Q72;MES-7b Step 0 Q14 · Q15,Tim):【一条巡检发现】—— 一次巡检里一项不合格之后要做的事:纠正措施、负责的人
--   (一名员工)、一个【人自己选的】到期日(可空 —— 没有默认,Q14:不编一个数)。它是自己的一条记录,不是一张任务。
--   【关闭】是另一行(inspection_finding_closures:做了什么、谁、什么时候)。开着的发现由提醒 inspection_finding_open 列出。
--   【"建一张任务"】(Q14)按下它的人给自己建一张私人任务(raise_inspection_finding_task —— 任务模块一行不改,走的是它自己那条
--     "自己的私人任务"的路),这一行的 task_id 指着它。【关掉那张任务不关闭这条发现】—— 两件事,两个出口。task_id 只写一次。
--   【不合格报告】(Q15)一条发现说的是一批货时,持 module.quality.edit 的人开一张来源 inspection 的不合格报告,那张报告必须引用这条发现
--     (nonconformance_reports.inspection_finding_id;open_ncr 判)—— 质量暂扣照旧。
--   【写】只经 record_inspection_finding / record_inspection_run(module.safety.edit),只能挂在同一次巡检里一项【不合格】的结果上
--     (INSPECTION_FINDING_NOT_A_FAIL|<项>),而那一次巡检没有被更正过(INSPECTION_RUN_SUPERSEDED|<编号>)。写下之后只有 task_id 那一次能填
--     (经 raise_inspection_finding_task),别的一列都不改、不删(INSPECTION_FINDING_IMMUTABLE)。会话里直连的写按名拒。
--   【读】module.safety.view。没有金额。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b2-inspections-and-environment.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inspection_findings (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    run_id            uuid NOT NULL REFERENCES public.inspection_runs (id),
    result_id         bigint NOT NULL REFERENCES public.inspection_results (id),
    corrective_action text NOT NULL CHECK (btrim(corrective_action) <> ''),
    owner_employee_id uuid NOT NULL REFERENCES public.employees (id),
    due_date          date,
    task_id           uuid REFERENCES public.tasks (id),
    recorded_at       timestamptz NOT NULL DEFAULT now(),
    recorded_by       uuid DEFAULT auth.uid()
);

CREATE INDEX inspection_findings_run_id_rel ON public.inspection_findings (run_id);
CREATE INDEX inspection_findings_result_id_rel ON public.inspection_findings (result_id);
CREATE INDEX inspection_findings_owner_employee_id_rel ON public.inspection_findings (owner_employee_id);
CREATE INDEX inspection_findings_task_id_rel ON public.inspection_findings (task_id);

COMMENT ON TABLE public.inspection_findings IS
    'MES-7b-2:一条巡检发现 —— 一项不合格之后的纠正措施、负责的员工、人选的到期日(可空,没有默认)。关闭是 inspection_finding_closures 的一行;开着的由提醒列出。"建一张任务"给按下的人建一张私人任务、task_id 指着它 —— 关掉任务不关闭发现。来源 inspection 的不合格报告必须引用一条发现。写只经 record_inspection_finding / record_inspection_run(module.safety.edit),之后只有 task_id 能填一次。读 module.safety.view。';
COMMENT ON COLUMN public.inspection_findings.due_date IS
    '人自己选的到期日(可空)—— 没有默认、没有"几天之内"的规矩(Q14)。过了这一天而发现还开着,提醒上照实说"过期"。';
COMMENT ON COLUMN public.inspection_findings.task_id IS
    '按"建一张任务"的那个人给自己建的私人任务(raise_inspection_finding_task)。只写一次;关掉那张任务【不】关闭这条发现(Q14)。';

ALTER TABLE public.inspection_findings ENABLE ROW LEVEL SECURITY;
CREATE POLICY "inspection_findings select by permission" ON public.inspection_findings
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.safety.view'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.inspection_findings TO authenticated;
REVOKE ALL ON public.inspection_findings FROM anon;

-- 插入与改(行级):直连按名拒;挂在同一次巡检里一项不合格的结果上;改只许 task_id 从空到有。直连的改与删(语句级)按名拒,删对谁都拒。
CREATE TRIGGER trg_inspection_findings_row
    BEFORE INSERT OR UPDATE ON public.inspection_findings
    FOR EACH ROW EXECUTE FUNCTION public.guard_inspection_record_write();
CREATE TRIGGER trg_inspection_findings_statement
    BEFORE UPDATE OR DELETE ON public.inspection_findings
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_inspection_record_write();
CREATE TRIGGER trg_inspection_findings_truncate
    BEFORE TRUNCATE ON public.inspection_findings
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
