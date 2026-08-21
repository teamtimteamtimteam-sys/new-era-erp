-- db/views/equipment_service_status.sql
-- EQP-2c:每一台机器、每一条保养间隔 —— 距上一次那一种保养,过了多少公斤、多少天。
-- 一个数都不存,全部从 EQP-2a/2b 已经记下的行推导。
--
-- 【基线是最难的一件,整段写在视图注释里,不在这里复述】两条事实:
--   ① 从未保养过的机器,基线是【取得日】—— 它做过的一切;
--   ② 归属只发生在 commit_processing_run 那一刻,系统里没有任何一条路能把一炉
--      跑完的加工事后归给机器,所以【在它的加工发生之后才登记】的机器从零起步。
-- 于是一个低读数有两种意思:【磨损得少】,与【磨损我们看不见】。
-- 能测量的那一半做成了 unattributed_runs_in_window 这一列;测不到的那一半
-- (窗口左边的历史)由取得日这个前提本身承担,只能由人核对。
--
-- 【日期与公斤共用同一个基线日】不共用会很安静地出事:线上这台机器的
-- in_service_date 是 2027-01-01(未来),从它起算天数是负的,那一支永远不到期。
--
-- 【不算可用率、不算 OEE、不算"逾期百分之多少"】分母没有人选过(EQP-2a 同一条)。
-- 返回条件在视图注释里。
--
-- NOTE: introduced by db/migrations/2026-08-21-eqp2c-service-intervals-and-the-due-arm.sql.

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
