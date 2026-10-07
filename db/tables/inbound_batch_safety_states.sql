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
    -- ★ MES-3a(2026-10-06,MES-0 Q36;MES-3a Step 0 Q22 · Q2,Tim):【状态有历史】—— 一条状态被【结束】,不再被删掉。
    --   主键从 (批次, 状态) 换成 id;"同一个状态只记一次"那条规矩挪到【开着的】那几行上(下面的部分唯一索引),
    --   于是同一个状态可以结束之后再被记一次,两段都留着。
    id                uuid NOT NULL DEFAULT gen_random_uuid(),
    created_by_run_id uuid REFERENCES public.processing_runs (id),
    ended_at          timestamptz,
    ended_by          uuid,
    end_reason        text,
    ended_by_run_id   uuid REFERENCES public.processing_runs (id),
    reopened_from_id  uuid,
    CONSTRAINT inbound_batch_safety_states_pkey PRIMARY KEY (id),
    CONSTRAINT inbound_batch_safety_states_reopened_from_fkey
        FOREIGN KEY (reopened_from_id) REFERENCES public.inbound_batch_safety_states (id),
    -- 结束要有理由;没结束的行四格都空。
    CONSTRAINT inbound_batch_safety_states_end_shape
        CHECK ((ended_at IS NULL AND ended_by IS NULL AND end_reason IS NULL AND ended_by_run_id IS NULL)
               OR (ended_at IS NOT NULL AND end_reason IS NOT NULL AND btrim(end_reason) <> ''))
);

COMMENT ON TABLE public.inbound_batch_safety_states IS
'PROC-2:一批料【身上的安全状态】,一行一个。**多值,而且这是它单独成表的全部理由** ——
一批料可以同时是「进过水」与「破损」,而一个单值的列表达不了它。

【开着的 (批次, 状态) 只有一条】(MES-3a 起:部分唯一索引 inbound_batch_safety_states_open_once;此前是主键)。
重复不是"更确定",它只会让任何按状态计数的读法开始骗人。
【有历史】(MES-3a,MES-0 Q36):一条状态被结束(ended_at · ended_by · end_reason,加工解决的还有 ended_by_run_id),不被删掉;
读"现在身上有什么"的地方一律带 ended_at IS NULL。加工写上的那一条记 created_by_run_id,回滚据此把它结束、
并把它结束掉的那几条重新开出来(reopened_from_id 指回原行,记录时刻照抄原行 —— 滞留时钟不因回滚重来)。

【没有安全状态行 = 没有人记过,【不是】"安全"】这与本仓库反复付账的那个区别
是同一个(METAL-1 的 no_reference、SS-1 的阈值为 NULL、PROC-1 的 may_be_processed)。
读它的屏幕与 PROC-3 那道闸都必须把"一条都没有"按名说出来,而不是当成通过。';

CREATE INDEX idx_inbound_batch_safety_states_batch
    ON public.inbound_batch_safety_states (inbound_batch_id);

-- 【一批料的同一个状态,开着的只有一条】重复一行不是"更确定",它只会让任何按状态计数的读法开始骗人(PROC-2 的原规矩,
-- MES-3a 把它从主键挪到这里:结束了的行不算)。
CREATE UNIQUE INDEX inbound_batch_safety_states_open_once
    ON public.inbound_batch_safety_states (inbound_batch_id, safety_state_code) WHERE ended_at IS NULL;

ALTER TABLE public.inbound_batch_safety_states ENABLE ROW LEVEL SECURITY;
-- 【跟着父单据判】与 assay_result_metals 同一条:哪个模块能读/写父,哪个就能读/写行。
CREATE POLICY "inbound_batch_safety_states select by permission"
    ON public.inbound_batch_safety_states
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.inbound.view'::text));
-- ★ MES-3a:没有写策略了 —— 写只经 set_inbound_safety_states(SECURITY DEFINER,module.inbound.edit)、两支收货函数、
--   加工的提交与回滚。直连写由下面的守卫按名拒(SAFETY_STATES_THROUGH_FUNCTION_ONLY),删除一律拒(SAFETY_STATE_NEVER_DELETED)。

-- PROC-2c:适用性守卫。**函数住在 db/functions/**(两张表共用它,而重放顺序是
-- functions → tables,所以两边的触发器都挂得上;先例 guard_soft_delete_provenance)。
CREATE TRIGGER trg_inbound_safety_states_applicable
    BEFORE INSERT ON public.inbound_batch_safety_states
    FOR EACH ROW EXECUTE FUNCTION public.guard_inbound_condition_applicable();


-- ── MES-3a(2026-10-06,MES-3a Step 0 Q22):状态行只经函数写;一行只结束一次;永远不删 ───────────────
-- 取代 SILENT-1 那条 enforce_write_permission 语句级触发器:那条管的是"被拒绝的写要抛",而这里直连写一律按名拒,
-- 删除连属主路径也拒(批次不能硬删 —— BATCH_NO_HARD_DELETE —— 所以级联删除不会走到这里)。
CREATE TRIGGER trg_inbound_safety_states_rows
    BEFORE INSERT OR UPDATE ON public.inbound_batch_safety_states
    FOR EACH ROW EXECUTE FUNCTION public.guard_safety_state_rows();
CREATE TRIGGER trg_inbound_safety_states_statement
    BEFORE UPDATE OR DELETE OR TRUNCATE ON public.inbound_batch_safety_states
    FOR EACH STATEMENT EXECUTE FUNCTION public.guard_safety_state_rows();
