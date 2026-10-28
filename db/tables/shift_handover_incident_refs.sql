-- db/tables/shift_handover_incident_refs.sql
-- MES-7b-1(2026-10-16,MES-7b Step 0 Q12,Tim):这次交接班【指着】哪几件事故 —— 引用,不是副本(shift_handover_equipment_refs 的同一个形状)。
--   docs/forward-queue.md:2402 等的那一刻到了:WSH 登记簿(incidents)建好之后,交接班才引用事故,"在那之前刻意不留空列"。
--   Q12 裁的形状是一张引用表,不是交接班上的一列:一个班可以有好几件要下一个班注意的事故。
--   在交接班表单上挑(submit_shift_handover 的 p_incident_ids),在交接班页与事故页两边都看得见。
--   【写】只经 submit_shift_handover(交接班一次交齐,之后不改)—— 表上没有写策略,直连的写撞 RLS。
--   【读】module.processing.view(交接班那一页)或 module.safety.view(事故那一页)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.shift_handover_incident_refs (
    handover_id uuid NOT NULL REFERENCES public.shift_handovers (id) ON DELETE CASCADE,
    incident_id uuid NOT NULL REFERENCES public.incidents (id),
    created_at  timestamptz NOT NULL DEFAULT now(),
    created_by  uuid DEFAULT auth.uid(),
    PRIMARY KEY (handover_id, incident_id)
);

CREATE INDEX shift_handover_incident_refs_incident_id_rel ON public.shift_handover_incident_refs (incident_id);

COMMENT ON TABLE public.shift_handover_incident_refs IS
    'MES-7b-1:这次交接班指着哪几件事故(引用,不是副本)。只经 submit_shift_handover 写;交接班页与事故页都读它(module.processing.view 或 module.safety.view)。';

ALTER TABLE public.shift_handover_incident_refs ENABLE ROW LEVEL SECURITY;
CREATE POLICY "shift_handover_incident_refs select by permission" ON public.shift_handover_incident_refs
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.processing.view'::text)) OR (SELECT has_permission('module.safety.view'::text)));
-- 默认权限会把 INSERT / UPDATE / DELETE 也授给 authenticated(线上 pg_default_acl)—— 收掉:这张表只经 submit_shift_handover 写,直连写按 42501 拒。
REVOKE ALL ON public.shift_handover_incident_refs FROM authenticated, anon;
GRANT SELECT ON public.shift_handover_incident_refs TO authenticated;
