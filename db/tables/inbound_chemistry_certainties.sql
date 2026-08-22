-- db/tables/inbound_chemistry_certainties.sql
-- PROC-2:对【这一批】料的化学体系我们知道多少。
--
-- 【RUNTIME CONFIG】加一种是加一行(与 certificate_types / material_kinds /
-- waste_classifications 同形,check_mirrors 不逐行比对内容)。
-- 【每一条轴都是字典,不是枚举、不是自由文本】理由是 F7,而它在这个仓库里
-- 已经发作过:materials.category 长出四种命名法而没有任何东西察觉,
-- 而那笔转换成本不是渐渐变贵,是会变成【不可能】。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc2-intake-condition-axes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inbound_chemistry_certainties (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    may_be_fed boolean NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.inbound_chemistry_certainties IS
'PROC-2:对【这一批】料的化学体系,我们知道多少。挂在进料批上,逐批不同。

【它决定什么】**能不能投料** —— 一批认不出化学体系的料,在认出来之前不许进炉。
"能不能与别的料【同炉】"是另一个问题,归 G19(化学体系隔离),不在本刀。

════════════════════════════════════════════════════════════════════════════
【它与 materials.chemistry 【不是同一件事的两个名字,是两件事】(Tim 裁定)】
  * `materials.chemistry = 混合` → **这一种物料【就是】混合料。**
    这是这一行里正当且常见的主数据:一种你有意按混合料买进、存放、卖出的东西。
  * 本表 `mixed`                → **这一批货【结果是】混合的**,不管卡片怎么写。

**两者可以同时成立,也可以各自独立成立**:一批 NMC 物料的货可能来的时候是混的,
而一批混合料的货也可能完全如预期。
**所以【不要】把 混合 从化学体系字典里禁掉** —— 那会变成"不许把混合料登记成一种物料",
而那是正常做法。G18(化学体系变字典)那一刀要写的是【分工】,不是禁令,
而且**两边要用同一句话**,让下一个人无论先打开哪一个都读到同一段。
════════════════════════════════════════════════════════════════════════════

【三个状态的界必须写死,否则它们会在门口塌成两个(Tim 点名)】
**`mixed` 的意思是【我们知道它是混的】—— 一个已经确立的事实。**
它【绝不】是"我们分不出来"。分不出来的那一种叫 `unknown_pending`。
**站在一个乱糟糟的集装箱前面的人最容易把这两个搞混**,而这与
「测出来是零」对「从来没测过」是同一个形状 —— 这个仓库为它付过一次账了。';

INSERT INTO public.inbound_chemistry_certainties (code, name_en, name_zh, may_be_fed, sort_order, notes) VALUES
    ('single_known',    'Single, known chemistry',        '单一已知',   true,  1,
     '这一批是单一化学体系,而且知道是哪一种。'),
    ('mixed',           'Mixed (known to be mixed)',      '已知混合',   true,  2,
     '**【我们知道它是混的】—— 一个确立的事实,不是"分不出来"。** 分不出来的那一种是 unknown_pending。'),
    ('unknown_pending', 'Unknown, pending identification', '待识别',    false, 3,
     '还没认出来。**在认出来之前不许投料** —— 而这与"已知是混的"完全不同:'
     || '后者可以投,前者不行,因为我们根本不知道投进去的是什么。');

ALTER TABLE public.inbound_chemistry_certainties ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 certificate_types / material_kinds / waste_classifications 同一处置。
CREATE POLICY "inbound_chemistry_certainties select all"
    ON public.inbound_chemistry_certainties AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "inbound_chemistry_certainties insert by permission"
    ON public.inbound_chemistry_certainties AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "inbound_chemistry_certainties update by permission"
    ON public.inbound_chemistry_certainties AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));

COMMENT ON COLUMN public.inbound_chemistry_certainties.may_be_fed IS
'PROC-2 记的规则,PROC-3 起【真的拦人】:guard_processing_input 读它。

【与安全状态那一条【故意】不对称:确定度【没记】是放行的】
安全状态防起火,所以"没人看过"与"不安全"同罪;确定度防的是数字算错,
而那个数字由后面的化验回答,不靠停线回答。理由完整写在 guard_processing_input
里那一段注释上 —— 看见不一致想抹平之前先读它,抹平的方向选错会停产线。

【两个动词】与 inbound_safety_states.may_be_fed 同一条:may_be_fed 撤规则,
is_active 停选单,守卫只读前者。';
