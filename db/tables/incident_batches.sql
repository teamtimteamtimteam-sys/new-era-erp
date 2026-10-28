-- db/tables/incident_batches.sql
-- MES-7b-1(2026-10-16,MES-0 Q73;MES-7b Step 0 Q7 · Q8,Tim):【一件事故碰过哪几批货】—— 一条链接,由一个人确认。
--   【建议从哪里来】(suggest_incident_batches,Q7)只有两种,而且【没有编一个时间窗】:
--     location     那一刻在事故库位上有货的批(那个库位上、发生时刻之前的流水净数 > 0);
--     machine_run  那一刻正在那台机器上跑的加工单([started_at, ended_at) 包含发生时刻、已提交、没回滚)的投入与产出批。
--   人对每一条建议各自确认(建一行,basis 记下是哪一种建议);任何一批也可以按批号挑出来(basis = picked)。
--   【一条链接不是一个安全状态】(MES-0 Q73,Tim 的裁定,inbound_safety_states.sql:49-55)—— 建 / 解链接一个字都不碰
--     inbound_batch_safety_states / output_batch_safety_states,也不动库存。要扣住一批,是在事故页上由持 module.quality.edit 的人
--     开一张来源 incident 的不合格报告(Q8),那时既有的质量暂扣照常生效。
--   【解链接要理由】一行链接只改一次:填上 unlinked_at / unlinked_by / unlink_reason(必填),之后对谁都不改;不删。
--     同一件事故 × 同一批同时最多一条有效链接(部分唯一索引);解了之后可以再链一次(新的一行)。
--   【写】只经 link_incident_batch / unlink_incident_batch(module.safety.edit)。会话里直连的写按名拒 INCIDENT_LINK_THROUGH_FUNCTION_ONLY。
--   【读】module.safety.view,或那一批自己那一页的查看码(批次页上的「关联的事故」那一行给两种码任一的人看 —— 样品与 NCR 同一个处置)。
--
-- NOTE: introduced by db/migrations/2026-10-16-mes7b1-incidents.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.incident_batches (
    id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    incident_id      uuid NOT NULL REFERENCES public.incidents (id),
    inbound_batch_id uuid REFERENCES public.inbound_batches (id),
    output_batch_id  uuid REFERENCES public.output_batches (id),
    basis            text NOT NULL CHECK (basis IN ('location', 'machine_run', 'picked')),
    linked_at        timestamptz NOT NULL DEFAULT now(),
    linked_by        uuid DEFAULT auth.uid(),
    unlinked_at      timestamptz,
    unlinked_by      uuid,
    unlink_reason    text,
    CONSTRAINT incident_batches_one_batch CHECK (num_nonnulls(inbound_batch_id, output_batch_id) = 1),
    -- 解链接的三样同进同出,理由不许是空白
    CONSTRAINT incident_batches_unlink_consistent CHECK (
        (unlinked_at IS NULL AND unlinked_by IS NULL AND unlink_reason IS NULL)
        OR (unlinked_at IS NOT NULL AND unlink_reason IS NOT NULL AND btrim(unlink_reason) <> ''))
);

CREATE INDEX incident_batches_incident_id_rel ON public.incident_batches (incident_id);
CREATE INDEX incident_batches_inbound_batch_id_rel ON public.incident_batches (inbound_batch_id);
CREATE INDEX incident_batches_output_batch_id_rel ON public.incident_batches (output_batch_id);
-- 同一件事故 × 同一批,同时最多一条有效链接
CREATE UNIQUE INDEX incident_batches_one_active
    ON public.incident_batches (incident_id, COALESCE(inbound_batch_id, output_batch_id))
    WHERE unlinked_at IS NULL;

COMMENT ON TABLE public.incident_batches IS
    'MES-7b-1:一件事故碰过的一批货(进料或产出,恰好一个)。basis:location(那一刻在事故库位上有货)· machine_run(那一刻在那台机器上跑的加工单的投入 / 产出)· picked(按批号挑的)。人确认才有这一行;解链接要理由,之后不改、不删。一条链接从不设任何安全状态(MES-0 Q73)。写只经 link_incident_batch / unlink_incident_batch(module.safety.edit)。';

ALTER TABLE public.incident_batches ENABLE ROW LEVEL SECURITY;
CREATE POLICY "incident_batches select by permission" ON public.incident_batches
    AS PERMISSIVE FOR SELECT TO authenticated
    USING ((SELECT has_permission('module.safety.view'::text))
        OR (inbound_batch_id IS NOT NULL AND (SELECT has_permission('module.inbound.view'::text)))
        OR (output_batch_id IS NOT NULL AND (SELECT has_permission('module.output.view'::text))));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.incident_batches TO authenticated;
REVOKE ALL ON public.incident_batches FROM anon;

-- 会话里直连的插入与改按名拒(属主路径放行);一行链接只在【解链接】那一次改,只许动那三列;不删。
CREATE TRIGGER trg_incident_batches_row
    BEFORE INSERT OR UPDATE OR DELETE ON public.incident_batches
    FOR EACH ROW EXECUTE FUNCTION public.guard_incident_batch_write();
-- 语句级:RLS 让一句 UPDATE / DELETE 碰不到任何一行时,它照样抛(ALERT-1)
CREATE TRIGGER trg_incident_batches_statement
    BEFORE UPDATE OR DELETE ON public.incident_batches
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_incident_batch_write();
CREATE TRIGGER trg_incident_batches_truncate
    BEFORE TRUNCATE ON public.incident_batches
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_append_only_log();
