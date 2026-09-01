-- db/tables/inbound_safety_states.sql
-- PROC-2:这一【批】料的安全状态。多值,挂在进料批上。
--
-- 【RUNTIME CONFIG】加一种是加一行(与 certificate_types / material_kinds /
-- waste_classifications 同形,check_mirrors 不逐行比对内容)。
-- 【每一条轴都是字典,不是枚举、不是自由文本】理由是 F7,而它在这个仓库里
-- 已经发作过:materials.category 长出四种命名法而没有任何东西察觉,
-- 而那笔转换成本不是渐渐变贵,是会变成【不可能】。
--
-- NOTE: introduced by db/migrations/2026-08-22-proc2-intake-condition-axes.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.inbound_safety_states (
    code       text PRIMARY KEY,
    name_en    text NOT NULL,
    name_zh    text NOT NULL,
    -- 【规则列】带着这个状态的一批料,能不能被投料。
    may_be_fed boolean NOT NULL,
    is_active  boolean NOT NULL DEFAULT true,
    sort_order integer NOT NULL DEFAULT 0,
    notes      text
);

COMMENT ON TABLE public.inbound_safety_states IS
'PROC-2:这一【批】料的安全状态。**多值** —— 一批料可以同时是"进过水"与"破损"。
RUNTIME CONFIG,加一种是加一行。

★【PROC-WIRE-1B-ii:它讲的是【物料状态】,不是"只属于进料批"】★
**表名里的 inbound 是历史,不是范围。** 自本刀起它由三张表共用:
inbound_batch_safety_states(进料批)、**output_batch_safety_states(产出批)**、
以及 operation_type_safety_states(哪道工序受理哪个状态)。
【为什么不改名】改名要 churn 掉每一份 fixture 与 operation_type_safety_states 的
外键,买到的只是一个更好看的名字 —— 而这句话把范围说清楚了,代价是零。
★【为什么产出侧【不】另起一本字典】那会让同一个码有两种意思,
并且 operation_type_safety_states 的表注已经明令"受理"只能有一个定义方式。
**必须不许分叉的是这本字典;那张联结表分不分叉,是另一件事(答案是分,见下)。**

【它决定什么】**能不能投料(may_be_fed),以及怎么存放。**
存放那一半今天【没有落点】—— 系统里没有任何"存放要求"的机制。
所以本表只做前一半,后一半记成一条待办而不是一个没人读的列
(一个没人用的列教下一个人"这件事已经在管了")。

════════════════════════════════════════════════════════════════════════════
【热失控历史【被考虑过,并且 Tim 决定不要】—— 这是一个决定,不是一个遗漏】
它不在下面的取值里,**而这句话必须写在这里**:在这个仓库里,
一次考虑过的省略如果没有写下来,与一次疏忽长得一模一样,
于是下一个人会把它当成漏掉的补进来 —— 而那会推翻一个已经做过的决定。
**不要因为"看起来少了一个"就加它。** 要加,先去问 Tim。
════════════════════════════════════════════════════════════════════════════

【may_be_fed 与 inbound_chemistry_certainties.may_be_fed 是【两个理由,同一个后果】】
一个讲危险,一个讲认不认得出来。**PROC-3 那道闸要把它们【相与】,
任何一个单独都不充分。** 两处注释互相点名,免得有人以为读一个就够了。

【下面这些 may_be_fed 是【引导默认值】,不是决定】与 certificate_types.disposition
同一条:Tim 在界面上改一行,线上就与本文件不同,那是系统在正常工作。';

COMMENT ON COLUMN public.inbound_safety_states.may_be_fed IS
    'PROC-2:这个状态的料可不可以投料 —— 【引导默认值】,不是决定;Tim 改一行即可。
★★【2026-09-01 · PROC-SUPPORT-1:这一列在本刀失去了它【最后一个消费者】】★★
它此前唯一的读者是 guard_processing_input 里 `v_op IS NULL` 那一支 —— 也就是"这张加工单没说工序时,拿什么回答受理问题"。本刀让 operation_type_code 在提交时【必填】,于是那一支【再也到不了】,受理问题从今往后一律由 operation_type_safety_states 回答。
【为什么不顺手做成"两条规则取交集"】那会【故意】弄坏 battery_powder_line:Tim 的closed ruling 让它受理 charged_not_discharged,而那一行的 may_be_fed = false。一个看起来更安全、却与一条已下裁定相抵触的改法,并不更安全。
【为什么不就这么留着】一列没人读的数据,读起来仍然像一条还在生效的规则 —— 下一个人会照着它做决定。waste_classifications.is_controlled 已经是这个病的一例,本仓库把它记成了债。**把死的东西宣告为死的**,所以这句话在这里,而不只是在某份文档里。
【排队】要么给它找一个真正的消费者(例如:新增 operation_type_safety_states 行时用它做引导默认),要么删掉它。见 docs/processing-support-as-built.md。';

INSERT INTO public.inbound_safety_states (code, name_en, name_zh, may_be_fed, sort_order, notes) VALUES
    ('charged_not_discharged', 'Charged, not yet discharged', '带电未放电', false, 1,
     '还带着电。**未放电的电芯进破碎机就是一场火** —— 这是本轴存在的首要理由。'
     || '【注意它与 material_sources.implies_never_charged 的关系】厂内边角料从来没充过电,'
     || '所以这个状态对它【不成立】,而不是"它已经放过电了"。两者不一样。'),
    ('discharged_verified',    'Discharged and verified',     '已放电并核验', true,  2,
     '放过电,而且有人核验过。【"核验过"是这个值的一半】—— 没核验的放电与没放电,在事故面前是同一件事。'),
    ('damaged_deformed',       'Damaged or deformed',         '破损或变形',   false, 3,
     '外壳破损、变形。引导默认不许投料 —— Tim 改一行即可。'),
    ('water_exposed',          'Water-exposed',               '进过水',       false, 4,
     '泡过水或受潮。引导默认不许投料。【它可能在干燥后可投】,而那是一个判断 —— 改这一行,不要绕过它。'),
    ('swollen_leaking',        'Swollen or leaking',          '鼓包或漏液',   false, 5,
     '鼓包、漏液。引导默认不许投料。');

ALTER TABLE public.inbound_safety_states ENABLE ROW LEVEL SECURITY;
-- 【目录不敏感】与 certificate_types / material_kinds / waste_classifications 同一处置。
CREATE POLICY "inbound_safety_states select all"
    ON public.inbound_safety_states AS PERMISSIVE FOR SELECT TO authenticated USING (true);
CREATE POLICY "inbound_safety_states insert by permission"
    ON public.inbound_safety_states AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.materials.edit'::text));
CREATE POLICY "inbound_safety_states update by permission"
    ON public.inbound_safety_states AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.materials.edit'::text))
    WITH CHECK (has_permission('module.materials.edit'::text));
