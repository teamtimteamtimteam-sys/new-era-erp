-- db/tables/handover_item_types.sql
-- PROC-SUPPORT-1(R4):交接班记哪几类内容。RUNTIME CONFIG ——
-- ★ 第七个交接班字段是【加一行】,不是一次改代码。★
--
-- NOTE: introduced by db/migrations/2026-09-01-procsupport1-a-an-operation-is-not-optional.sql.

CREATE TABLE public.handover_item_types (
    code        text PRIMARY KEY,
    name_en     text NOT NULL,
    name_zh     text NOT NULL,
    is_required boolean NOT NULL DEFAULT false,
    sort_order  integer NOT NULL DEFAULT 0,
    is_active   boolean NOT NULL DEFAULT true,
    notes       text
);

COMMENT ON TABLE public.handover_item_types IS
    'PROC-SUPPORT-1(R4):交接班【记哪几类内容】。RUNTIME CONFIG —— ★ 第七个交接班字段是【加一行】,不是一次改代码 ★,那正是 Tim 要的形状。
形状抄仓库里已经被用了三次的那一套(operation_type_input_forms / _output_forms / operation_type_safety_states),规则列抄 output_batch_purposes.is_saleable_stock:**行为由数据回答,不由写死的字符串回答。**
★【第一天这张字典里只有【一行】,而那正是重点】★ Tim 列的七项确定内容里:
  · 哪个班、几点到几点 → shifts 那张表(时刻待 Tim 填);
  · 谁交给谁 / 接班人签收 → shift_handovers 上的列(它们是每张交接班【恰好一份】的事实,不是可增删的条目);
  · 设备状态 → **引用** equipment_downtime(R5,不复述);
  · 事故 → 属于那本尚未建的 WSH 登记簿(R5/R6),**现在连列都不留**;
  · 这个班处理了什么 → **答不出来,阻塞在 G8**,所以不建;
  · 未完成工作 → **就是这一行**,而且它是这一件里【唯一】没有现成载体的实质内容。
所以一行不是"建少了",是把每一项都放回了它该在的地方之后剩下的那一项。';

COMMENT ON COLUMN public.handover_item_types.is_required IS
    '这一类内容是不是【必须至少有一条】才算交接完成。规则列 —— 由数据回答,不由代码里的 if 回答(抄 output_batch_purposes.is_saleable_stock)。
【unfinished_work 引导为 false,理由要说出来】"没有未完成的工作"是一个【合法且常见】的班次结果,而必填会逼着人写一句"无" —— 那句"无"与"没人填"在数据里长得一样,于是必填反而毁掉了这一栏的意义。这与 inbound_batches 那条"没有行 = 没人记录过,不是记录了零"同一条。';

INSERT INTO public.handover_item_types (code, name_en, name_zh, is_required, sort_order, is_active, notes) VALUES
    ('unfinished_work', 'Unfinished work', '未完成工作', false, 1, true,
     '料还在机器里、批次喂了一半、某台机器停在半程 —— **这一件里唯一没有现成载体的实质内容**。引导 is_required = false:"这个班没有未完成的工作"是一个合法结果,必填会逼出一句毫无信息量的"无"。');

ALTER TABLE public.handover_item_types ENABLE ROW LEVEL SECURITY;
CREATE POLICY "handover_item_types select all" ON public.handover_item_types
    AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "handover_item_types write by permission" ON public.handover_item_types
    AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.handover_item_types TO authenticated;
