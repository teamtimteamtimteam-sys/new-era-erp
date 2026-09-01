-- db/tables/shift_handover_equipment_refs.sql
-- PROC-SUPPORT-1(R5):这次交接班【指着】哪几段设备停机 —— 引用,不是副本。
--
-- NOTE: introduced by db/migrations/2026-09-01-procsupport1-a-an-operation-is-not-optional.sql.

CREATE TABLE public.shift_handover_equipment_refs (
    handover_id uuid NOT NULL REFERENCES public.shift_handovers (id) ON DELETE CASCADE,
    downtime_id uuid NOT NULL REFERENCES public.equipment_downtime (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    PRIMARY KEY (handover_id, downtime_id)
);

COMMENT ON TABLE public.shift_handover_equipment_refs IS
    'PROC-SUPPORT-1(R5):这次交接班【指着】哪几段设备停机。
★★【为什么是一张引用表,而不是交接班上的几个字段】★★ 设备状态已经有载体:equipment_downtime(EQP-2a),一行一段,ended_at 可空正好表示"到交班这一刻还没结束" —— 那恰恰是交班的人要说的话。
**一次事件两份记录,迟早会不一致,而人们读到的那一份会是错的那一份。** 所以这里存的是 downtime_id,不是 reason 的一份抄写。想知道那台机器怎么了,读 equipment_downtime;这张表只回答"交班的人当时要下一个班注意哪几段"。
同一条论证 forward-queue.md 已经对保险用过一次:「保险【就是一种证书】,不是第二套到期机制」。';

ALTER TABLE public.shift_handover_equipment_refs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_handover_equipment_refs select by permission" ON public.shift_handover_equipment_refs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.processing.view'::text));
CREATE POLICY "shift_handover_equipment_refs write by permission" ON public.shift_handover_equipment_refs
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.shift_handover_equipment_refs TO authenticated;
