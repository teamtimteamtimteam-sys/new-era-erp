-- db/tables/equipment_service_intervals.sql
-- EQP-2c:一行 = 【这台机器的这一种活,每隔多少算一轮】。
--
-- 【没有这一行 = 「未监控」,不是「未到期」】equipment_service_status 里它仍然有
-- 一行,monitored = false,每一个量度都是 NULL。把"没人决定要盯它"读成"查过了
-- 没问题",正是 METAL-1 的 no_reference 与 SS-1 那条安全库存阈值的同一课。
--
-- 【关灯有两种】删掉这一行 = 回到「未监控」;disposition = 'ignore' = 照旧算、
-- 不上看板。用删行去关灯会把两者压成一个状态。
--
-- 【键是 (equipment_id, kind),而 kind 只有两个值 —— 这是被排期逼出来的】
-- 更细的 service_type 今天走不通:equipment_maintenance 上没有那一列,而改 2b 的
-- 表不在本刀,于是按 service_type 配的间隔永远匹配不到保养记录。返回条件见表注。
--
-- 【提前量与后果都在【行】上】lead_kg / lead_days / disposition ——
-- 形状取自 certificate_types(那里是 warn_lead_days + disposition),
-- 落点从【类型】挪到【间隔行】的两条理由写在本刀迁移的抬头 ②。
--
-- NOTE: introduced by db/migrations/2026-08-21-eqp2c-service-intervals-and-the-due-arm.sql.
-- First-run script (plain CREATEs).

CREATE TABLE public.equipment_service_intervals (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    equipment_id uuid NOT NULL REFERENCES public.fixed_assets (id),
    -- 【域照抄 equipment_maintenance.kind,一个字不差】两处必须同域,否则配了
    -- 间隔的那一种永远匹配不到保养记录。见抬头 ①。
    kind         text NOT NULL CHECK (kind IN ('service', 'repair')),
    -- ── 两个量度,至少说出一个(D1)──────────────────────────────────────
    interval_kg   numeric CHECK (interval_kg IS NULL OR interval_kg > 0),
    lead_kg       numeric,
    interval_days integer CHECK (interval_days IS NULL OR interval_days > 0),
    lead_days     integer,
    -- ── 后果(certificate_types.disposition 的形状,只有两个值)────────────
    disposition  text NOT NULL DEFAULT 'warn' CHECK (disposition IN ('warn', 'ignore')),
    notes        text,
    created_at   timestamptz NOT NULL DEFAULT now(),
    created_by   uuid DEFAULT auth.uid(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    updated_by   uuid,
    -- 【至少说出一个 —— 照抄 2b 那一族的 num_nonnulls 写法,不另发明一种拼法】
    CONSTRAINT equipment_service_intervals_at_least_one CHECK (
        num_nonnulls(interval_kg, interval_days) >= 1
    ),
    -- 【提前量与它的量度成对出现,而且严格小于它】
    -- 0 是允许的(= 不要提前警告,只在到期那一刻上牌),那是一个【决定】;
    -- 等于间隔则是一盏【从第一天就亮着】的灯,而喊狼来了的告警没人看。
    CONSTRAINT equipment_service_intervals_lead_kg_shape CHECK (
        (interval_kg IS NULL AND lead_kg IS NULL)
        OR (interval_kg IS NOT NULL AND lead_kg IS NOT NULL
            AND lead_kg >= 0 AND lead_kg < interval_kg)
    ),
    CONSTRAINT equipment_service_intervals_lead_days_shape CHECK (
        (interval_days IS NULL AND lead_days IS NULL)
        OR (interval_days IS NOT NULL AND lead_days IS NOT NULL
            AND lead_days >= 0 AND lead_days < interval_days)
    ),
    CONSTRAINT equipment_service_intervals_one_per_kind UNIQUE (equipment_id, kind)
);

COMMENT ON TABLE public.equipment_service_intervals IS
'EQP-2c:一行 = 【这台机器的这一种活,每隔多少算一轮】。

【没有这一行的机器是「未监控」,不是「未到期」—— 这条区别是本表存在的理由之一】
一台没有间隔行的机器,在 equipment_service_status 里【仍然有一行】,带
monitored = false,而它的每一个量度都是 NULL(不是 0、不是 false)。
**把"没人决定要盯它"读成"查过了,没问题",正是 METAL-1 的 no_reference
与 SS-1 的"安全库存阈值为 NULL"那一课。** 看板那两支臂只收 monitored 的行。

【关灯有两种,它们不是一回事】
* **删掉这一行** = 我们不再盯这台机器的这一种活(回到「未监控」);
* **disposition = ''ignore''** = 我们照旧盯着、照旧算得出到期,只是不要上看板。
用删行去关灯,会把"不想被打扰"记成"从来没决定过",而后者读起来像疏漏。

【为什么键是 (equipment_id, kind),而 kind 只有两个值】
本刀要算的是"距上一次【那一种】保养",而"那一种"今天在库里只有
equipment_maintenance.kind 这一个维度(''service'' / ''repair'')。
给本表另立一套 service_type(换油 / 换皮带 …)在今天【走不通】:
equipment_maintenance 上没有那一列,而改 2b 的表不在本刀 ——
于是按 service_type 配的间隔【永远匹配不到任何一行保养记录】,推导会永远停在
"从未保养过"这个基线上。**一个永远停在基线上的推导比没有更坏,因为它看起来在工作。**
**返回条件:equipment_maintenance 长出 service_type 那一列的那一刀,把本表的
唯一键从 (equipment_id, kind) 扩成 (equipment_id, kind, service_type) ——
equipment_service_status 的推导一个字都不用改,它按 kind 匹配的那一句跟着扩即可。**

【repair 也允许配间隔,而它多半配不上】保养按间隔重复,修理是事件驱动
(equipment_maintenance.kind 的列注释写着这句)。允许它是为了不把返回条件
做成一次改表;它不是一个建议。

【本表不判断任何事】到期就是到期,系统不拦任何人、不停任何机器、不算
可用率、不算"逾期百分之多少"。理由与返回条件写在 equipment_service_status
的视图注释里。

【界面是 EQP-2d】本刀落的是数据这一半:表、推导、以及看板那两支臂的【行】。
牌子、表单、机器页上的那一块,都在 2d。**它们的缺席是排期,不是遗漏。**';

COMMENT ON COLUMN public.equipment_service_intervals.kind IS
'EQP-2c:这一轮说的是哪一种活 —— 域与 equipment_maintenance.kind 【必须一字不差】,
因为推导正是按它去匹配保养记录的。两处若漂开,配了间隔的那一种会永远匹配不到,
读出来永远是「从未保养过」—— 而那与"真的从未保养过"在屏幕上一模一样。';

COMMENT ON COLUMN public.equipment_service_intervals.interval_kg IS
'EQP-2c:每处理多少公斤算一轮。判据是【投料】(processing_runs.total_input)——
磨损来自进去的料,不是出来的料。**只有公斤,没有运转小时**:加工这一族里没有
任何开始/结束/班次/工时列,这是 EQP-2a 实测出来的,不是一次选择。
可空:与 interval_days 至少说出一个即可(表上那条 num_nonnulls CHECK)。';

COMMENT ON COLUMN public.equipment_service_intervals.lead_kg IS
'EQP-2c:还差多少公斤就开始报【将到期】。**这个数是【数据】,推导现读它** ——
fixture 111 的 F6 在同一笔事务里把它调大再调小,看那一支臂两个方向都动。
【0 是一个决定,不是"没填"】0 = 不要提前警告,到期那一刻才上牌;
而 interval_kg 一旦给了,本列就【必须】给(表上那条 CHECK)—— 留空与 0 若都
合法,两种拼法就有了同一个意思,而"没填"会静默地变成"不提前警告"。
【严格小于 interval_kg】等于间隔 = 一盏从第一天起就亮着的灯。';

COMMENT ON COLUMN public.equipment_service_intervals.interval_days IS
'EQP-2c:每隔多少天算一轮。与 interval_kg 【互相独立,各自够用】——
一台跑得少的机器仍然要按日历保养(油会老化,而油不知道它转了多少公斤)。
可空:两者至少说出一个。';

COMMENT ON COLUMN public.equipment_service_intervals.lead_days IS
'EQP-2c:还差多少天就开始报【将到期】。语义与 lead_kg 逐字相同,包括
「0 是决定」与「严格小于」两条。';

COMMENT ON COLUMN public.equipment_service_intervals.disposition IS
'EQP-2c:到期之后【会怎样】—— 形状取自 certificate_types.disposition。
* ''warn''   = 上看板(equipment_service_due / equipment_service_approaching 两支);
* ''ignore'' = 照旧算,不上看板。
**【没有 ''block''】** certificate_types 的 block 是有人兑现的(收货闸门读它);
本刀什么都不拦,所以一个没有任何地方兑现的枚举值只会是一句谎 ——
与本仓库那条"在关闭它的提交里就地退休一个 known gap"是同一条规矩的另一面。
**返回条件:哪天有一道门要按"保养逾期"拦住什么(不许开工、不许接单),
连同那道门一起把 ''block'' 加进来,不要先把值加上等着。**';

COMMENT ON CONSTRAINT equipment_service_intervals_at_least_one ON public.equipment_service_intervals IS
'EQP-2c:公斤与天数【至少说出一个】—— 照抄 2b 那一族的 num_nonnulls 写法,
不另发明第二种拼法。两个都空的一行,读起来像"配好了",而它什么都不会报。';

CREATE INDEX idx_equipment_service_intervals_equipment
    ON public.equipment_service_intervals (equipment_id, kind);

ALTER TABLE public.equipment_service_intervals ENABLE ROW LEVEL SECURITY;

-- 【读写两侧逐字照抄 equipment_maintenance(EQP-2b)】读是两个模块的 OR
-- (机器卡在财务、干活的人在加工),写是加工侧。没有新权限码 ——
-- 那个 OR 是 AGENTS.md 第 2 条常设决定。
-- 【多出来的是 DELETE 那一条,而它是刻意的】equipment_maintenance 没有 DELETE
-- 策略,因为一行保养记录是【历史】—— 干过的活删不掉。本表装的是【配置】,
-- 而"不再盯这台机器的这一种活"是一个正当的、要做得到的决定(见表注:
-- 删行 = 回到「未监控」,与 disposition = 'ignore' 是两件事)。
-- 没有 DELETE 策略的话,那个决定就只能靠改 disposition 表达,而那会把
-- 「未监控」与「盯着但不吵」压成一个状态 —— 正是表注要分开的那两个。
CREATE POLICY "equipment_service_intervals select by permission"
    ON public.equipment_service_intervals
    AS PERMISSIVE FOR SELECT TO authenticated
    USING (has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text));

CREATE POLICY "equipment_service_intervals insert by permission"
    ON public.equipment_service_intervals
    AS PERMISSIVE FOR INSERT TO authenticated
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "equipment_service_intervals update by permission"
    ON public.equipment_service_intervals
    AS PERMISSIVE FOR UPDATE TO authenticated
    USING (has_permission('module.processing.edit'::text))
    WITH CHECK (has_permission('module.processing.edit'::text));

CREATE POLICY "equipment_service_intervals delete by permission"
    ON public.equipment_service_intervals
    AS PERMISSIVE FOR DELETE TO authenticated
    USING (has_permission('module.processing.edit'::text));
