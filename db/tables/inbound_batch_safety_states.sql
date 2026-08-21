-- db/tables/inbound_batch_safety_states.sql
-- PROC-2:一批料【身上的安全状态】,一行一个。**多值,这是它单独成表的全部理由** ——
-- 一批料可以同时是「进过水」与「破损」,而一个单值的列表达不了它。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc2-intake-condition-axes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inbound_batch_safety_states (
    inbound_batch_id  uuid NOT NULL REFERENCES public.inbound_batches (id) ON DELETE CASCADE,
    safety_state_code text NOT NULL REFERENCES public.inbound_safety_states (code),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    -- 【一批料的同一个状态只记一次】主键就是那条规矩 ——
    -- 重复一行不是"更确定",它只会让任何按状态计数的读法开始骗人。
    PRIMARY KEY (inbound_batch_id, safety_state_code)
);

COMMENT ON TABLE public.inbound_batch_safety_states IS
'PROC-2:一批料【身上的安全状态】,一行一个。**多值,而且这是它单独成表的全部理由** ——
一批料可以同时是「进过水」与「破损」,而一个单值的列表达不了它。

【主键 = (批次, 状态)】同一个状态在同一批上只记一次。重复不是"更确定",
它只会让任何按状态计数的读法开始骗人。

【没有安全状态行 = 没有人记过,【不是】"安全"】这与本仓库反复付账的那个区别
是同一个(METAL-1 的 no_reference、SS-1 的阈值为 NULL、PROC-1 的 may_be_processed)。
读它的屏幕与 PROC-3 那道闸都必须把"一条都没有"按名说出来,而不是当成通过。';

CREATE INDEX idx_inbound_batch_safety_states_batch
    ON public.inbound_batch_safety_states (inbound_batch_id);

ALTER TABLE public.inbound_batch_safety_states ENABLE ROW LEVEL SECURITY;
-- 【跟着父单据判】与 assay_result_metals 同一条:哪个模块能读/写父,哪个就能读/写行。
CREATE POLICY "inbound_batch_safety_states select by permission"
    ON public.inbound_batch_safety_states
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));
CREATE POLICY "inbound_batch_safety_states insert by permission"
    ON public.inbound_batch_safety_states
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.inbound.edit'::text));
CREATE POLICY "inbound_batch_safety_states delete by permission"
    ON public.inbound_batch_safety_states
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.inbound.edit'::text));

-- PROC-2c:适用性守卫。**函数住在 db/functions/**(两张表共用它,而重放顺序是
-- functions → tables,所以两边的触发器都挂得上;先例 guard_soft_delete_provenance)。
CREATE TRIGGER trg_inbound_safety_states_applicable
    BEFORE INSERT ON public.inbound_batch_safety_states
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_condition_applicable();

