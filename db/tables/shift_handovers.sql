-- db/tables/shift_handovers.sql
-- PROC-SUPPORT-1(R4/R5):一次交接班。**它【指向】别处的记录,不【复述】它们。**
-- 刻意没有的三样:"这个班处理了什么"(阻塞在 G8)、设备状态正文(在
-- equipment_downtime)、事故(属于尚未建的 WSH 登记簿,现在连列都不留)。
--
-- NOTE: introduced by db/migrations/2026-09-01-procsupport1-a-an-operation-is-not-optional.sql.

CREATE TABLE public.shift_handovers (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    shift_code           text NOT NULL REFERENCES public.shifts (code),
    handover_date        date NOT NULL,
    outgoing_employee_id uuid NOT NULL REFERENCES public.employees (id),
    incoming_employee_id uuid NOT NULL REFERENCES public.employees (id),
    notes                text,
    submitted_at         timestamptz NOT NULL DEFAULT now(),
    submitted_by         uuid,
    -- ★【签收:没签 vs 签了】两列一起空、一起满。抄 attendance_lines.recorded_at
    --   那条"没记 vs 记了是零"的形状。
    acknowledged_at      timestamptz,
    acknowledged_by      uuid REFERENCES public.employees (id),
    created_at           timestamptz NOT NULL DEFAULT now(),
    created_by           uuid DEFAULT auth.uid(),
    updated_at           timestamptz NOT NULL DEFAULT now(),
    updated_by           uuid,
    CONSTRAINT shift_handover_one_per_shift_date UNIQUE (shift_code, handover_date),
    -- 一个人不能交给自己 —— 那样的"交接"没有传递任何东西。
    CONSTRAINT shift_handover_two_people
        CHECK (outgoing_employee_id <> incoming_employee_id),
    -- ★ 签收的两列要么都空(未签收),要么都满(签收了,而且说得出是谁、什么时候)。
    --   只有时间没有人 = 一次说不出是谁签的签收,那比没签更坏。
    CONSTRAINT shift_handover_ack_paired
        CHECK (num_nonnulls(acknowledged_at, acknowledged_by) <> 1)
);

COMMENT ON TABLE public.shift_handovers IS
    'PROC-SUPPORT-1(R4/R5):一次交接班。**它【指向】别处的记录,不【复述】它们。**
【一张交接班上确定有的东西】哪个班(shift_code)、哪一天、谁交给谁、接班人的签收。
【刻意【没有】的东西,逐条给理由 —— 请不要"补全"它们】
  ① **"这个班处理了什么、多少" —— 没有这一栏。** processing_runs 只有 process_date(一个 date),全库 time 列在本刀之前为 0,所以**一张加工单归不到某一个班次上**。这是阶段 7 的 **G8**。一个自由文本会装一个猜测,而那个猜测会与加工单算出来的数打架 —— **人们读到的那一份会是错的那一份**。缺席看得见,不一致看不见。
  ② **设备状态 —— 不在这张表上,在 equipment_downtime(EQP-2a)。** 交接班经 shift_handover_equipment_refs 挂一条【引用】。同一件事记两遍,迟早不一致。
  ③ **事故 —— 连一列都不留。** 它属于那本尚未建的 WSH 事故与未遂事件登记簿(forward-queue.md:1198,触发条件"第一个技师上岗")。留一个指向不存在的表的空外键,读起来像"忘了填" —— EQP-2a 已经按名拒绝过这种做法。
  ④ **NEA 的法定时限(立即通报 / 两个工作日内书面报告)不在这里。** 见 R6 与 docs/processing-support-as-built.md:法定时限只能有一个载体。
【第一天它会装什么】**零行。** 线上 work_category = ''shopfloor'' 的员工数是 **0** —— 没有人交班,也没有人接班。本刀交付的是形状与屏幕,不是内容,而这一点不许被打扮成别的样子。';

COMMENT ON COLUMN public.shift_handovers.acknowledged_at IS
    'PROC-SUPPORT-1(R4):接班人签收的时刻。**空 = 还没有人签收**,不是"签收了但没记时间"。
与 acknowledged_by 由 shift_handover_ack_paired 绑成一对:要么都空,要么都满。**一次说不出是谁签的签收比没签更坏** —— 它看起来像有人负责了。
【未签收必须在屏幕上看得见】不是靠一个空白格,而是一个具名的状态(【待签收】)。空白格读起来像"这一栏不重要"。';

COMMENT ON COLUMN public.shift_handovers.acknowledged_by IS
    'PROC-SUPPORT-1(R4):是谁签收的 —— 一个 employees 引用,不是一个 auth 用户 id。
【为什么指向 employees 而不是 user_id】交接班是【车间里两个人】之间的事,而不是两个登录账号之间的事;一个技师可能共用工位账号,而"谁接的班"必须是一个人。acknowledge_shift_handover() 只认 current_user_employee(),并且**只允许这张交接班点名的那位接班人签收** —— 见该函数的函数头。';

ALTER TABLE public.shift_handovers ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_handovers select by permission" ON public.shift_handovers
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "shift_handovers write by permission" ON public.shift_handovers
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shift_handovers TO authenticated;

CREATE TRIGGER trg_shift_handovers_updated_at
    BEFORE UPDATE ON public.shift_handovers
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();
