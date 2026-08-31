-- db/tables/deep_discharge_judgements.sql
-- PROC-1B-iii:【这批料能不能深度放电】—— 采购时做出的那个判断,一个三值字典。
--
-- 【RUNTIME CONFIG】加一种是加一行(与 inbound_safety_states / output_batch_purposes
-- 同形,check_mirrors 不逐行比对内容)。
--
-- NOTE: introduced by db/migrations/2026-08-31-proc1biii-the-purchase-time-judgement-and-reservations-outrank-the-earmark.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.deep_discharge_judgements (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    -- 【规则列,而且它【有消费者】】grn_discrepancies 拿它决定"这一侧算不算
    -- 一次主张"。没有它,那张视图就得把 'not_assessed' 这个字面量写死在
    -- CASE 里 —— 而这个仓库对写死阈值有一条成文的规矩(见 grn_discrepancies
    -- 抬头【阈值一个都没写死】)。
    -- ★【它不是一个没人读的列】★ 加一列没人读的东西,会教下一个人
    --   "这件事已经在管了" —— 见 inbound_safety_states 抬头对"存放要求"的处置。
    is_a_claim boolean NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.deep_discharge_judgements IS
'PROC-1B-iii:【这批料能不能深度放电】—— 一个在【采购时】做出的判断。
RUNTIME CONFIG,加一种是加一行(与 inbound_safety_states / output_batch_purposes 同形)。

★【三个值各自路由到哪里 —— 这是本表存在的理由,不是装饰】★
  · can          → 【深度放电】(专用设备)→ 人工拆解 → 电芯 → …
  · cannot       → 【整电池粉料线】(旁路;它与极片粉料线是两台设备,两道工序)
  · not_assessed → **不可路由。** 没有人看过,而【你不许照着一个猜测去路由】。

★★【"没评估"是一个【记下来的事实】,不是一个空值】★★
两种缺席,而它们是【两件不同的事】,不许压成同一个 NULL:
  · 列上是 NULL     = **这一行比这条轴还老。** 不回填,不拦人。
  · not_assessed 这一行 = **有人打开了表单,并且没有下判断。** 那是一个
    positive 的、被记下来的事实,它必须存得下。
把两者并成一个可空 boolean,正是 materials.may_be_processed 走过的路:
最后要靠散文去解释线上那两批计价库存的 NULL 是什么意思。
★【一个没设的判断,永远不许被读成"不能"】★ —— 字典让这句话是【结构性的】,
而不是一条要靠人记着的约定。

【它与 inbound_safety_states 是【两条轴】,不是同一条 —— 这一段是刻意写下来的】
  · inbound_safety_states 答【状态】:这批料现在放没放电(charged_not_discharged /
    discharged_verified)。**那条轴是起火闸读的**(guard_processing_input)。
  · 本表答【能力】:这批料【压根能不能】放电。
两者【不是同一个事实记两遍】,证据就在 operation_type_safety_states 里:
整电池粉料线【受理 charged_not_discharged 而【不】解决它】—— 因为它专收
【放不了电】的料。也就是说"带电"与"放得了电"必须能同时说出口,
而且组合起来指向不同的产线:
    带电 + 能放电   → 深度放电线
    带电 + 放不了电 → 整电池粉料线
★【为什么"实际"不做成 inbound_safety_states 的一行】★ 那会把【能力】搬到
【起火闸读的那条状态轴】上,于是同一件事有了第二种说法 —— 而"一个事实两个来源"
正是这个仓库反复付账的那一类缺陷。**同一本字典让两侧可比;不同的表让能力轴
离起火闸远远的。**';

COMMENT ON COLUMN public.deep_discharge_judgements.is_a_claim IS
'PROC-1B-iii:这个取值【算不算一次主张】。
can / cannot = true(它们各自主张了一件事);not_assessed = false(它什么都没主张)。

【谁读它】grn_discrepancies:一次差异需要【两次互相矛盾的主张】,
而"我没看"不是一次主张 —— 于是任何一侧不是主张时,差异是 NULL,不是 true。
与 assay_beyond_tolerance 在任一侧缺失时给 NULL 是同一条,只是取值集合更宽。

【它让"以后加第四个值"真的只是加一行】比如 can_with_precautions:
is_a_claim = true,视图当场就把它算进比较里,一行代码都不用改。';

INSERT INTO public.deep_discharge_judgements (code, name_en, name_zh, is_a_claim, sort_order, notes) VALUES
    ('can', 'Can be deep-discharged', '可深度放电', true, 1,
     '路由到【深度放电】。这是主线:放电 → 人工拆解到模组 → 模组拆解到电芯 → 开壳 → 极片分离。'),
    ('cannot', 'Cannot be deep-discharged', '不可深度放电', true, 2,
     '路由到【整电池粉料线】(旁路)。放不了电的整包 / 模组 / 3C 电池走这里 —— '
     || '而它与极片粉料线是【两台不同的设备】,因此是两道工序,不是一道。'),
    ('not_assessed', 'Not assessed', '未评估', false, 3,
     '**有人打开了表单,并且没有下判断** —— 这是一个记下来的事实,不是一个空值。'
     || '【不可路由】:你不许照着一个猜测去路由。它与列上的 NULL(这一行比这条轴还老)'
     || '是两件不同的事,而这正是本表不做成可空 boolean 的全部理由。');

ALTER TABLE public.deep_discharge_judgements ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 inbound_safety_states / material_kinds / waste_classifications 同一处置。
CREATE POLICY "deep_discharge_judgements select all"
    ON public.deep_discharge_judgements AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "deep_discharge_judgements write by permission"
    ON public.deep_discharge_judgements AS PERMISSIVE FOR ALL TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
GRANT SELECT, INSERT, UPDATE, DELETE ON public.deep_discharge_judgements TO authenticated;
