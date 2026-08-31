-- db/tables/output_batch_safety_states.sql
-- PROC-WIRE-1B-ii(R1 / M4):一批【产出】料身上的安全状态,一行一个。多值。
-- **共用 inbound_safety_states 这本字典** —— 必须不许分叉的是字典,不是这张联结表。
--
-- NOTE: introduced by db/migrations/2026-08-31-procwire1bii-an-assertion-that-cannot-see-must-refuse-by-name.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.output_batch_safety_states (
    output_batch_id   uuid NOT NULL REFERENCES public.output_batches (id) ON DELETE CASCADE,
    safety_state_code text NOT NULL REFERENCES public.inbound_safety_states (code),
    created_at        timestamptz NOT NULL DEFAULT now(),
    created_by        uuid DEFAULT auth.uid(),
    -- 【一批料的同一个状态只记一次】与进料侧逐字同源:重复一行不是"更确定",
    -- 它只会让任何按状态计数的读法开始骗人。
    PRIMARY KEY (output_batch_id, safety_state_code)
);

COMMENT ON TABLE public.output_batch_safety_states IS
'PROC-WIRE-1B-ii(R1 / M4):一批【产出】料身上的安全状态,一行一个。多值。

★【它存在的理由:那处不对称是"问不了",不是"不需要问"】★
guard_processing_input 里 PROC-3 那一段过去只问 inbound_batch_id ——
于是【买进来的】极片要过火闸,而【自己产的】极片连问都问不到。
Tim 的 R1:**抬高产出这一侧,绝不放低进料那一侧。** 这张表就是那个抬高。

【为什么是平行表,而不是把 inbound_batch_safety_states 改成 XOR】
仓库里两个先例指向两个方向:processing_inputs 走 XOR,
inbound_batch_metals / output_batch_metals 走平行表。
**更近的是金属那一对** —— 一个逐批的实测事实,两种出处。
改老表要动一个带主键、带触发器、有线上行的结构,买到的只是少一条分支。
**照抄一个先例之前要问那个先例成立的条件在这里成不成立。**

★【没有安全状态行 = 没有人记过,【不是】"安全"】★ 与进料侧【同一个意思】——
**这正是它必须与那边一致的地方**:同一种"空"在两张表里若有相反的意思,
就是本仓库反复付账的那一族(METAL-1 的 no_reference、SS-1 的阈值 NULL、
PROC-1 的 may_be_processed)。缺席 → PRODUCED_SAFETY_STATE_NOT_RECORDED。

★【回填:一行都没有写,而这是一个【决定】】★ 线上 20 批产出全是测试残留,
产线一天没开过。给它们写上一个状态等于**记下一次没有人做过的核验** ——
一条假记录,与把 ZZ-PROCCOST1-DEMO 注销掉是同一种错。
所以:**不回填,而缺席拦人。** 代价量过:线上 14 批活着的产出批一批都没记过,
于是此后再投料它们中的任何一批都会被拦,直到有人去记 ——
**今天代价为零(产线没开),而那正是这道火闸要的那个动作。**';

CREATE INDEX idx_output_batch_safety_states_batch
    ON public.output_batch_safety_states (output_batch_id);

ALTER TABLE public.output_batch_safety_states ENABLE ROW LEVEL SECURITY;
-- 【跟着父单据判】与 inbound_batch_safety_states 逐字同源:哪个模块能读/写父,
-- 哪个就能读/写行。产出批的父模块是 output。
CREATE POLICY "output_batch_safety_states select by permission"
    ON public.output_batch_safety_states
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.output.view'::text));
CREATE POLICY "output_batch_safety_states insert by permission"
    ON public.output_batch_safety_states
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.output.edit'::text));
CREATE POLICY "output_batch_safety_states delete by permission"
    ON public.output_batch_safety_states
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.output.edit'::text));

GRANT SELECT, INSERT, DELETE ON public.output_batch_safety_states TO authenticated;
