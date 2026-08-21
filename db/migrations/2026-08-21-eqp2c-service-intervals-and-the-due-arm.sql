-- EQP-2c(2026-08-21):保养间隔、到期的推导,以及看板那两支臂。
--
-- 本刀只读 EQP-2a / EQP-2b 建的东西,一个字节都不改它们。
--
-- ════════════════════════════════════════════════════════════════════════════
-- 【grill 改了设计的四处,写在最前面,因为其中两处改的是 brief 本身】
--
-- ① **「每一种服务」只能是 equipment_maintenance.kind 那两个值 —— 这是被
--    排期逼出来的,不是选出来的。** D2 要算的是"距上一次【那一种】保养",
--    而"那一种"这件事,今天在库里【只有 kind IN ('service','repair')】这一个
--    维度。给间隔表另立一套 service_type(换油 / 换皮带 …)会立刻走进死路:
--    equipment_maintenance 上没有这一列,而【改 2b 的表不在本刀】——
--    于是任何按 service_type 配的间隔都【永远匹配不到一行保养记录】,
--    读出来永远是"从未保养过"。**一个永远停在基线上的推导,比没有更坏,
--    因为它看起来在工作。** 所以间隔的键是 (equipment_id, kind)。
--    返回条件写在表注上:equipment_maintenance 有了 service_type 那一列,
--    这张表的唯一键跟着变宽,推导一个字不用改。
--    **这与 EQP-2a「只有公斤没有小时」是同一种句子:一个测量结果,不是一次将就。**
--
-- ② **提前量与后果落在【间隔行】上,不落在一张按 kind 的类型表上 ——
--    这是对 brief「照 certificate_types 的形状」的一处偏离,理由有两条。**
--    certificate_types 把 warn_lead_days + disposition 放在【类型】上,而那里的
--    类型是一张自己的目录表。照搬到这里,就要新建一张按 kind 的目录表 ——
--    而 kind 的域【已经】写在 equipment_maintenance 那条 CHECK 上,
--    于是同一个域有了两份定义,必然漂开(本仓库为"两份定义"付过很多次账)。
--    第二条更硬:**一个固定的提前量服务不了两个量级的间隔** —— 500 公斤的间隔
--    与 50,000 公斤的间隔,提前 1,000 公斤分别是"永远亮着"与"几乎不亮"。
--    **而 brief 真正要的东西一个没丢:提前量是【行】(可编辑的一行上的一列),
--    后果也是【行】(disposition),改一行数据就改行为,fixture F6 两个方向都验。**
--
-- ③ **disposition 只有 warn / ignore,【没有 block】。** certificate_types 的
--    block 是有人兑现的(收货闸门读它)。本刀什么都不拦(D4),一个没有任何
--    地方兑现的枚举值就是一句谎 —— 与本仓库那条"退休一个已经不存在的 known gap"
--    是同一条规矩的另一面。要 block,连同兑现它的那道门一起加。
--    **ignore 因此是一个【真的】状态**:盯着它、但不要上看板 —— 它与
--    "没有间隔行"(压根没决定盯)不是同一件事,而删掉行去关灯会把两者混掉。
--
-- ④ **到期与【将到期】是两支臂,不是一支带等级。** D3 说"绝不许塌成一个
--    不分轻重的告警",而 operations_now 的列契约里没有等级这一列 ——
--    唯一结构上做得到的分法就是两个 item_type。与 qualification_expiring /
--    qualification_missing、container_no_arrival / container_eta_overdue 同形。
--    **两支互斥**:已到期的不再出现在"将到期"里(否则同一件事数两遍,
--    正是 fixture 30 那句话要抓的东西)。
-- ════════════════════════════════════════════════════════════════════════════

BEGIN;

-- ═══ 1 · 保养间隔 ═══════════════════════════════════════════════════════════
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

-- ═══ 2 · 到期的推导 ═════════════════════════════════════════════════════════
CREATE VIEW public.equipment_service_status WITH (security_invoker = off) AS
 SELECT s.equipment_id,
    s.equipment_code,
    s.equipment_description,
    s.equipment_status,
    s.acquisition_date,
    s.interval_id,
    s.monitored,
    s.service_kind,
    s.disposition,
    s.interval_kg,
    s.lead_kg,
    s.interval_days,
    s.lead_days,
    s.last_service_date,
    s.never_serviced,
    s.baseline_date,
    s.kg_since,
    s.days_since,
    s.unattributed_runs_in_window,
    s.due_kg,
    s.due_days,
    s.due_kg OR s.due_days AS is_due,
        CASE
            WHEN s.due_kg AND s.due_days THEN 'kg+days'::text
            WHEN s.due_kg THEN 'kg'::text
            WHEN s.due_days THEN 'days'::text
            ELSE NULL::text
        END AS due_reason,
    (s.approaching_kg OR s.approaching_days) AND NOT (s.due_kg OR s.due_days) AS is_approaching,
        CASE
            WHEN s.due_kg OR s.due_days THEN NULL::text
            WHEN s.approaching_kg AND s.approaching_days THEN 'kg+days'::text
            WHEN s.approaching_kg THEN 'kg'::text
            WHEN s.approaching_days THEN 'days'::text
            ELSE NULL::text
        END AS approaching_reason
   FROM ( SELECT fa.id AS equipment_id,
            fa.code AS equipment_code,
            fa.description AS equipment_description,
            fa.status AS equipment_status,
            fa.acquisition_date,
            i.id AS interval_id,
            i.id IS NOT NULL AS monitored,
            i.kind AS service_kind,
            i.disposition,
            i.interval_kg,
            i.lead_kg,
            i.interval_days,
            i.lead_days,
            m.last_service_date,
                CASE WHEN i.id IS NULL THEN NULL::boolean
                     ELSE m.last_service_date IS NULL END AS never_serviced,
                CASE WHEN i.id IS NULL THEN NULL::date
                     ELSE COALESCE(m.last_service_date, fa.acquisition_date) END AS baseline_date,
                CASE WHEN i.id IS NULL THEN NULL::numeric
                     ELSE u.kg_since END AS kg_since,
                CASE WHEN i.id IS NULL THEN NULL::integer
                     ELSE CURRENT_DATE - COALESCE(m.last_service_date, fa.acquisition_date) END AS days_since,
                CASE WHEN i.id IS NULL THEN NULL::bigint
                     ELSE u.unattributed_runs_in_window END AS unattributed_runs_in_window,
                CASE WHEN i.id IS NULL THEN NULL::boolean
                     ELSE i.interval_kg IS NOT NULL AND u.kg_since >= i.interval_kg END AS due_kg,
                CASE WHEN i.id IS NULL THEN NULL::boolean
                     ELSE i.interval_days IS NOT NULL
                          AND CURRENT_DATE - COALESCE(m.last_service_date, fa.acquisition_date) >= i.interval_days END AS due_days,
                CASE WHEN i.id IS NULL THEN NULL::boolean
                     ELSE i.interval_kg IS NOT NULL AND u.kg_since >= i.interval_kg - i.lead_kg END AS approaching_kg,
                CASE WHEN i.id IS NULL THEN NULL::boolean
                     ELSE i.interval_days IS NOT NULL
                          AND CURRENT_DATE - COALESCE(m.last_service_date, fa.acquisition_date) >= i.interval_days - i.lead_days END AS approaching_days
           FROM fixed_assets fa
             LEFT JOIN equipment_service_intervals i ON i.equipment_id = fa.id
             LEFT JOIN LATERAL ( SELECT max(em.performed_on) AS last_service_date
                   FROM equipment_maintenance em
                  WHERE em.equipment_id = fa.id AND em.kind = i.kind) m ON true
             LEFT JOIN LATERAL ( SELECT COALESCE(sum(pr.total_input) FILTER (WHERE pr.equipment_id = fa.id), 0::numeric) AS kg_since,
                    count(*) FILTER (WHERE pr.equipment_id IS NULL) AS unattributed_runs_in_window
                   FROM processing_runs pr
                  WHERE i.id IS NOT NULL
                    AND pr.status = 'committed'::text
                    AND pr.deleted_at IS NULL
                    AND pr.process_date >= COALESCE(m.last_service_date, fa.acquisition_date)
                    AND (pr.equipment_id = fa.id OR pr.equipment_id IS NULL)) u ON true) s
  WHERE has_permission('module.finance.view'::text) OR has_permission('module.processing.view'::text);

GRANT SELECT ON public.equipment_service_status TO authenticated;

COMMENT ON VIEW public.equipment_service_status IS
'EQP-2c:每一台机器、每一条保养间隔 ——【距上一次那一种保养,过了多少公斤、多少天】。
一个数都不存,全部从 EQP-2a/2b 已经记下的行推导。

════════════════════════════════════════════════════════════════════════════
【基线是这张视图最难的一件,而它必须被说出口,不能被抹平】
════════════════════════════════════════════════════════════════════════════

**「距上一次保养」这句话,对一台【从未保养过】的机器没有指涉。** 它的基线因此是
【取得日】—— 也就是"这台机器在我们手上做过的一切"。never_serviced = true 与
baseline_date 两列把这件事写在数据里,而不是留给读的人猜。

**而"它做过的一切"这个数,本身就有一个看不见的洞,来自 EQP-2a 记下的事实:**

> **归属只发生在 commit_processing_run 那一刻,而且只在加工日 >= 取得日时才允许
> (EQUIPMENT_NOT_ACQUIRED)。系统里【没有任何一条路】能把一炉已经跑完的加工
> 事后归给一台机器。** 于是一台【在它的加工发生之后才被登记】的机器,
> 从零公斤起步 —— 而它其实已经磨损过了。

**这不是一个假想。2026-08-21 实测,线上唯一那台机器正是这一幕:**
FA-2026-0001「Bosch Deep Discharging Machine」取得日 2026-08-21,而全库
十三炉加工的日期是 2026-06-10 到 2026-08-16 —— **每一炉都早于取得日,
每一炉的 equipment_id 都是空,而且【就算有人想补】commit_processing_run 也会
按名拒掉。** 所以它今天的 kg_since 是 **0**。

> **因此:一个低读数有两种意思 ——【磨损得少】,和【磨损我们看不见】。
> 这两件事不一样,而这张视图不替谁把它们抹平。**

**能被测量的那一半,做成了一列:`unattributed_runs_in_window`** ——
在这一行的基线窗口里,有多少炉加工【谁都没归属】(equipment_id 为空)。
* 它 **不是** 这台机器的未归属炉数 —— 未归属的炉子按定义不属于任何机器;
  它是**这段窗口里那个盲区有多大**。同一窗口的几台机器读到同一个数,那是对的。
* 它 > 0,就意味着一个低 kg_since **不构成"磨损得少"的证据**。
* 它 = 0,也**不**证明记全了:早于取得日的那些炉子根本不在窗口里
  (上面那一幕就是这样 —— 窗口从 2026-08-21 开始,十三炉全在它左边,
  于是这一列读 0,而盲区恰恰是最大的)。**这一列量得到窗口里的洞,量不到
  窗口左边的历史。后者是取得日这个前提本身,只能由人核对。**
  (与 finance_settings.system_start_date 是同一族:一条【声明】的边界,
  错了不报错,只是把每一道判据悄悄放到了错的位置。)

【日期与公斤共用【同一个】基线日,这不是顺手,是判据】
两个量度都从 baseline_date 起算(上一次那一种保养,没有就是取得日)。
**不共用会出事,而且出得很安静**:天数若改从 in_service_date 起算,
线上这台机器的 in_service_date 是 2027-01-01 —— 一个【未来】的日期,
CURRENT_DATE - 它 是【负数】,那一支于是永远不到期。而 in_service_date 可空,
NULL 会让整个天数量度消失。取得日 NOT NULL、永远不晚于任何一炉可归属的加工,
而且正是 EQP-2a 给归属划的那条界 —— **一条界,两个量度**。

【同一天的那一炉算在保养的哪一边:算【之后】】
performed_on 与 process_date 都只到【日】,同一天的先后无从分辨。这里让它算在
保养【之后】(判据是 process_date >= baseline_date)—— 于是最坏情况是把一天的
投料重复计一次,告警【早】一点;反过来会让告警【晚】,而晚是没有上界的。
两个方向都错得有限时选早的那个;这里不是。

════════════════════════════════════════════════════════════════════════════
【本视图不做的算术,以及返回条件(D4)】
════════════════════════════════════════════════════════════════════════════
**没有可用率、没有 OEE、没有"逾期百分之多少"这种指数。** 记录与比较是本刀,
判断不是。理由与 EQP-2a 拒绝算可用率时逐字相同:**那些数都要一个分母,
而分母(计划工时?日历工时?)没有人选过** —— 系统替谁选一个,得到的是一个
看起来权威、其实是我们自己编的数。
连 `interval_kg - kg_since`(还差多少)都没有出现在这里:两列都在,减法是
屏幕的事,多一列就多一处会与它的两个来源漂开的地方。
**返回条件:哪天有人(Tim)指定了那个分母,可用率就成立了;在那之前它不成立。**

════════════════════════════════════════════════════════════════════════════
【三个状态,不是两个 —— 而且「未监控」永远不许被读成「未到期」】
════════════════════════════════════════════════════════════════════════════
* **没有间隔行** → 本视图【仍然给一行】,monitored = false,其余每一个量度
  都是 **NULL**(不是 0、不是 false)。这是"没人决定要盯它"。
  LEFT JOIN 是刻意的,与 equipment_usage(EQP-2a)那一句同源:
  没跑过的机器也要在,而 NULL 不是零。
* **有间隔行,disposition = ''ignore''** → 算得出到期,不上看板。
* **有间隔行,disposition = ''warn''** → 上看板那两支。

【为什么是属主权限 + 体内两个模块的 OR】机器卡在财务、干活的人在加工。
逐字照抄 equipment_usage 与 equipment_maintenance_advice(EQP-2a/2b)。
invoker 会让 RLS 把读者无权的行【静默丢掉】,而这里行丢掉 = 那台机器看起来
"不需要保养" —— 正是 OPS-14 的 xmodule 那一族。

【界:间隔是【自愿配的】,所以扫描量跟着间隔行数走,不跟机器数走】
未监控的机器不触发那两个 LATERAL(它们的 WHERE 里第一句就是 i.id IS NOT NULL)。
与 safety_stock_below / credit_over_limit 的界是同一条:opt-in,量小。

【已处置的机器仍然在本视图里,但两支臂不收它】一张状态视图该说得出一台已处置
机器的最后状态;而一件"去保养它"的待办对一台已经不在的机器没有意义。
判据落在臂上(equipment_status <> ''disposed''),不落在这里。

【repair 的记录不重置 service 的间隔,反之亦然】按 kind 逐一匹配。
一次大修算不算"顺带做了保养"是一个人的判断,而判断不是本刀(D4)。

【界面是 EQP-2d】本刀落数据这一半;牌子、机器页上的那一块都在 2d。';

-- ═══ 3 · 放宽算子多认两支 ═══════════════════════════════════════════════════
-- 【为什么要放宽】两支臂声明的 permission 是 module.processing.view(去保养机器
-- 的是操作侧的人)。而这两支底下的数据 —— equipment_service_intervals、
-- equipment_maintenance、equipment_usage —— 每一个的读者都是
-- 【module.finance.view OR module.processing.view】(机器卡在财务)。
-- 若不放宽,一个只持财务的读者【读得到那张状态视图】,却在首页上看见「受限」——
-- 那是把"你看得见"说成"你看不见",与 operations_now 那条
-- 「缺席 ≠ 零」是同一个错的另一个方向。
-- 【为什么不是 arm_permission_any】它与 permission 【相与】,只会收窄(LOG-5a
-- 那一整段);要 OR 就只能走这里。两个名字很像而方向相反。
CREATE OR REPLACE FUNCTION public.arm_permission_widen(p_item_type text)
 RETURNS text[]
 LANGUAGE sql
 IMMUTABLE
AS $function$
    -- 【放宽】:持有其中任一码的读者,即便没有那一支声明的 permission,也看得见它。
    -- 与 arm_permission_any() 【方向相反】—— 那一个是【收窄】(与 permission 相与)。
    -- 两个名字很像而语义相反,所以两处注释互相点名。
    -- 免柜期是【钱】的事(滞港费),而录里程碑的人在操作侧:两边都要看得见,
    -- 而它们之间没有共同的权限码,所以只能放宽。
    -- EQP-2c:保养那两支同理 —— 机器卡在财务、干活的人在加工,而它们底下每一张
    -- 表/视图的读者都是这两个码的 OR。不放宽,财务会在首页读到「受限」,
    -- 而他明明读得到那张状态视图。
    SELECT CASE WHEN p_item_type = 'free_time_expiring'
                THEN ARRAY['module.purchasing.view', 'module.finance.view']
                WHEN p_item_type IN ('equipment_service_due', 'equipment_service_approaching')
                THEN ARRAY['module.processing.view', 'module.finance.view']
           END;
$function$;

-- ═══ 4 · 看板多两支 ═════════════════════════════════════════════════════════
-- 【怎么拼进去的】不是手打 —— 见 db/views/operations_now.sql 的抬头与本刀报告的
-- S2:唯一的输入是现有镜像(check_mirrors 已证明它与线上同义),脚本把新块插在
-- 末尾那个锚点之前,然后【把新块原样拿掉,反证还原成拼之前那份文件的每一个字节】。
-- 上一次有人差点把十九支重打一遍进迁移里,那正是这条规矩的由来。
-- 【列契约一字未动】(item_type / permission / permission_any / item_id /
-- doc_kind / item_code / subject / item_date / days_waiting),所以
-- CREATE OR REPLACE 够用,不必 DROP —— 与 EXEC-1a / SS-1 / LOG-5a 同。
CREATE OR REPLACE VIEW public.operations_now AS
 SELECT item_type,
    permission,
    arm_permission_any(item_type) AS permission_any,
    item_id,
    doc_kind,
    item_code,
    subject,
    item_date,
    CURRENT_DATE - item_date AS days_waiting
   FROM ( SELECT 'awaiting_assay'::text AS item_type,
            'module.inbound.view'::text AS permission,
            g.inbound_batch_id AS item_id,
            NULL::text AS doc_kind,
            g.batch_code AS item_code,
            array_to_string(g.missing_metals, ', '::text) AS subject,
            g.arrival_date AS item_date
           FROM batch_required_assay_gaps g
          WHERE g.sampleable
        UNION ALL
         SELECT 'assay_unapplied'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.latest_assay_code AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.has_unapplied_assay
        UNION ALL
         SELECT 'batch_unpriced'::text AS item_type,
            'module.inbound.view'::text AS permission,
            ib.id AS item_id,
            NULL::text AS doc_kind,
            b.batch_code AS item_code,
            b.supplier_name AS subject,
            COALESCE(ib.arrival_date, ib.created_at::date) AS item_date
           FROM batch_assay_status b
             JOIN inbound_batches ib ON ib.id = b.inbound_batch_id
          WHERE b.pricing_status = 'unpriced'::text
        UNION ALL
         SELECT 'allocation_stale'::text AS item_type,
            'module.processing.view'::text AS permission,
            s.run_id AS item_id,
            NULL::text AS doc_kind,
            s.code AS item_code,
            NULL::text AS subject,
            s.last_cost_change::date AS item_date
           FROM processing_run_allocation_status s
          WHERE s.is_stale OR s.allocated_at IS NULL AND s.last_cost_change IS NOT NULL
        UNION ALL
         SELECT 'po_awaiting_receipt'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            po.id AS item_id,
            NULL::text AS doc_kind,
            po.code AS item_code,
            po.status AS subject,
            po.order_date AS item_date
           FROM purchase_orders po
          WHERE po.deleted_at IS NULL AND (po.status = ANY (ARRAY['confirmed'::text, 'receiving'::text]))
        UNION ALL
         SELECT 'stocktake_open'::text AS item_type,
            'module.stocktakes.view'::text AS permission,
            st.id AS item_id,
            NULL::text AS doc_kind,
            st.code AS item_code,
            NULL::text AS subject,
            st.started_at::date AS item_date
           FROM stocktakes st
          WHERE st.deleted_at IS NULL AND st.status = 'open'::text
        UNION ALL
         SELECT 'qualification_expiring'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_1.id AS item_id,
            NULL::text AS doc_kind,
            s_1.code AS item_code,
            (ct.name_en || ' — '::text) || s_1.legal_name AS subject,
            sc.valid_until AS item_date
           FROM supplier_compliance sc
             JOIN certificate_types ct ON ct.code = sc.cert_type_code
             JOIN suppliers s_1 ON s_1.id = sc.supplier_id
          WHERE sc.deleted_at IS NULL AND s_1.deleted_at IS NULL AND ct.disposition <> 'ignore'::text AND sc.valid_until IS NOT NULL AND sc.valid_until <= (CURRENT_DATE + ct.warn_lead_days)
        UNION ALL
         SELECT 'qualification_missing'::text AS item_type,
            'module.suppliers.view'::text AS permission,
            s_2.id AS item_id,
            NULL::text AS doc_kind,
            s_2.code AS item_code,
            s_2.legal_name AS subject,
            s_2.created_at::date AS item_date
           FROM suppliers s_2
          WHERE s_2.deleted_at IS NULL AND s_2.supplies_goods AND s_2.status = 'active'::supplier_status AND NOT (EXISTS ( SELECT 1
                   FROM supplier_compliance sc2
                  WHERE sc2.supplier_id = s_2.id AND sc2.deleted_at IS NULL))
        UNION ALL
         SELECT 'credit_over_limit'::text AS item_type,
            'module.customers.view'::text AS permission,
            c_1.id AS item_id,
            NULL::text AS doc_kind,
            c_1.code AS item_code,
            c_1.legal_name AS subject,
            COALESCE(( SELECT min(sr.sale_date) AS min
                   FROM sales_records sr
                  WHERE sr.customer_id = c_1.id), CURRENT_DATE) AS item_date
           FROM customers c_1
          WHERE c_1.deleted_at IS NULL AND c_1.credit_limit_base IS NOT NULL AND customer_ar_exposure_visible(c_1.id) >= c_1.credit_limit_base
        UNION ALL
         SELECT 'output_unsold_aging'::text AS item_type,
            'module.output.view'::text AS permission,
            ob.id AS item_id,
            NULL::text AS doc_kind,
            ob.code AS item_code,
            ob.state AS subject,
            COALESCE(ob.output_date, ob.created_at::date) AS item_date
           FROM output_batches ob
          WHERE ob.deleted_at IS NULL AND ob.remaining_qty > 0::numeric AND (CURRENT_DATE - COALESCE(ob.output_date, ob.created_at::date)) >= 60
        UNION ALL
         SELECT 'safety_stock_below'::text AS item_type,
            'module.inventory.view'::text AS permission,
            msa.material_id AS item_id,
            NULL::text AS doc_kind,
            msa.code AS item_code,
            (((((trim_scale(msa.available_qty)::text || ' / '::text) || trim_scale(msa.safety_stock_qty)::text) || ' '::text) || COALESCE(msa.unit, ''::text)) || ' — short '::text) || trim_scale(msa.safety_stock_qty - msa.available_qty)::text AS subject,
            COALESCE(msa.last_movement_date, CURRENT_DATE) AS item_date
           FROM material_stock_available msa
          WHERE msa.safety_stock_qty IS NOT NULL AND msa.available_qty < msa.safety_stock_qty
        UNION ALL
         SELECT 'leave_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            lr.id AS item_id,
            NULL::text AS doc_kind,
            lr.code AS item_code,
            e.legal_name AS subject,
            lr.created_at::date AS item_date
           FROM leave_requests lr
             JOIN employees e ON e.id = lr.employee_id
          WHERE lr.status = 'pending'::text AND lr.deleted_at IS NULL
        UNION ALL
         SELECT 'claim_pending'::text AS item_type,
            'module.hr.view'::text AS permission,
            mc.id AS item_id,
            NULL::text AS doc_kind,
            mc.code AS item_code,
            e.legal_name AS subject,
            mc.created_at::date AS item_date
           FROM medical_claims mc
             JOIN employees e ON e.id = mc.employee_id
          WHERE mc.status = 'submitted'::text AND mc.deleted_at IS NULL
        UNION ALL
         SELECT 'review_submitted'::text AS item_type,
            'module.hr.view'::text AS permission,
            r.id AS item_id,
            NULL::text AS doc_kind,
            e.code AS item_code,
            e.legal_name AS subject,
            COALESCE(r.submitted_at::date, r.created_at::date) AS item_date
           FROM performance_reviews r
             JOIN employees e ON e.id = r.employee_id
          WHERE r.status = 'submitted'::text
        UNION ALL
         SELECT 'invoice_overdue'::text AS item_type,
            'module.finance.view'::text AS permission,
            i.invoice_id AS item_id,
            NULL::text AS doc_kind,
            i.code AS item_code,
            i.customer_name AS subject,
            i.due_date AS item_date
           FROM invoice_status i
          WHERE i.overdue
        UNION ALL
         SELECT 'ar_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            COALESCE(ar.sales_record_id, ar.invoice_id) AS item_id,
            ar.doc_kind,
            ar.doc_code AS item_code,
            ar.customer_name AS subject,
            ar.sale_date AS item_date
           FROM ar_open_items ar
          WHERE ar.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'ap_over_90'::text AS item_type,
            'module.finance.view'::text AS permission,
            ap.doc_id AS item_id,
            ap.doc_kind,
            ap.doc_code AS item_code,
            ap.supplier_name AS subject,
            ap.doc_date AS item_date
           FROM ap_open_items ap
          WHERE ap.bucket = 'b90_plus'::text
        UNION ALL
         SELECT 'fx_rate_gap'::text AS item_type,
            'module.finance.view'::text AS permission,
            NULL::uuid AS item_id,
            NULL::text AS doc_kind,
            g.currency AS item_code,
            array_to_string(g.missing_types, ', '::text) AS subject,
            g.rate_date AS item_date
           FROM fx_rate_gaps g
          WHERE g.rate_date >= (CURRENT_DATE - 45)
        UNION ALL
         SELECT 'bank_unmatched'::text AS item_type,
            'module.finance.view'::text AS permission,
            s.id AS item_id,
            NULL::text AS doc_kind,
            s.bank_account_code AS item_code,
            s.code AS subject,
            l.line_date AS item_date
           FROM bank_statement_lines l
             JOIN bank_statements s ON s.id = l.statement_id
          WHERE l.match_status = 'unmatched'::text AND s.deleted_at IS NULL
        UNION ALL
         SELECT 'margin_cost_not_allocated'::text AS item_type,
            'data.view_prices'::text AS permission,
            bm.run_id AS item_id,
            NULL::text AS doc_kind,
            bm.batch_code AS item_code,
            bm.material_name AS subject,
            ob.output_date AS item_date
           FROM batch_margin bm
             JOIN output_batches ob ON ob.id = bm.output_batch_id
          WHERE bm.margin_status = 'no_unit_cost'::text
        UNION ALL
         SELECT 'metal_quote_stale'::text AS item_type,
            'module.pricing.view'::text AS permission,
            mp.latest_id AS item_id,
            NULL::text AS doc_kind,
            mp.metal AS item_code,
            mp.latest_price::text AS subject,
            mp.max_date AS item_date
           FROM ( SELECT p.metal,
                    max(p.price_date) AS max_date,
                    (array_agg(p.id ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_id,
                    (array_agg(p.price_usd_per_tonne ORDER BY p.price_date DESC, p.created_at DESC))[1] AS latest_price
                   FROM metal_prices p
                  WHERE p.deleted_at IS NULL
                  GROUP BY p.metal) mp
          WHERE (CURRENT_DATE - mp.max_date) > (( SELECT ps.metal_quote_stale_days
                   FROM pricing_settings ps
                 LIMIT 1))
        UNION ALL
         SELECT 'orders_unfulfilled'::text AS item_type,
            'module.sales.view'::text AS permission,
            so.id AS item_id,
            NULL::text AS doc_kind,
            so.code AS item_code,
            so.status AS subject,
            so.order_date AS item_date
           FROM sales_orders so
          WHERE so.deleted_at IS NULL AND (so.status = ANY (ARRAY['confirmed'::text, 'partially_shipped'::text]))        UNION ALL
-- ── EXEC-3a:工单逾期 ──────────────────────────────────────────────────────
-- 【排产日为空【永远不是】逾期】—— 空的意思是"没排期",而不是"排在过去"。
-- 一个 COALESCE(scheduled_date, CURRENT_DATE) 会把没排期的全部报成今天到期,
-- COALESCE(..., 'infinity') 会把它们全部漏掉 —— 两个方向都错,所以这里
-- 显式 IS NOT NULL(WO-1c 记在 arm inventory 里的那条)。
--
-- 【"放行了三个月、从没排过期"该不该有别的支管】—— 仍然是一个【开着的问题】,
-- 记在 arm inventory 里。这一支不假装回答它:它只报"排了期而且过了期"的。
         SELECT 'work_order_overdue'::text AS item_type,
            'module.processing.view'::text AS permission,
            w.id AS item_id,
            NULL::text AS doc_kind,
            w.code AS item_code,
            w.scheduled_date::text AS subject,
            w.scheduled_date AS item_date
           FROM work_orders w
          WHERE w.status = 'released'::text
            AND w.scheduled_date IS NOT NULL
            AND w.scheduled_date < CURRENT_DATE
        UNION ALL
-- ── EXEC-3a:工单差异超阈 ──────────────────────────────────────────────────
-- 【两种坏消息,两个阈值,两种触发时机】—— WO-1c 在 arm inventory 里留的那个
-- 问题("投入超耗与产出短交是否用同一个阈值")的答案是【不是】,所以
-- processing_settings 有两列,而这一支有两条腿:
--
--   * 投入超耗:吃掉的比计划多出 t_in% 以上。**开着的单和收了工的单都报** ——
--     超耗在它发生的那一刻就是可处理的事(料已经下去了,要么改计划、要么查为什么)。
--   * 产出短交:产出比预期少 t_out% 以上。**只报收了工的单** —— 在收工之前,
--     "少"只是"还没做完",把它报出来等于每天提醒一件正在进行的事。
--
-- 【没记录预期的行永远不报】has_plan = false 意味着没人估过,而不是估了零。
-- 一个把它当零的实现会让每一次产出都成为"短交 100%"—— 这正是 WO-1a 让
-- 预期产出行可选、WO-1b 让视图返回 NULL 的全部理由,在这里必须一路守住。
--
-- 阈值现读 processing_settings,不写死(与 metal_quote_stale 同一条)。
         SELECT 'work_order_variance_beyond'::text AS item_type,
            'module.processing.view'::text AS permission,
            f.work_order_id AS item_id,
            NULL::text AS doc_kind,
            f.work_order_code AS item_code,
            CASE WHEN f.side = 'input'::text
                 THEN 'input overrun · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
                 ELSE 'output shortfall · ' || COALESCE(f.material_code, '?') || ' · '
                      || trim_scale(f.actual_qty)::text || ' / ' || trim_scale(f.planned_or_expected_qty)::text
            END AS subject,
            COALESCE(w2.scheduled_date, w2.created_at::date) AS item_date
           FROM work_order_fulfilment f
             JOIN work_orders w2 ON w2.id = f.work_order_id
          WHERE f.has_plan
            AND f.planned_or_expected_qty > 0::numeric
            AND (
                 (f.side = 'input'::text
                  AND w2.status = ANY (ARRAY['released'::text, 'closed'::text])
                  AND f.actual_qty > f.planned_or_expected_qty
                      * (1::numeric + (SELECT ps.wo_input_overrun_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
              OR (f.side = 'output'::text
                  AND w2.status = 'closed'::text
                  AND f.actual_qty < f.planned_or_expected_qty
                      * (1::numeric - (SELECT ps.wo_output_shortfall_pct FROM processing_settings ps LIMIT 1) / 100::numeric))
            )
        UNION ALL
-- ═══ LOG-5a:物流的四支 ═══════════════════════════════════════════════════
-- 【四支全部排除已软删的箱子】(c.deleted_at IS NULL,逐支各写一次)。
-- 【三个阈值 2 / 14 / 7 都是写死的(v1,Tim 定)】。要把它们变成可调的那一天,
-- 现成的先例是 certificate_types.warn_lead_days —— 一张 RUNTIME CONFIG 表,
-- 每一类自带提前期【和】后果(block/warn/ignore),"加一种是编辑一行,不是跑一次迁移"。
-- 在那之前,写死的数字至少是【看得见】的:它就在这里,不在某个配置项里。

-- ── 1 · 免柜期将尽 / 已超 ────────────────────────────────────────────────
-- 【锚点是"最后被【录入】的那条 arrived"】(LOG-5d 改)—— ORDER BY
-- recorded_at DESC, id DESC。**此前是 event_date DESC,那是错的**:
-- 里程碑只增不改,更正的写法是再记一条;而一条把日期改【早】的更正,
-- 在 event_date 排序下【永远排不到前面】,于是它一次都不会生效。
-- (线上实例 CTR-2026-0009:先录 arrived 08-16,再录一条更正 08-14 ——
--  所有读者仍然锚在 08-16。改晚的更正碰巧生效,改早的永远不生效。)
-- 【屏幕那一侧算的是同一件事,必须同刀改】页面为了显示剩余天数自己算了一遍
-- (app/logistics/containers/[id]/ContainerFreightPanel.tsx),口径一旦与这里分岔,
-- 屏幕写着"剩余 1 天"而看板一声不吭,且没有任何东西会报错。两处注释互相点名。
-- 【id DESC 是破平局的】recorded_at 默认 now() = 事务时刻,同一事务里插两条会一样;
-- uuid 比大小没有"更晚"的含义,但它是【确定的】—— 不确定比排错更坏。
-- 【这条规则只管"同一种里程碑里哪一条算数"】。跨类型的"现在走到哪一步"是另一个
-- 问题,仍按 event_date 排(container_overview.latest_milestone)—— 那里若改成
-- recorded_at,今天补录一条 booked 就会让箱子"退回"已订舱。
-- 【报价里 free_days 为 NULL 的箱子一支都不响】NULL = "这份报价没有写免柜期",
-- 与 0 =「零个免费天」是两件不同的事,而把前者当成后者会让每一个到港的箱子
-- 从第一天起就报警 —— 那是喊狼来了,而喊狼来了的告警等于没有告警。
         SELECT 'free_time_expiring'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            ((q.free_days - (CURRENT_DATE - arr.event_date))::text || ' left of '::text
              || q.free_days::text) || COALESCE(' — '::text || f.legal_name, ''::text) AS subject,
            arr.event_date AS item_date
           FROM containers c
             LEFT JOIN suppliers f ON f.id = c.forwarder_id
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'arrived'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) arr ON true
             JOIN forwarder_rate_quotes q
               ON q.supplier_id = c.forwarder_id AND q.lane_id = c.lane_id
              AND q.deleted_at IS NULL
              AND c.departure_date >= q.valid_from AND c.departure_date <= q.valid_to
          WHERE c.deleted_at IS NULL
            AND q.free_days IS NOT NULL
            AND (q.free_days - (CURRENT_DATE - arr.event_date)) <= 2
        UNION ALL
-- ── 2 · 走了很久,没人说到了 ─────────────────────────────────────────────
-- 【这一支是上一支的保命companion】免柜期那一支只在【有 arrived】时才可能响;
-- 一个没人录到港的箱子,在那一支里【永远安静】,而安静与"没问题"在屏幕上
-- 长得一模一样(METAL-1 的 no_reference 那一课)。所以这一支专门说:
-- 开走 14 天了,而没有任何人说过它到了。
         SELECT 'container_no_arrival'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            dep.event_date::text AS subject,
            dep.event_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT m.event_date
                   FROM container_milestones m
                  WHERE m.container_id = c.id AND m.milestone = 'departed'::text
                  ORDER BY m.recorded_at DESC, m.id DESC
                 LIMIT 1) dep ON true
          WHERE c.deleted_at IS NULL
            AND (CURRENT_DATE - dep.event_date) >= 14
            AND NOT (EXISTS ( SELECT 1 FROM container_milestones m2
                               WHERE m2.container_id = c.id AND m2.milestone = 'arrived'::text))
        UNION ALL
-- ── 3 · 说好的到港日过了,而它还没到 ─────────────────────────────────────
-- 【expected_arrival_date 为 NULL 时这一支不响】,而那是一条【已知的局限】,
-- 不是一个疏漏:与 work_order_overdue 逐字同形(它也只报"排了期而且过了期"的,
-- 并在视图里明写"放行了三个月、从没排过期该不该有别的支管"仍是开着的问题)。
-- 同一个问题在这里原样成立:一个从来没人填过 ETA 的箱子,是"没问题",
-- 还是最该被问的那一个?这一支不假装回答它。
         SELECT 'container_eta_overdue'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            c.expected_arrival_date::text AS subject,
            c.expected_arrival_date AS item_date
           FROM containers c
          WHERE c.deleted_at IS NULL
            AND c.expected_arrival_date IS NOT NULL
            AND c.expected_arrival_date < CURRENT_DATE
            AND NOT (EXISTS ( SELECT 1 FROM container_milestones m3
                               WHERE m3.container_id = c.id AND m3.milestone = 'arrived'::text))
        UNION ALL
-- ── 4 · 开走了,单据还欠着 ───────────────────────────────────────────────
-- 【锚在 departure_date】—— 它是箱子上唯一 NOT NULL 的世界侧日期,所以一定算得出来。
-- 【代价照直写】:有些单据(订舱确认、装箱单)本该在开航【之前】就到,
-- 以开航日为零点会让它们永远不迟。这一支因此不是"所有该到的单据"的告警,
-- 是"开航之后还欠着"的告警 —— 名字与它测的东西一致。
-- 【从没实例化过清单的箱子一支都不响】:pending 数为 0,这里就没有行。
-- 那种"空"与"都收齐了"在库里长得一样,而把它们分开是 5b 的事(屏幕上说清哪一种空)。
         SELECT 'container_documents_late'::text AS item_type,
            'module.purchasing.view'::text AS permission,
            c.id AS item_id,
            NULL::text AS doc_kind,
            c.code AS item_code,
            p.n::text || ' pending'::text AS subject,
            c.departure_date AS item_date
           FROM containers c
             JOIN LATERAL ( SELECT count(*) AS n
                   FROM container_documents d
                  WHERE d.container_id = c.id AND d.status = 'pending'::text) p ON true
          WHERE c.deleted_at IS NULL
            AND p.n > 0
            AND (CURRENT_DATE - c.departure_date) >= 7
        UNION ALL
-- ── EQP-2c · 保养到期,以及【将到期】——【两支,不是一支带等级】────────────
-- operations_now 的列契约里没有"严重程度"这一列,所以唯一在结构上分得开的
-- 办法就是两个 item_type。与 qualification_expiring / qualification_missing、
-- container_no_arrival / container_eta_overdue 同形。
-- 【两支互斥】已到期的不再出现在"将到期"里(is_approaching 自己带 NOT is_due)
-- —— 否则同一件事被数两遍,那正是 fixture 30 那句话要抓的东西。
-- 【提前量是【数据】】lead_kg / lead_days 在 equipment_service_intervals 的行上,
-- 视图现读;fixture 111 F6 在同一笔事务里两个方向都验过。
-- 【item_id 是机器,不是间隔行】判据是 LINKS-1 那一条:门牌指向【承载补救动作】
-- 的那张页面所对应的行。补救动作是"给这台机器记一次保养",而它发生在机器那一页
-- (/finance/assets/[id],EQP-1c-b 建的)—— 间隔行今天没有自己的页面。
-- 与 bank_unmatched / margin_cost_not_allocated 取父行是同一条规矩。
-- 【item_date 是基线日】= 上一次那一种保养,没有就是取得日。于是
-- days_waiting 读出来就是"距上一次保养多少天",【正好就是两个量度里的天数那一个】,
-- 不是第三个数。
-- 【未监控的机器一支都不响,而那是一个具名状态不是零】判据 s.monitored ——
-- 理由整段写在 equipment_service_status 的视图注释里,这里不复述。
-- 【已处置的机器不收】一件"去保养它"的待办,对一台已经不在的机器没有意义。
-- 【牌子在 EQP-2d】本刀落的是这两支的【行】;首页那两块牌子在 2d。
         SELECT 'equipment_service_due'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess.equipment_code AS item_code,
            (ess.service_kind || ' — '::text) || ess.equipment_description AS subject,
            ess.baseline_date AS item_date
           FROM equipment_service_status ess
          WHERE ess.monitored AND ess.disposition = 'warn'::text AND ess.equipment_status <> 'disposed'::text AND ess.is_due
        UNION ALL
         SELECT 'equipment_service_approaching'::text AS item_type,
            'module.processing.view'::text AS permission,
            ess_1.equipment_id AS item_id,
            NULL::text AS doc_kind,
            ess_1.equipment_code AS item_code,
            (ess_1.service_kind || ' — '::text) || ess_1.equipment_description AS subject,
            ess_1.baseline_date AS item_date
           FROM equipment_service_status ess_1
          WHERE ess_1.monitored AND ess_1.disposition = 'warn'::text AND ess_1.equipment_status <> 'disposed'::text AND ess_1.is_approaching
) a
  WHERE (has_permission(permission) OR has_any_permission(arm_permission_widen(item_type)))
    AND (arm_permission_any(item_type) IS NULL OR has_any_permission(arm_permission_any(item_type)));

COMMIT;
