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
挂在进料批上而不是物料上,因为它逐批不同,而且只有收货的人看得见。
RUNTIME CONFIG,加一种是加一行。

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
'PROC-2 记的规则,PROC-3 起【真的拦人】:guard_processing_input 读它。

【合取】一批货身上的每一条安全状态都必须 may_be_fed = true 才投得进去。
一批已放电的货【同时也进过水】,那它就是进过水的 —— 放电不能把水抵消掉。

【两个动词,谁也替不了谁】
  * 要撤回一条【规则】(我们把规则定错了,想全局收回)—— 改 **may_be_fed**。
    一行字典,立刻生效,而且【事实还留着】:那批货进过水这件事没有被抹掉。
  * 要让一个值【不再被新选】—— 改 **is_active**。它管的是选单,不管已记的事实。
【守卫【不读】is_active】所以停用一个值【不会】让已经贴着它的货变成可投料。
这是刻意的:停用一行字典是一个看起来很轻的动作,而它若能解锁一批货,
那就成了一条无痕迹、且一次性对所有批次生效的释放路径。';

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
